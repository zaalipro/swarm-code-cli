# Fix round, lane S (daemon, wire and gate): notes

Branch `cli020/fixS` from CLI main `55dbe5a2`, worktree `~/dev/swarm-code-cli-wt/fix-S`.
Every task has a test that failed first. Gates that ran are listed at the end.

## Per task

### S1 `--approval <mode>` reaches queued prompts, queued commands (done), workflow runs and /compact (not changed, see below)

- `PersistedBackend.start_queued/3` now takes `approval_opts(state)`: a queued prompt starts through
  `Engine.start_chat_turn/4` with `approval_mode:`, a queued slash command through
  `CommandDispatcher.dispatch/3` with it. `retry_run`'s swarm branch (`Engine.start_swarm/3`) also
  passes it (it was the one other session-started run that dropped it).
- **A bug the finisher's B23 stub left behind**: `CommandDispatcher.valid_options?/1` only allowed
  `@allowed` keys with list values, so `approval_mode: "auto"` made every dispatched slash command
  in an `ncode -p --approval ...` session return `{:error, :invalid_request}`. It has its own clause
  now (a real mode, once). Tests: `daemon/service/fix_s_approval_test.exs`.
- **Workflow runs: needs a desktop engine change, not done (as the brief says).** `Workflows.launch/1`
  (`domain/workflows.ex`, derived) takes no `approval_mode` and `start_run/8` builds a payload without
  `approval_override`, so a workflow run always decides in the project's mode. The desktop-first
  change: `launch/1` accepts `attrs[:approval_mode]`, runs the same check as
  `Engine.check_approval_override/2` (make it public, or move it to `Projects`), and puts
  `approval_override: attrs[:approval_mode]` into the `start_run` payload (the RunServer already reads
  `Map.get(state, :approval_override)` and `Operation.current_mode/1` honours it). Then the CLI side is
  one line: `execute(conv, %{action: :launch_workflow}, opts)` adds `approval: approval(opts)` to the
  `Workflows.launch(%{...})` map. AGENTS.md still says "workflows and `/compact` keep the project's
  mode"; that stays true until then (finisher edits AGENTS.md, not this lane).
- **`/compact` needs nothing**: the compactor is `root_spec(%{run: %{kind: "compact"}})` with
  `tools: []` and `max_turns: 1`, a plain completion; there is no approval decision to carry. An
  automatic compaction before a send chains the send with its `opts` (`run_chained_turn`), so the
  mode reaches that turn already.

### S2 retry line names the HTTP status

- The reason word is all the op node ever received (`{:retry, attempt, of, reason}`), and the status
  exists only in the HTTP layer, so the fix cannot live in the daemon. **Outside my row, smallest
  change: a recorded CLI provenance patch on the derived `domain/llm/http.ex`** (one call site and a
  3-line private function, `shown_reason/2`): the retry callback gets `message` (`"HTTP 500"`) when
  the retry came from a status, else the reason word (`stream ended early`, `network`). The error
  class and the final failure text are unchanged. Test: `daemon/fix_s_retry_status_test.exs` (500,
  429, early end, give-up).
- Needs upstreaming to the desktop (Q3 desktop-first; the desktop's op detail has the same
  `retrying 2/5 · server`). Until then this is a CLI patch: `provenance/patches/.../llm/http.ex.diff`.
- **Merge note for the integrator**: lane L also edits `domain/llm/http.ex` (L2 patches). The two
  source edits are in different places and merge as text; then regenerate, never hand-merge the
  patch file or the ledger: `mix swarm_code.provenance.sync --ref 7b8f379f5ed5976a191c08708af824d10b919633`
  (records the combined patch), then `mix swarm_code.provenance.sync --check` and `verify`.
- The frozen live-runtime copy (`lib/swarm_code/llm/http.ex`) still says `server`; lane L removes it.

### S3 a manual mode pick trusts the project, and the notice says so

- New `Daemon.Service.ApprovalPick.pick/2`: `Projects.update(approval_mode)` then
  `Projects.mark_trusted/1`, exactly the desktop's `set_approval_mode` (spec 67 T31 G44). The notice
  is `Approvals: read-only → auto · this project is now trusted` only when the project was untrusted;
  an already trusted project keeps `Approval mode: auto` (pinned by existing tests).
