# Lane Y notes (truthful effort, quit summary, sparkline), CLI 0.2.2

Branch `cli022/Y` from CLI main `4fd44d18`, worktree `~/dev/swarm-code-cli-wt/cli022-Y`. Not merged.

## For lane X: the effective-effort fields (F4 seam)

Both `DTO.WorkspaceSnapshot` and `DTO.WorkspaceMetadata` (so `ReadModel`'s workspace snapshot,
`state.read_model.snapshots[:workspace]`) gain four fields. `effort` / `swarm_effort` keep their
meaning: the conversation's own stored value, nil while it follows a default.

| Field | Type | Meaning |
| --- | --- | --- |
| `effort_effective` | string or nil | the level the next chat turn uses: the conversation's `effort`, else the session's `NCODE_EFFORT`, else Settings' `default_effort`, else `"medium"` |
| `effort_source` | `:conversation` \| `:env` \| `:default` or nil | where `effort_effective` came from |
| `swarm_effort_effective` | string or nil | the level the next worker (swarm run) uses: the conversation's `swarm_effort`, else Settings' `default_swarm_effort`, else `"medium"` |
| `swarm_effort_source` | `:conversation` \| `:default` or nil | where `swarm_effort_effective` came from (the env never feeds the worker slot) |

X: mark `current?` from `effort_effective` / `swarm_effort_effective` (fall back to `effort` /
`swarm_effort` when nil, e.g. an older daemon or the live launcher before it sends them). The
`default` row is "current" when `effort_source` is not `:conversation` (the stored value is nil).
After `/effort default` the status line shows `effort_effective` (the default level), with no
client work: Y's status line already reads the effective field.

Fake (`ui/data_source/fake/session.ex`): Y fills the four fields from the fake's own `effort` /
`swarm_effort` (source `:conversation` when set, else the demo defaults below / `:default`).

