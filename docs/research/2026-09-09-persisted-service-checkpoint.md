# Persisted service and feature-command checkpoint

This slice remains inside the CLI checkout and does not import or modify the web
checkout at runtime.

Implemented:

- `SwarmCode.Daemon.Service.PersistedBackend` requires an already admitted,
  supervised Domain Repo and projects bounded persisted runs, messages, nodes,
  agents, approvals and questions through the existing socket protocol.
- SQL projections cap run/history/agent pages and fetch detail windows by byte
  offset. Provider text and reasoning deltas remain visible before a run finishes
  through bounded in-memory overlays.
- Slash dispatch now reaches the persisted Domain engine, including multi-turn
  context, plan/goal/swarm/consensus/workflow/research routing, controls and
  request deduplication within a service epoch.
- `feature.command` is a closed, validated protocol operation. Settings, workflow,
  research, schedule and checkpoint actions are scoped to the admitted project or
  conversation. The TUI library renders rows, action controls and destructive
  confirmations.
- Pending approval/question data is a bounded projection with secret redaction and
  exact interaction-node matching. Socket tests validate real responses with the
  strict CLI Codec, including streamed node updates.
- The native predecessor now exposes an opaque owner-bound `DatabaseBinding`
  resource with identity pinning, lease retention, owner-death revocation and
  fail-closed `:database_binding` adapter handling. It deliberately does not claim
  production SQLite connection promotion until the descriptor-relative VFS,
  pool/reconnect attestation and close-error quarantine are complete.

Verification:

- Broad suite run: core **121 tests**, daemon **534 tests**, CLI **575 tests and
  5 properties**, all passed. Backend fixes made during that run were verified
  afterward with the focused acceptance suite.
- Persisted backend acceptance: **9 tests, 0 failures**.
- Compile with warnings-as-errors, provenance verification and `git diff --check`:
  passed.
- Terminal port/unit and PTY suites: passed.
- Native binding strict production build and focused BEAM tests: **3 tests, 0
  failures**.
- Ego-browser inspected the live terminal capture and the dedicated task space was
  closed. User browser sessions/cookies were not touched.

Still required for the full objective:

- Production Foundation-to-Repo startup using the real descriptor-relative SQLite
  binding, new-database/migration handling, connection and cleanup attestation.
- Durable command request identity across daemon restarts, conversation/project
  creation and selection, restart recovery, and a persisted production launcher.
- Command-selection results (`/goal` report, rewind, research selection), complete
  question/plan gates, attachments and memory integration, and persisted composer
  mode/model metadata.
- Feature creation/editing forms and complete workflow, swarm, Ultra, consensus,
  deep research, schedules, MCP, Git/checkpoint, provider/settings and usage flows.
- Installable release packaging and supported-platform verification.

The current development launcher remains explicitly `LIVE · UNSAVED`; the new
backend is exercised against disposable fixture databases and is not yet its
production execution path. Do not mark the parity plan or active goal complete.