- Used by `project.update` with an `approval_mode` (Shift-Tab, the `/approval` picker) and by the
  typed `/approval <mode>` command, so the two cannot disagree. `project.update` with
  `trusted: true` (`/trust`) is unchanged.
- Like the desktop, **any** pick trusts, including `read-only`; `/approval read-only` in a fresh
  project therefore also trusts it. I kept desktop parity on purpose; say so if you want read-only
  picks to leave trust alone.
- `Fake.Session` (ui/data_source) does the same, so the demos agree with the service
  (`ui/data_source/fix_s_fake_trust_test.exs`). Two older tests were updated for the new words:
  `pass70_conversation_test` ("the approval mode changes the project...") and
  `pass70_session_commands_test` ("/approval reports and changes the mode...").
- For lane U (U1): the client keeps preferring its own `Approvals: a → b` words when it has them
  (`recent_policy_words/1`) and only shows the daemon's text when it has none. The trust part of the
  daemon's sentence is therefore dropped by `settle_service/3` today; U1's single notice should
  append ` · this project is now trusted` when the daemon text contains it (or when the outcome's
  project was untrusted).

### S4 database file mode has its own sentence

- `Schema.Refusal.database_mode/1`: message `Your conversations database file has the wrong
  permissions.`, action `Run: chmod 600 <path> and then run ncode again; nothing was changed.` (the
  path is shell-quoted when it has a space or a quote, for `Application Support`). Code stays
  `:schema_incompatible`.
- `Schema.Probe.regular_stat/2` and `sidecar_stats/2` return it for a regular file of this user with
  a mode other than 0600 (main file first, then `-wal`, `-shm`, each naming its own path); another
  owner, a symlink or a directory keep the general refusal. It is raised in the probe, before any
  schema judgement. The action names the physical (resolved) path.
- **Outside my row, one line**: `Release.PersistedSession.startup_words/3` recognises actionable
  refusals by message, so `database_mode("")` is added to its list (otherwise the generic "comes from
  an ncode version this ncode does not know" would still print). Test:
  `persisted_session_release_test.exs` ("a stray or damaged database file is said as such").

### S5 DriftTest leaves nothing

- `@moduletag :tmp_dir` stays; an `on_exit` removes the test's directory and then its (and `tmp/`'s)
  parent only if empty. Verified: after the run `apps/swarm_code_core/tmp` does not exist. Note
  `C74CliFileTest` (not mine) uses the same tag and leaves `apps/swarm_code_core/tmp/` in the
  main checkout; same two-line fix if wanted.

## Provenance

- `daemon/service/command_dispatcher.ex` (frozen entry) edited: repinned with
  `mix swarm_code.provenance.repin`.
- `domain/llm/http.ex` (derived) patched (S2): patch recorded by syncing at the pin.
- Merge: conflicts in `provenance/extracted-files.json` or `provenance/patches/**` are resolved by
  re-running repin / sync as above, never by hand.

## Observations (not changed)

- `erl_child_setup: failed with error 32` (EPIPE) appeared once in the S1 test run while a command
  port started; harmless there, but it is the symptom lane R's brief describes when an app holds many
  pipes.
- `ApprovalPick` is a new CLI-only file (not in the ledger).

## Gates that ran (worktree `fix-S`, HEAD before this note's commit `671d54d0`)

- `mix format` and `mix format --check-formatted`: clean.
- `mix compile --warnings-as-errors`: clean.
- `mix swarm_code.provenance.verify`: pass. `mix swarm_code.provenance.sync --check`: pass (after the
  `llm/http.ex` patch was recorded and `command_dispatcher.ex` repinned).
- Focused tests, one app per call: daemon 126 tests (gate, refusal, fix_s_approval, fix_s_retry_status,
  pass70_conversation, pass70_session_commands, pass70_qa_queue, read_only_ask, command_dispatcher,
  c020_dispatcher, retry_run, queue, c020_projection): 0 failures; cli 37 (persisted_session_release,
  fix_s_fake_trust, pass70_fake, pass73_delivery): 0 failures; core drift test 5: 0 failures and
  `apps/swarm_code_core/tmp` absent afterwards.
- Not run: the full suite / `mix precommit` (finisher's, slot rule), `keymap --check` and
  `settings --write` (no binding or registry touched), PTY suites, `check_terminal_port.sh`.
