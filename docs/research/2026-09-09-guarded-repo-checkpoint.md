# Guarded Repo and restart checkpoint

The CLI checkout now contains a descriptor-relative SQLite connection route and
an existing-database Foundation-to-Repo launcher. The normal terminal launcher is
still the explicit unsaved development session; this checkpoint is not a full
product/release completion claim.

Implemented in this slice:

- Native DatabaseBinding acquires the canonical basename beneath the retained
  data directory, issues one-use PID-bound connection tickets, attests every
  query/step as well as connection initialization, and retains lease ownership
  through SQLite/statement cleanup.
- The VFS supports concurrent WAL connections, exact sidecar identities, bounded
  SHM mappings, last-mapper SHM removal and observable close uncertainty. A close
  syscall observer preserves pinned Unix inode/unused-FD bookkeeping while
  uncertain closes retain the lease in quarantine.
- CrossAppLease seals creator-bound admission into a one-use Repo generation,
  validates actual DBConnection pool/slot membership, authorizes replacement
  connections, and records initialized slots. Native resources never leave their
  owning process as raw startup authority.
- RepoLauncher runs Foundation admission, starts a private Repo using fixed
  guarded options, waits for all slots, then publishes that Repo for Domain
  processes. It confirms Repo termination before binding/lease cleanup and
  reports a bounded cleanup-pending owner when retained resources remain.
- CommandLedger preserves stable command identities and results across backend
  restarts. Interrupted reservations return outcome_unknown. The exact optional
  CLI metadata schema is validated before being excluded from the web schema
  fingerprint; arbitrary same-prefix objects are not ignored.
- Persisted stream append/reset events preserve channel, identity and credit
  ordering through the strict client codec.
- SessionSelection creates/selects projects and resumes, creates or selects a
  conversation, using canonical project paths and scoped IDs.
- The unsaved development launcher has --help and requires an explicit endpoint
  for the selected provider. LiveBackend membership accepts client navigation
  generations while refusing invalid/foreign scopes.

Fresh focused root verification:

- Guarded Repo: 4 tests pass, including a real three-connection write/reconnect/
  close/restart and coordinator-death cleanup followed by reacquisition.
- Native cached-query regression: 10 binding tests pass. Full native test/prod
  feasibility was rerun by the native implementer after close and SHM fixes.
- Persisted backend/ledger: 18 tests pass; client codec/watch: 19 tests pass.
- Session selection: 3 tests pass. Live backend: 11 tests pass.
- Compile with warnings-as-errors and provenance verification pass. Bash syntax
  and actual development --help invocation pass. git diff --check passes.

The wider regression log is _build/startup-regression.log (active process must be
polled before treating it as completed).

Remaining before a usable saved product launch:

1. New-database creation and verified migration startup through the same guarded
   ownership path. Foundation currently refuses these cases explicitly.
2. Real supported-platform identity/desktop detection and production private
   directory creation. The macOS default detector remains unavailable; tests use
   explicit disposable fixture identity/detector settings.
3. Saved daemon/TUI entrypoint, provider configuration, session selection and
   detach/reconnect behavior using the guarded Repo plus PersistedBackend.
4. Full feature mutation forms and end-to-end coverage for the six modes, swarm,
   planning gates, goals, workflows, research/attachments, schedules, settings,
   providers, usage, MCP, Git/checkpoints and memory.
5. Installable artifacts, supported-platform acceptance and final precommit,
   terminal PTY and ego-browser verification. Browser sessions/cookies must never
   be cleared; close only dedicated task spaces.

No changes to the web checkout or daily database were made in this slice.
