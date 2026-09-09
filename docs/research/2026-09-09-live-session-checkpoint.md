# Live development session checkpoint

The CLI now has a real, explicitly unsaved development launcher:
`scripts/dev/run_live_session.sh`. It connects the native terminal to
`DataSource.Daemon`, a private Unix socket, `Service.LiveBackend`, and real
`Runtime.Run` provider/tool execution. Provider configuration comes from the
environment. No canonical database is opened; the existing Repo gate stays closed.

## Current evidence

- `mise exec -- mix test`: 119 core + 501 daemon + 568 CLI tests, 5 properties,
  no failures (seed 735225).
- `mix compile --warnings-as-errors`, formatter, dependency-lock check,
  provenance verifier (216 records), native schema snapshot checks (12), and both
  Unicode source checks passed.
- Real socket acceptance verifies prompt -> provider tool request -> approval ->
  `write_file` -> approval -> actual shell verification -> final response -> new
  client reconnect to daemon-owned memory. It checks file contents and tool output.
- Native live terminal PTY test sends a real prompt through the composer and
  verifies the loopback provider response is visible before clean terminal exit.
- Native terminal Port suite: 14 checks passed; synthetic terminal demo: 8 passed.
  One earlier suspend/resume observation timed out during concurrent tests; rerun
  passed. Full platform acceptance remains open.
- Actual terminal text capture was inspected in ego-lite; the dedicated task
  space (3) was closed with `done:true`. No daily sessions/cookies were cleared.
- Web checkout still shows only its pre-existing untracked `.specs/` directory.
- Feature catalogue and slash dispatcher slices are now real: `FeatureCatalog`
  exposes scoped, bounded workflows, research, schedules, settings, usage,
  changes, checkpoints, and MCP projections; `/review`, `/goal`, `/plan`,
  `/consensus`, `/ultra`, workflow controls, custom commands and the other
  built-ins dispatch through persisted Domain APIs. The dispatcher fixture suite
  is 8 tests; the feature catalogue suite is 9 tests.
- The CLI has a typed feature query protocol, strict `LibrarySnapshot`/`LibraryItem`
  DTOs, and a live switcher modal with paging/refresh. The socket settings test
  verifies credential redaction and unavailable persistence is an explicit typed
  error.

## Fixes found by integration

The launcher originally omitted `ProviderCaps` startup; the first real model call
failed on a missing ETS table. Starting the daemon application's process-local
infrastructure fixes it without opening storage. The TUI title now accepts a
validated live banner instead of always showing the synthetic-data banner.

The historical renderer audit incorrectly treated dependency `include` symlinks
created by Mix as rejected renderer artifacts. It now ignores dependency headers
while retaining CLI/renderer findings, with a regression test. Generated links
were restored before verification.

## Native storage predecessor

`vendor/exqlite/c_src/swarm_binding_experimental.c` and its standalone harness are
private, macro-gated, and absent from production NIF/adapter paths. Strict compiler
and ASan/UBSan runs exercise descriptor-relative WAL commit/reopen, canonical SHM,
crash recovery, rollback journal, one-use open, revocation, and main/WAL replacement.
This is still one-connection experimental code. See `vendor/exqlite/test/native_binding.md`
for remaining pool, ownership, close-error, and lease integration obligations.

## Review rulings

- Provider endpoint defaults are intended user-facing configuration. The work's
  no-remote-call restriction applies to agent verification; every acceptance call
  used loopback. Merely launching the TUI sends no provider request. Submitting a
  prompt with a user-selected model/key is the requested functionality.
- `Scope.generation` is a client view correlation value, incremented by
  `UI.Reducer.Watch` on navigation. It is not a daemon database generation. The
  daemon validates membership and node/approval revisions; the socket/client
  validates exact scope correlation. Forcing it to zero would break navigation.
- Request identity is immutable even for rejected commands. A corrected command
  must use a fresh identity; reusing one with a changed payload is a conflict.

## Remaining objective

The full port is **not complete**. Production writable NIF/Repo binding, durable
admission and history/restart, migrations/new-database startup, complete multi-turn
context, six real modes/swarm/plan/consensus/goal/Ultra, workflows, research,
schedules, MCP, Git/checkpoints, settings/usage, attachments, memory, all slash
executions and packaged releases still need end-to-end integration and evidence.
The development launcher is an implementation milestone, not a substitute for
those requirements.
