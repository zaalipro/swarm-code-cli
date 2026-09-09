# Feature service and command integration checkpoint

This slice adds real persisted Domain command APIs and a typed feature-library
query path. It does not complete the requested port.

Implemented:

- `Service.CommandDispatcher` resolves all sixteen built-ins, project/global
  custom commands, and workflow aliases using the extracted Domain engine and
  contexts. Navigation/selection results are explicit. Tests use a fixture Repo,
  a real loopback model, and persisted workflow rows.
- `Domain.FeatureCatalog` provides scoped, bounded rows and underlying command
  APIs for workflows, research, schedules, settings, usage, changes, checkpoints,
  and MCP. Settings and MCP credential values are excluded from query projections.
- `feature.query` now crosses the closed protocol, socket service, strict client
  codec, and `LibrarySnapshot`/`LibraryItem` DTOs. Unknown keys, features, actions,
  mismatched feature replies and oversized results are rejected.
- Live `Ctrl+K` entries open library modals with paging/refresh and explicit
  unavailable states. Closing drops pending query identity; late replies cannot
  replace the current conversation. `/workflows` and bare `/deep_research` open
  library views. Unsupported unsaved slash modes are rejected before network
  execution; there is no fake swarm/goal/consensus implemented as a plain prompt.
- The native binding prototype now supports eight SQLite handles with per-handle
  SHM masks, aggregate POSIX lock accounting and replacement connections. It is
  still private experimental code, absent from production NIF/adapter paths.

Verification during this slice:

- Core suite: 120 tests passed.
- Final CLI suite: 573 tests and 5 properties passed (seed 162545).
- Feature catalogue: 9 tests passed, including actual no-model workflow completion,
  scoped persistence, checkpoint restore and redaction.
- Command dispatcher: 8 tests passed, including actual custom/review model turns.
- Library socket acceptance: 2 tests passed, including persisted settings and
  unavailable storage without losing the client.
- Library UI tests pass, including request correlation, closing and slash navigation.
- Live terminal PTY smoke passes through prompt, response, Settings navigation,
  unavailable state and clean exit. Native Port/demo PTY suites pass (14 + 8).
- Native binding strict build and ASan/UBSan pass: multi-reader snapshots,
  replacement, writer contention, capacity, close-busy, shared locks, WAL crash
  recovery, revocation and namespace replacement refusal.
- Compile with warnings-as-errors, format, provenance and diff whitespace checks pass.
- Ego-lite inspected the actual terminal library capture in task space 6, then
  closed it with `done:true`. Daily browser sessions/cookies were untouched.

The next storage step must implement the actual opaque NIF resource and Exqlite
connection route, with lease/owner lifetime and pool/reconnect attestation. A
stubbed unavailable binding API or ordinary pathname reopening does not satisfy
that step. A persisted service backend must then connect the Domain dispatcher
and run events to the TUI. Feature mutation controls, complete multi-turn context,
all mode flows, migrations/restart and release packaging remain incomplete.