The demo's Settings defaults are `low` (chat) and `medium` (worker), so in the demo PTY a status
line that shows the default (`low`) is told apart from a picked `medium`/`high`. The fake's
`/effort` handler already maps a level named `default` to nil (if X parses `/effort default` as a
new action instead of `set_effort` with `effort: :default`, add a fake clause for it: the file is
Y's, a two-line clause is fine).

## F4 truthful effort: root cause and fix

Reproduced first (`daemon/service/cli022_effective_effort_test.exs`, a real persisted backend,
its workspace query; 5 tests, all failing before the fix).

- The wire sent the raw column: `persisted_backend.ex:4856` (at `4fd44d18`) `"effort" =>
  conversation.effort`, nil until `/effort` stores a value, while the engine runs the turn at
  `conversation.effort || settings.default_effort || "medium"` (`domain/engine/run_server.ex`
  `effective_effort/1`; swarm runs `swarm_effort || default_swarm_effort`). So the status line and
  the dropdown had nothing to show. The QA guess was right.
- `NCODE_EFFORT` was not used at all in saved sessions: the launcher copies it to `SWARM_EFFORT`
  (`rel/overlays/bin/ncode:150`), and only `Runtime.Configuration.from_env/2` reads that
  (`runtime/configuration.ex:17`), i.e. the unsaved live launcher's runs and the first-run
  provider setup (`session_configuration.ex` `first_run/4`, which drops `config[:effort]`). The
  registry's `session.effort` has no env layer either.
- Fix, as the brief's chain says (conversation, else env, else the global default):
  - `SessionConfiguration.prepare/2` keeps the session's `NCODE_EFFORT` (else `SWARM_EFFORT`;
    blank, malformed or multi-line values are ignored) in memory (`env_effort/0` =
    `%{value:, name:}`), like the `--model` override. `overlay/1` puts it on a conversation whose
    `effort` is nil, so every turn start that already goes through the overlay (backend send,
    queue drain, dispatcher's swarm/goal/plan launches) really runs at it. Chat slot only: the
    worker slot has its own Settings default (`efforts.sub_agent`) and no env name. Nothing is
    written; `/effort <level>` wins; `/effort default` (nil) goes back to the env level.
  - `SessionConfiguration.effective_effort(conversation, :chat | :swarm)` =
    `{level, :conversation | :env | :default}` with the engine's chain.
  - `workspace_metadata/2` sends `effort_effective`/`effort_source` and the swarm pair beside the
    stored `effort`/`swarm_effort` (now read from the stored row, not the overlaid one). The live
    launcher's workspace sends `effort_effective` = its run effort (source nil).
  - Client: `DTO.WorkspaceSnapshot`/`WorkspaceMetadata` fields (optional on the wire, so an older
    daemon still decodes), the codec's optional-key lists, the fake, and the status line
    (`projector/status.ex`) shows `effort_effective || effort`.
- "If an env value overrides a later `/effort`, say so": with this chain it never does (the
  conversation's value wins), so no notice is needed. X's `/effort default` notice can name the
  level it falls back to from `effort_effective`/`effort_source` (`:env` = `NCODE_EFFORT`).
- Not changed (outside Y's row, for the integrator): Settings' row "Effort · this conversation"
  (registry `session.effort`, layers `[:session, :global, :default]`) does not show the env
  layer; README's env table has no `NCODE_EFFORT` row (proposed: "`NCODE_EFFORT` (`SWARM_EFFORT`) |
  This session's chat effort while the conversation has none of its own (`/effort` wins); the
  unsaved launcher's runs use it too"). A chained turn after an automatic `/compact` reloads the
  conversation inside the synced engine (`engine.ex` `run_chained_turn/5`) and so runs without the
  env level, exactly as it already loses a `--model` override.

## F5 quit summary after a rewind: root cause and fix

Reproduced first (`daemon/service/cli022_quit_summary_test.exs`: real persisted backend, loopback
model writing `NOTES.md` then creating `new.md`, `rewind.apply` with scope `files`, then
`PersistedSession.exit_summary/3`; 2 tests failing before the fix).

- Cause: `release/persisted_session.ex:888-893` (at `4fd44d18`) listed `SELECT DISTINCT path FROM
  checkpoints WHERE conversation_id = ? AND inserted_at >= <session start>`. A checkpoint row is
  the file before a write; a rewind (`Checkpoints.restore_run_report/2`, synced) restores the files
  but keeps the rows, so a restored file stayed "changed".
- Fix (`net_changed/3`): the net change, not the cheap "drop what a rewind restored" rule. For each
  path the session's first row (`ROW_NUMBER() OVER (PARTITION BY path ORDER BY inserted_at,
  rowid)`) is the file before the session touched it: left out when the file now has exactly that
  content (size compared first, the file read only when it matches; content from the row by
  `rowid`), or when there was no file then and there is none now. Kept (listed) when the row is not
  restorable (binary or over 2 MB), the path is outside the project root (as stored or its real
  path), the file is a symlink, or anything cannot be read. At most 200 paths, as before. So a hand
  revert also drops out, and a file changed again after a rewind is listed again.

## F6 sparkline samples: root cause and fix

What one bar means: one finished, measured model call. The desktop's speed monitor
(`speed_monitor.ex`, read-only) shows the latest finished call's tok/s per slot and a "live
estimate" while one streams; there is no per-second series. The CLI already draws a streaming
call's estimate as the provisional newest bar and stores only finished calls.

Reproduced (`daemon/service/cli022_vitals_samples_test.exs`, the real synced `Speed` with a fake
clock and the real `Vitals`). The 1/s emit limit drops nothing: `Vitals` absorbs every
`{:speed_sample, …}` as it arrives, not on ticks. Two causes instead:

1. CLI (fixed): `vitals.ex` `absorb/3` marked a sample `{at, tps}` with `at` in whole seconds; a
   second call finishing in the same second at the same rate (the QA gateway's equal speeds) was
   taken for the first and dropped, though `Speed` published it (its ttft differed). The mark is now
   the whole value (`at`, `tps`, `ttft_ms`, `model`).
2. Synced, OPEN (needs the desktop): `domain/llm/speed.ex` `publish/2` (`shown =
   Map.merge(conv.exact, conv.live)`, line ~361 here, `lib/swarm_code/llm/speed.ex` on the
   desktop): while another call of the same slot streams (for over a second), its live estimate
   replaces the exact value of a call that just finished, and the next exact value overwrites it in
   `conv.exact`. Two parallel workers (the QA's lead spawns two at a time) give one bar per pair:
   4 worker calls, 2 bars, as QA saw. The repro test pins this (`published == [60]`).
   Desktop change needed (no UI change on the desktop): in `SwarmCode.LLM.Speed`, in both
   `handle_cast({:finish, …})` and `handle_cast({:finish_bare, …})`, right where a measured
   `value` is built (the `if ok? and window >= @min_window_ms and tokens > 0` branch and the
   `window >= @min_window_ms` branch), also broadcast it on the same topic:
   `Phoenix.PubSub.broadcast(SwarmCode.PubSub, @topic, {:speed_call, cid, role, value})` (as `publish/2` does at desktop `speed.ex:368`)
   (`value` = the same `%{tps:, ttft_ms:, model:, at:, live?: false}` map). Subscribers that only
   match `{:speed_sample, …}` (the desktop's LiveView) ignore it. The CLI's `Vitals` already takes
   `{:speed_call, cid, slot, value}` (one sample each, never merged; a later `speed_sample` with the
   same value is not counted twice; tested with the message itself). After the next
   `provenance.sync`, flip the repro's last two assertions to `[50, 60]`.

Also (U's `ui/projector/vitals.ex`): a lone sample drew a full block; it is now at most half height
(`▄`, level 3 of 8), lower values as they are; two or more samples keep the shared scale. Chosen
over "newest bar on an empty track" because an idle row already sits on the track glyphs, so half
height still reads as "measured once".

## Stubs

None. The `{:speed_call, …}` clause in `Vitals` is live code waiting for the desktop change above
(nothing sends it today); it is not a stub of another lane's seam.
