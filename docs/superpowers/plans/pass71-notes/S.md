# pass71 owner S notes

Owner S: service and runtime. Branch `p71/S`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p71-S`,
from main `6e8dad1`.

## Contracts (published early)

### S5 queue count (for V's "N queued" indicator)

- Field **`queued`**, a non-negative integer (`:count`), on both
  `DTO.WorkspaceSnapshot` and `DTO.WorkspaceMetadata` (the `workspace_metadata` delta).
- Meaning: prompts of this conversation waiting behind its live turn
  (`length(conversations.queued)` of the open conversation). `0` when nothing waits.
- Wire default `0`: an older daemon, or a map without the key, decodes as `0`.
- Updated by the service whenever the queue changes (a prompt queued, a queued prompt started or
  put back): a `workspace_metadata` delta carries the new count.
- Fake parity: `Fake.Session` has the same field; conversation `a` starts at `0` and a `send`
  while its run is live queues (count up, toast), like the service.
- Read it in the projector as
  `Map.get(workspace_snapshot_or_metadata, :queued, 0)` until the merge.

## Landed

| Task | Commits | What |
| --- | --- | --- |
| S1 P0 | 2514b16 | Deadlines: one monotonic clock in `DataSource.Daemon`. |
| S2 P0 | d092324 | Slow reads of the persisted service run as supervised jobs. |
| S5 P1 | f85c7f6 | `queued` on the workspace snapshot and metadata; fake parity. |
| S3 P1 | 327a52b | umask 077: a test proves the release env's umask reaches the VM; dev launchers set it. |
| S4 P1 | e66dc3c | The exit summary lists every run the quit stopped. |
| S6 P2 | 5394a6e | Streaming ticks refetch only the rows they name (C9), golden-tested. |

## S1: request deadlines

`Request.deadline` is, and stays, the owner's wall-clock millisecond (`state.now + deadline_ms`):
every producer (reducer, library, plain session, one-shot) stamps it that way and the reducer
stays pure. `DataSource.Daemon` converts it exactly once, at admission, into the wire's
`timeout_ms` budget and a monotonic deadline; every later comparison (requests, controls,
receipts, partial frames) is monotonic. Before, the source compared the wall-clock deadline with
`System.monotonic_time/1`, so no request ever expired and the wire's `timeout_ms` was always the
600 s cap. New option `clock: (:system | :monotonic -> ms)` for tests. Regression test
`daemon_test.exs` "a deadline fires on the monotonic clock and a late reply is ignored" (also: a
wall-clock step alone expires nothing). Tests that stamped deadlines with the monotonic clock now
use the wall clock like production.

## S2: slow reads as jobs

`PersistedBackend` (`handle_call({:service_request, …})` now defers its reply for reads that are
jobs):

- Jobs: every `feature_query` (the `@path` file index and ranking, Changes' Git tree in the
  project scope, the libraries), a `detail` of a `<id>:diff` not in the diff cache, and the
  change facts of finished runs (the "facts job", one at a time, 50 checkpoints per job, not tied
  to a caller; its result refreshes the projection).
- Each is `Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, …)` (opt
  `:task_supervisor` for tests), kept in `state.jobs` by task ref with the caller's `from`.
- Replace: a newer `files` query kills the older one, whose caller gets `stale_revision`.
- Cancel: a conversation switch answers every job `not_allowed`; a job past its request's
  `timeout_ms` is killed (`source_unavailable`); `terminate/2` (the service now traps exits so a
  supervisor shutdown runs it) kills every job and settles its caller. A crashed job is
  `source_unavailable`. At most 8 jobs run; the ninth is `capacity_exceeded`.
- Bounded: a diff larger than the 4 MB diff cache is refused whole (`capacity_exceeded` in the
  detail window), never truncated; the file index stays capped at 50 000 paths.
- Feature commands (mutations) stay in order inside the GenServer.
- Test seam: opt `work: %{file_index:, diff:, change_diff:, feature_query:}` (functions), used by
  `pass71_jobs_test.exs` with blocking fakes.
- Consequence for tests: change facts appear after the facts job; `pass70_changes_test` and
  `pass70_socket_test` wait for them.

## S3: umask

`rel/env.sh.eex` already had `umask 077` (pass70 B7); every `bin/swarm_code_cli` command sources
it, so the TUI, `-p` and `--plain` VMs and the port they spawn inherit it. New:
`test/swarm_code_cli/release_umask_test.exs` renders the template, starts `erl` under it from a
`umask 022` shell and checks that a written file is 0600 and a directory 0700. The dev session
launchers (`scripts/dev/run_{saved,plain,live}_session.sh`) now set `umask 077` too.

## S4: exit summary lists stopped runs

- `SwarmCode.Daemon.Shutdown.run/1` result gains `stopped_runs: [%{id, kind, title}]` (title =
  label, else prompt; described before the stop, oldest first); `stopped` stays the count.
- `PersistedSession` prints `Stopped  N live runs` and one `· <title>` line per run (non-chat kinds
  get ` · <kind>`).
- Request for I: the summary lists what `Shutdown` stops at the end of the session. If the new
  quit path (R1) stops runs itself before the session ends, those runs will not be listed; leave
  the stopping to the shutdown (or tell me and I will read the stopped runs from the engine).

## S6: incremental projection for streaming ticks (C9)

- `{:nodes_patch, run_id, [{id, cols}]}` and a totals-only `{:run_updated, run}` (the counters
  moved; status, finished_at, error_kind, root_node_id and kind did not) arm a *partial* refresh
  that accumulates the run and node ids of the ticks coalesced into its 20 ms window. Any other
  event arms a full reload, which absorbs a pending partial.
- The partial refresh refetches only the named run rows (`PersistedProjection.runs/5` with a
  `:runs` scope), the named agents (`agents_by_ids/2`) and the named records (`records_by_ids/2`,
  the same union as the paged `records/5`, so types match) and replaces them in place in the
  last projection's inputs (`state.inputs`: rows, records, agents, running ops, checkpoints,
  checkpoint counts). Running ops and checkpoints are reused; the rest (metadata, pending
  interactions, background) is recomputed as a reload does, then projected by the same
  `build_projection/5`.
- It falls back to a full reload when the inputs are missing, a run is not in the projection, a
  row is gone, or a refetched row changed anything a tick cannot carry (runs: only tokens, cost,
  model, updated_at; agents: status, progress, tokens, cost, updated_at; records: status, text,
  text_bytes, detail, tokens, updated_at).
- No RunServer change was needed: the refetch reads the `updated_at` the flush wrote, so the
  revisions are exact (pass-70 C's blocker).
- Known, documented difference: a checkpoint written mid-op with no event of its own shows up on
  the op's finishing upsert (the next full reload), not on the next tick.
- `state.projections` counts `full`/`partial` projections (tests read it).
- Golden tests: `pass71_projection_test.exs` compares `runs`, `order`, `revision`, `metadata`,
  `changes`, `verdicts` and `inputs` after a partial refresh with a full reload of the same
  database; plus the fallbacks (a row with a new `result`, a status change, a tick coalesced
  with a structural event).

## Verification so far

- `daemon_test.exs` 21/0, CLI `ui/data_source` 190/0 (with the new tests), daemon
  `service/` 137/0, `shutdown_test` 2/0, `persisted_session_release_test` 9/0,
  `release_umask_test` 2/0.
- Each regression test was checked to fail without its fix (S1: 4 failures without it; S3: the
  umask test fails without the env line).
- `mix test apps/swarm_code_cli/test` once: 1432 tests, 1 failure,
  `plain/session_test` "reader handles charlist devices …", which passes alone with and without
  my changes (load flake, not mine).

## Final verification

- Full umbrella `mise exec -- mix test` (after 5394a6e, no `_build/prod`, `MIX_QUIET` unset):
  core `146 tests, 0 failures`; daemon `945 tests, 0 failures`; cli
  `5 properties, 1435 tests, 2 failures`. The two failures are load timing in files outside my set
  and pass when rerun (28/0): `plain/session_test.exs:233` (reader `:line_too_large` within 2 s)
  and `ui/session_runtime_test.exs:309` (a `snapshot` call timed out).
- `mix format --check-formatted` clean; `mix compile --force --warnings-as-errors` clean;
  `mix swarm_code.provenance.verify` passes. No manifest-listed file edited; no synced
  `domain/**` file edited.
- Real session in a sandbox HOME (`/private/tmp/p70cli/p71-S/home`, scratch ailogic copy, release
  built from this branch, 3 real prompts):
  - `@READ` completion listed `README.md` first (the files job path, S2).
  - With a run waiting for approval, select-mode `q` asked "Stop 1 live run and quit?"; after
    `X` the summary printed `Stopped  1 live run` and `· Use run_command to run: sleep 120 &&
    echo finished` (S4).
  - Everything the release wrote under the sandbox is 0600/0700: the DB, the lease DB, the
    backup and its manifest, `cli.log` and their directories (S3).
  - The screen session ended with the app's own quit; `_build/prod` removed afterwards.

## Found, not mine / left

- Pre-existing flake: `service/pass70_qa_queue_test.exs` "a prompt queued behind a running turn
  starts …" fails about 1 run in 6-12 of the whole `service/` directory, on the tree without S6
  too (2 of 12 in a scratch copy without S6); the queued prompt does not start within 6 s after
  the first turn is done. 25 further runs of a smaller set did not reproduce it, so I could not
  capture the cause. Suspect: `drain_queue/1`'s `{:error, _}` branch puts the prompt back and
  toasts but arms no new watch, so a start refused by a race is never retried. Worth a look by
  the finisher if it shows up in precommit.
- `service/persisted_backend_test.exs:1250` (inspector paging) failed once in 12 service runs
  (items shifted by five): looks like `inserted_at` ties in the fixture; not touched.
- From pass-70 C, still open: slash commands (`/export` writes a file, `/search` FTS) still run
  inside the persisted backend's `handle_call`. Same job mechanism would apply; not in this
  round's list.
- S6 limitation (documented above): a mid-op checkpoint shows on the op's finishing upsert.
