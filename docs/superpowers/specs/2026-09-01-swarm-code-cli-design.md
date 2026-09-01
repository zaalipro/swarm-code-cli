# Standalone SwarmCode CLI/TUI — architectural design specification

**Status:** Architecture approved; written specification awaiting owner review  
**Date:** 2026-09-01  
**Target repository:** `~/dev/swarm-code-cli`  
**Desktop compatibility surface:** one new numbered document under `~/dev/swarm-code/.specs/`; no desktop implementation changes are part of this project

## 1. Product contract

SwarmCode CLI is a standalone, local-first Elixir/OTP application with a full-screen terminal UI, an append-only plain-text interface, and versioned headless commands. It preserves the current SwarmCode domain behavior: projects, conversations and history; chat, Goal, Swarm, Plan, Consensus, Workflow, Ultra, Compact and standalone Deep Research; streamed text and reasoning; questions and approvals; agents, operations, files, Git, checkpoints, worktrees and attachments; MCP; providers and search; schedules; usage, pricing, storage, settings and administrative actions.

“Full parity” means the same persisted semantics, ownership, ordering, gates, replay behavior and inspectable failures. It does not mean reproducing browser-only pixels, hover behavior, native window controls or CSS animation. GUI-only mechanisms are replaced by keyboard-complete terminal equivalents.

The release contract is:

- macOS 14 or newer and Ubuntu 22.04 or newer;
- native arm64 and x86_64 artifacts for both operating systems;
- ERTS and the Elixir applications needed at runtime are bundled; users do not install Erlang, Elixir, Mix, Rust or a compiler;
- the bundle is an application runtime, not a general-purpose `elixir`, `iex` or `mix` toolchain;
- supported system Git is a prerequisite for Git features; `gh` and runtimes needed by user-selected MCP servers remain optional and user-provided;
- immutable public GitHub Release assets require no account, token or login;
- the primary direct install is one no-root HTTPS shell command. Public download access never means unverified bytes.

The existing desktop repository remains implementation-unchanged. Core extraction and all executable work occur in the new repository. The only permitted desktop-repository change is a numbered compatibility specification describing the reciprocal lease, schema and credential handshake the desktop must later implement.

## 2. Chosen architecture

Use a provenance-preserving extraction of the current domain core, a long-lived per-user local daemon, and disposable clients. The new umbrella contains:

- **`swarm_code_core`** — Repo and schemas, providers, search, tools, Git/files, MCP, run/agent engine, command dispatcher, conversation coordinator, workflows, research, schedules, storage, typed events and query projections.
- **`swarm_code_daemon`** — startup gate, cross-application data lease, schema handshake, migrations and recovery, credential broker, local IPC, service integration and notifications.
- **`swarm_code_cli`** — argument parsing, ExRatatui presentation adapter, plain presenter, NDJSON/headless commands, help/completion, updater and installer-facing commands.

A single installed Mix release can expose several boot modes, but these ownership boundaries remain distinct. Phoenix, LiveView, Bandit, `elixir-desktop`, wx, browser assets and desktop-window code are not included.

The core is extracted at the exact upstream commit current when implementation begins; the audit baseline is `f51c8d48eb666e538ac987cac17e512c55c7702d`. Every copied file records upstream path, commit and SHA-256 in a machine-readable provenance manifest. Focused Fake-driven tests and normalized golden fixtures move with it. No source is copied into a public repository until the owner records extraction authorization, copyright, license and NOTICE terms. If authorization is absent, the same interfaces and acceptance suite are implemented clean-room from numbered specs instead; public release does not proceed with unlicensed copied source.

The core boundary is larger than `lib/swarm_code/engine/**`. Command parsing and precedence, workflow slash routing, queued-turn draining, edit/resend, mode transitions, plan gates, transcript projection and safe Markdown currently crossing the LiveView boundary move into core services.

## 3. Runtime ownership and supervision

Production runs one non-distributed daemon per canonical database. TUI, plain and headless invocations are clients. Closing or crashing a TUI cancels only view-owned requests and subscriptions; it does not stop daemon-owned runs, research or schedules. A user who wants to switch to the macOS desktop must first stop the CLI daemon cleanly so it releases the canonical database lease.

```text
SwarmCodeCLI.RootSupervisor (:rest_for_one)
├── FoundationSupervisor
│   ├── PathsAndIdentity
│   ├── CrossAppLease
│   ├── MigrationAndSchemaGate       # Ecto.Migrator.with_repo/backup/handshake
│   ├── SwarmCode.Repo               # starts only after the gate succeeds
│   ├── CredentialBroker
│   ├── EventHub
│   ├── SwarmCode.Registry
│   └── owned task/job supervisors
├── BootstrapGate
│   └── integrity, recovery, seeds, stale claims, cleanup intents, approved MCP startup
├── RuntimeSupervisor
│   ├── SwarmCode.Engine.RunSupervisor
│   ├── ConversationSupervisor
│   │   └── one ConversationCoordinator per active/queued conversation
│   ├── SwarmCode.Research.Supervisor
│   ├── WorkflowSandboxSupervisor
│   ├── SwarmCode.MCP.Supervisor
│   ├── Workflow watchdog
│   ├── Scheduler
│   └── storage, cleanup and notification job supervisors
└── DaemonSupervisor
    ├── owner-only Unix-socket listener
    └── one bounded client supervisor per connection

Client process
└── SessionSupervisor
    ├── TerminalOwner
    ├── Projection/reducer
    ├── EventBridge
    └── renderer adapter or plain/NDJSON presenter
```

Within a run, preserve the existing significant-child topology and terminal semantics:

```text
RunSupervisor
└── RunSup (:one_for_all, temporary, auto_shutdown: :any_significant)
    ├── AgentsSup
    │   └── AgentSup (:one_for_all)
    │       ├── per-agent operation Task.Supervisor
    │       └── AgentServer (temporary, significant)
    ├── per-run auxiliary workers
    ├── workflow Runner when applicable
    └── RunServer (temporary, significant)
```

Every task, port, process group, socket, timer, monitor, queue entry, spill file and subscriber has one owner and one settlement path. State owners do no filesystem, Git, network, external-process or long database work in callbacks. They admit monitored workers, store `{generation, request_ref, monitor, absolute_deadline}`, and accept only the exact matching result. Cancellation invalidates the generation first, freezes admission second, terminates descendants third and settles callers once.

The scheduler is a coordinator: at most one tick worker is active, long launch/reconciliation/retention work is monitored outside its callback, and scheduled occurrence uniqueness remains enforced in SQLite. Work intentionally surviving a run is represented by an idempotent durable cleanup intent, never a detached task.

Model-authored Elixir workflows never execute through `Code.eval_*` in the core VM. Each runs in a disposable, non-distributed child BEAM with no inherited credentials, project write access or network. A length-prefixed JSON broker is its only effect channel. The daemon owns workflow budgets, journal entries, capabilities, agent launches, gates and cancellation, and kills the child process group on stop.

## 4. Core interfaces

### 4.1 Command and launch boundary

All interactive and headless launches use one core dispatcher. A command contains a stable request UUID, source, conversation/project scope, text, attachment and research references, optional reply/steer target and queue intent. It returns one of:

- `accepted` with durable message/run/goal/workflow/research identifiers;
- `needs_input` with a typed interaction schema;
- `rejected` with a stable error code and corrective action;
- `outcome_unknown` only when an external non-idempotent effect may have occurred.

`CommandDispatcher` owns built-in/custom/workflow command precedence, the six mutually exclusive modes, Goal creation, edit/resend supersession, explicit fork, queueing and launch routing. `ConversationCoordinator` starts the next queued turn after the scoped terminal event even when no client is attached.

Launch is an idempotent state machine. One `BEGIN IMMEDIATE` transaction creates the initiating message, assistant placeholder, run/goal links and unique `starting` intent. The supervised owner acknowledges admission; a compare-and-set advances it to `running`. Admission failure performs one compensation transaction and leaves an inspectable failed run. Bootstrap settles committed `starting` intents without a valid owner. Events are emitted only for committed state.

### 4.2 Run control

The daemon exposes scoped `pause`, `continue`, `resume`, `stop`, `stop_agent`, `steer`, `answer_question` and `resolve_approval` commands. Pause finishes the current indivisible LLM/tool step and holds before the next; continue releases held work; resume creates the documented continuity run; stop structurally terminates descendants and writes a truthful terminal state. A client never makes policy or liveness decisions locally.

### 4.3 Query/read model

Queries return page-limited DTOs, not Ecto structs or complete GenServer state. Surfaces include projects, conversations, transcript windows, run summaries/details, pending interactions, workflows, research, schedules, usage, storage and settings. Large source, result, reasoning, log and diff fields are fetched by explicit detail request. Pagination is keyset-based and stable under concurrent inserts.

### 4.4 Typed event protocol

The in-process EventHub publishes semantic envelopes containing protocol version, scope, revision, sequence, event type, request reference and occurrence time. Run flush ordering remains node changes, assistant text, reasoning, then run row; final message and goal settlement precede the terminal run event.

Daemon IPC uses a user-owned Unix socket at mode `0600` under a verified mode-`0700` runtime directory. It validates peer UID (`SO_PEERCRED` on Linux, `getpeereid` on macOS), a random daemon-instance nonce and protocol compatibility. Messages are length-prefixed versioned JSON with strict count, byte and nesting limits. Do not use TCP, HTTP, Phoenix, ETF from clients, distributed Erlang, cookies or EPMD.

Clients subscribe before requesting a snapshot, apply only matching scope/generation events, and request a new snapshot on sequence gaps. Slow-client pressure replaces derived queued events with `snapshot_required`; canonical content is never dropped. Approval decisions are server-side compare-and-set so multiple attached clients cannot answer twice.

### 4.5 Platform adapters

Core defines fixed behaviors for paths, credentials, notifications, event delivery, process/Git execution, Markdown/safe links, open-conversation presence, clock/UUID test seams and terminal capability discovery. Runtime input never selects modules or creates atoms.

## 5. Canonical persistence and desktop interoperability

### 5.1 Canonical paths

On macOS, both products use the existing canonical database sequentially:

`~/Library/Application Support/SwarmCode/swarm_code.db`

The CLI does not silently honor `DATABASE_PATH` in production. Explicit alternate database paths are limited to test, development and recovery commands and receive the same lease, permissions and handshake checks.

On Ubuntu, the canonical database is `${XDG_DATA_HOME:-$HOME/.local/share}/swarm-code/swarm_code.db`. Configuration, state, cache and runtime paths follow XDG; macOS uses Application Support, Logs, Caches and a verified per-user runtime directory. Directories are `0700`; database/WAL/SHM, sockets, logs, manifests, backups and spill files are `0600`; process umask is `077`.

CLI-only render caches, socket metadata, install receipts and UI preferences do not alter desktop-owned presentation fields. Project-authored `.swarm_code` files remain interoperable, with product/run-specific worktree subdirectories and atomic writes.

### 5.2 Exclusive cross-application lease

The desired protocol is one exclusive lease per canonical DB, held from before Repo/migrations/bootstrap until after runtime shutdown and Repo close. The lease uses an adjacent mode-`0600` SQLite lease file in rollback-journal mode. `CrossAppLease` opens it, verifies regular-file ownership and path confinement, executes a zero-timeout `BEGIN EXCLUSIVE`, and keeps that connection alive. Kernel process exit releases the lock; stale PID files never grant ownership. An atomically written owner record supplies only diagnostics: product, PID, process start identity, random nonce, database fingerprint, lease protocol, schema contract and start time.

Startup order on macOS is:

1. resolve and validate the canonical path;
2. detect any same-UID running `.app` whose bundle identifier is `com.zaali.swarmcode`, including its BEAM descendant, and refuse before opening the DB;
3. acquire the cross-application lease non-blockingly;
4. repeat desktop detection after acquisition;
5. complete schema handshake, backup/migration/recovery and only then open client admission;
6. hold the lease while the daemon, any run or the scheduler is alive.

Detection uses a bundled, signed macOS platform helper backed by `NSWorkspace`/`libproc`; it matches bundle identity and executable ancestry rather than a loose process-name substring. Refusal names the detected PID/application and instructs the user to quit the desktop. It never kills the desktop or overrides the lease.

The new desktop `.specs` document requires the desktop eventually to acquire this exact lease before its Repo, migrator, bootstrap, MCP or scheduler starts; perform the same schema handshake; refuse a CLI owner; and release only after complete shutdown. This project writes that specification but does not implement it.

**Safety limitation:** the current desktop does not honor the lease. The CLI's pre/post detection narrows the risk but cannot prevent the desktop from starting after the second check and opening the database while the CLI daemon is live. Until the desktop implements the compatibility specification, there is a residual startup race, concurrent desktop/CLI operation is unsupported, and the product must not claim cross-app exclusion is safe. The TUI, help, service onboarding and release notes must tell macOS users to quit the desktop before starting the CLI and stop the CLI daemon before reopening the desktop. No `--force` flag bypasses this warning or the CLI lease.

### 5.3 Schema handshake

The CLI preserves the complete historical desktop migration chain and the `SwarmCode.*` domain schema. An embedded compatibility manifest lists each known migration, schema hash, data-format epoch, minimum reader/writer versions and whether an additive migration is readable by the current desktop baseline.

Under the lease, startup verifies:

- canonical path/device identity and SQLite `application_id`;
- `schema_migrations` exactly matches a supported prefix plus explicitly compatible additive migrations;
- the handshake table's data epoch and minimum reader/writer versions admit this CLI;
- bundled SQLite source/version meets the release floor and foreign keys are enabled;
- no unknown newer or conflicting migration exists.

A legacy database without the handshake row is accepted only if its migration set and normalized schema hash match a signed legacy entry in the compatibility manifest. Establishing `application_id` and the handshake row is a migration and follows the backup gate. Unknown or incompatible schemas open only through an explicit read-only diagnostic command; normal startup refuses without changing bytes.

While the desktop does not implement the handshake, CLI migrations on the shared database are restricted to the audited desktop lineage or additive changes explicitly certified as readable by that desktop baseline. A change that reinterprets or removes an existing field, status or credential representation is held behind a new data epoch and cannot be activated on the shared database until the desktop compatibility implementation exists. This prevents the CLI from intentionally writing a format known to break the current desktop, while acknowledging that the current desktop cannot itself enforce the rule.

### 5.4 Migration and backup gate

Before every schema or persisted-data repair, with all work stopped and the lease held:

1. create a consistent SQLite online-backup snapshot, never a raw live-WAL copy;
2. harden it to `0600` and write a `0600` manifest containing source/application/schema IDs, SQLite source ID, sizes, SHA-256, migration list, row counts, `quick_check` and `foreign_key_check` results;
3. open the backup at an independent path, verify representative reads and an independently restorable copy, then fsync the backup and containing directory;
4. quarantine every changed legacy row losslessly before enforcing new constraints;
5. run transactional or resumable/idempotent migration batches;
6. repeat integrity, FK, count/checksum equations and a cold reopen;
7. retain the backup until a successful new-version boot is recorded.

Disk-full, corruption, failed verification or unknown-newer schema stops new work and enters an inspectable read-only recovery mode. The application never resets, recreates or silently repairs the user's database. Binary rollback checks schema compatibility and refuses rather than corrupting data; it does not silently restore an old database.

SQLite uses a small bounded read pool, serialized domain writer, `foreign_keys=ON`, local-filesystem WAL, busy timeout and `BEGIN IMMEDIATE` for allocation. Human-readable names and positions have constraints plus retry, never query-then-insert or `count + 1`.

## 6. Credentials and privacy

`CredentialBroker` stores opaque references in persistence and resolves secrets only inside the short-lived provider/search/MCP request worker. Adapters are macOS Keychain Services, Linux Secret Service/libsecret, isolated in-memory tests and environment/session-only headless input. If Linux Secret Service is absent or locked, persistent save fails with actionable instructions; there is no plaintext-file or SQLite fallback.

Secret save is two-phase: create, read back for equality, transactionally swap the reference, then delete the old secret; failures clean the new item or leave an idempotent cleanup intent. Exact configured values, `Authorization`/Bearer values, URL credentials and known credential shapes are redacted before logs, noncredential DB fields, events, terminal output and exceptions. Provider keys are stripped from shell, Git, workflow and MCP child environments and never passed in argv.

The existing shared macOS database can contain legacy plaintext secrets. Before the desktop implements reference-aware schema/credential handling, the CLI treats those values as frozen compatibility debt: it never creates or updates plaintext fields, never includes them in a new backup manifest/log, and prefers Keychain or session overrides. CLI-created credentials are references and may be unavailable to the unmodified desktop. A lossless, verified rollback quarantine may temporarily preserve legacy values only under the migration contract. A full shared credential cutover is activated only at a schema epoch both products understand.

No network telemetry is enabled by default. Local logs are structured, bounded, rotated, mode `0600` and redacted at event creation and sink. Diagnostic export is explicit and previewable.

## 7. TUI, plain and headless experience

### 7.1 Renderer boundary and go/no-go

Pin ExRatatui **0.13.0 exactly** for the prototype behind SwarmCode-owned `Cli.Ui.Scene` and normalized action intents. Renderer structs, NIF resources and framework key names never enter core or persisted state. The reducer owns only focus, scroll, draft, selection, responsive layout, modal state and subscriptions. It renders viewport windows rather than full history and coalesces redraws, not semantic events.

A native spike renders streaming chat/composer, swarm agents, consensus rounds and research report/source scenes on all four targets. A reproducible valid-input BEAM crash, native hang, persistent lost input, terminal corruption, broken Unicode editing, end-user compiler dependency or adapter-breaking API churn rejects ExRatatui. The first fallback is TermUI after its Unicode-width and paste/focus gates; when NIF isolation is the sole failure, use a supervised Ratatui OS-process sidecar with the same scene/action protocol.

### 7.2 Information architecture

The stable regions are title bar, optional Navigator, main viewport, optional unified Inspector and action deck. Inspector tabs are Thread, Agents, Timeline and Changes; a separate permanent side-chat column is allowed only on very wide terminals. The title bar always shows project/branch, conversation/page, mode and aggregate running/waiting counts. An Activity Center sorts Needs you, running/paused work, recent failures and completions.

Responsive behavior is structural:

- at 150 columns and wider: Navigator, Main and Inspector;
- at 100–149: Main plus either Navigator or Inspector drawer;
- at 72–99: one main surface with full-height overlays;
- at 50–71: survival layout with compact title, viewport, action strip and composer;
- below 50×14: resize/help/quit remain usable and `--plain` is offered.

No whole-screen horizontal scroll is permitted. Code, diff, raw JSON and wide tables can scroll independently. Auto-follow continues only while the viewport is at bottom; user scroll detaches it, shows an exact new-item count, and `End`/`G` rejoins. Async changes never reset drafts, selection, focus or logical scroll anchor.

Keyboard operation is complete: `Tab`/`Shift+Tab` cycles regions, arrows or `j/k` navigate, `Enter` activates, `Space` toggles, `Esc` closes one layer and restores focus, `Ctrl+K` opens the universal switcher, and every shortcut has a command/menu route. Enter sends; enhanced Shift+Enter and universal Ctrl+O insert newline; Alt+Enter and `/queue` queue. Modal focus is trapped, destructive actions default to Cancel and paste never auto-submits.

Only the renderer emits control sequences built from fixed enums. Model, repository, Git, web, command, MCP, filename, URL and log bytes become sanitized inert spans. CSI/OSC/DCS/APC/PM/C0/C1, carriage return, backspace, bidi controls and zero-width deception are exposed safely. OSC 8 links are generated only for validated destinations; OSC 52 clipboard write is explicit, bounded and opt-in under SSH/tmux.

### 7.3 Permanent alternative surfaces

`--plain` is append-only chronological text with stable headings, explicit prompts, no cursor rewriting and no control bytes. It is selected automatically for non-TTY or `TERM=dumb` and is the screen-reader acceptance surface. `--no-alt-screen`, `--ascii`, `--no-color`, `NO_COLOR` and reduced-motion modes are supported.

Headless commands invoke the same dispatcher/query/event APIs. Human output and versioned NDJSON keep diagnostics on stderr, include schema version/scope/sequence, fetch large detail separately and distinguish rejected, failed, interrupted and outcome-unknown exit codes. `--detach` returns the durable run ID; wait mode follows until terminal state.

### 7.4 Full-parity surfaces

All items below are release scope, even when delivered in later phases:

- project and no-project workspaces, instructions, memory and custom commands;
- persistent transcript/run cards, nested follow-ups, queue/history, reply/steer, explicit fork and edit/resend supersession;
- Build, Plan, Goal, Ultra, Workflow and Consensus as the six exclusive modes; Swarm, Review and Compact as actions; Deep Research as a separate background object/artifact;
- chat/swarm models and efforts, consensus planner/judge/optional implementer, rounds/checks, provider/search settings and image attachments;
- questions, approvals, Needs you, pause/continue/stop/resume, plan Approve→Assistant/Swarm/Revise/Decline;
- full swarm tree, operation/prompt detail, Timeline and Changes, checkpoints/rewind, worktrees, branches, merge/discard/PR;
- workflows with scopes, authoring, smoke/check, deterministic panels/budgets, structured output, journal/replay, gates, controls, Pipeline/Script/Journal/Result and built-ins;
- Deep Research Fastest 1×4, Medium 2×3, High 3×4 and Ultra 4×10, adaptive rounds, sources, reports, models, controls and attach/continue in chat;
- MCP stdio/HTTP CRUD, trust, discovery, scoped tools, calls and reconnect;
- schedules and occurrence history, usage/pricing/budget, all settings sections, storage cleanup/retention and notifications.

Native folder pickers, hover/minimap geometry, CSS motion, SVG consensus artwork, drag/drop plumbing, web calendar pixels and embedded designed-HTML rendering are adapted to path completion, jump lists, textual ledgers, agenda views and explicit `open`/`xdg-open` actions.

## 8. Error handling, recovery and resource bounds

Errors are typed at the daemon boundary and rendered with a stable code, safe message, affected scope, retryability and corrective action. User/model text is never used as authoritative approval chrome. Expected categories include data lease held, desktop active, schema incompatible, backup failed, credential locked, permission denied, queue full, deadline exceeded, outcome unknown, provider/MCP unavailable, disk full and terminal unsupported.

Canonical assistant text, reasoning, tool arguments/results, workflow replay values and ordering are preserved exactly. Only cached, duplicated, derived, queued or hidden working state is bounded. Streams use iodata/chunk deques and attempt IDs; a provider retry emits reset events and excludes the failed attempt from final/history bytes. Collectors enforce wire and decoded limits while reading and drain/reap producers. Queues are bounded by count and bytes and refuse admission visibly rather than drop work.

Crash recovery classifies effects. Read-only idempotent work may retry under policy. A write/execute/MCP timeout after dispatch becomes `outcome_unknown` unless an idempotency marker proves the result. Git commit/merge, file rename and workflow journal recovery inspect durable markers/hashes before deciding. Bootstrap reconciles stale launch intents, scheduled claims, runs, workflow children, research, spill files and cleanup intents idempotently.

Quit semantics are explicit:

- close/detach client: engine work continues;
- stop current run: only that run subtree ends;
- stop daemon: stop admission/scheduler, settle or pause by domain contract, reap every descendant, flush/close Repo and release the cross-app lease;
- `SIGTSTP` restores cooked/main screen before suspend and snapshots/redraws on continue;
- client `SIGHUP` closes only the session; daemon `SIGTERM` performs bounded structured shutdown.

## 9. Security requirements

Permissions are fixed capabilities evaluated again at the effect boundary: project read/write, Git read/mutate, host execution, public/private network, scoped MCP call, clipboard write, external open, automation enable and destructive storage. Read-only/Auto/Full Access remain user-facing presets. Plan mode both omits mutating tools and rejects them at dispatch. “Always” approvals are narrowly scoped and include project/run/node/tool/canonical-argument hash.

Filesystem effects are descriptor-relative at use time. Linux uses `openat2` beneath the project root; macOS uses held directory FDs with `openat`/`fstatat`, `O_NOFOLLOW` and `renameat`. Atomic writes use a same-directory `0600` exclusive temp, chunked write, file and directory fsync, mode preservation, rename and cleanup on every exit. Edits use inode/size/mtime/SHA-256 compare-and-swap.

Shell, Git and stdio MCP children use argv or explicitly approved `/bin/sh -c`, sanitized allow-list environments, closed stdin, separate bounded stdout/stderr and their own process group. Stop sends TERM, waits a bounded grace, then KILLs and reaps the group. Git validates refs/revisions, separates options and paths, resolves untrusted revisions to object IDs and scopes integration to the exact project/conversation/run/node.

`web_fetch` retains private and localhost support through explicit `network_private` permission. A resolver/connector classifies and pins every DNS answer and actual peer, revalidates each redirect, blocks metadata by default, strips cross-origin credentials, disables implicit proxies and never delegates a private URL to a cloud reader.

MCP servers are disabled until explicitly trusted when imported or changed. Annotations, including `readOnlyHint`, are untrusted hints. Each client owns request workers, caller monitors, generations, one absolute deadline, bounded frames/queues/tool catalog and one reconnect timer. Non-idempotent transport timeout is not retried automatically.

No atom is created from runtime or decoded input. IPC and workflow boundaries use bounded JSON, not ETF. External text cannot emit terminal controls or impersonate trusted approval UI.

## 10. Packaging, installer and updates

Build target-native relocatable `mix release` archives with `include_erts: true`:

- `macos-arm64`, macOS 14+;
- `macos-x86_64`, macOS 14+;
- `ubuntu-22.04-arm64`, glibc 2.35 floor;
- `ubuntu-22.04-x86_64`, glibc 2.35 floor.

Build on native pinned baseline runners. Inspect every ERTS executable, Exqlite/ExRatatui NIF and helper for architecture, linked libraries, RPATH and glibc symbol floor. Nothing downloads a runtime, NIF, migration or asset on first start. Burrito is not the production baseline; a later bounded experiment can replace the outer artifact only if it passes the identical four-target, rollback, signing and offline suite.

Public immutable GitHub Releases contain archives, deterministic SHA-256 manifest, detached signature, build-provenance and SBOM attestations, human SBOM, third-party notices and a release manifest recording source commit, OTP/Elixir/SQLite versions, target, minimum OS and digest. macOS nested Mach-O code is signed inside-out with Developer ID, hardened-runtime entitlements are minimal and evidence-based, final archives are notarized, and quarantine/Gatekeeper tests pass. Without Apple signing/notarization credentials, macOS output is labeled internal/prerelease and is not called a production public Mac release.

The documented direct command is a public no-login HTTPS installer. The bootstrap is small, reviewable and versioned; TLS/domain control is explicitly its initial trust anchor. It selects OS/CPU, resolves an immutable version, downloads into a `0700` temporary directory, verifies the exact SHA-256 and available signature/provenance before extraction, rejects absolute/`..`/device/escaping-symlink archive entries, bounds downloads, self-checks in staging without touching the user DB, then atomically switches immutable version directories. It never uses `sudo`, runs an unverified artifact or silently edits shell startup files.

Direct installs support pinned version, update, rollback, offline local artifact and uninstall. Install/update is locked, repeatable and cancellation-safe; the previous known-good runtime remains. Uninstall removes runtime/launcher/cache/completions but preserves data, configuration, state and Keychain/Secret Service entries by default. Purge requires a separate explicit confirmation. Package-managed installations delegate update/uninstall to their package manager. Homebrew can consume the same artifacts after the direct channel is stable.

## 11. Verification strategy

Tests use deterministic fake providers, seeded data, injectable clocks/UUIDs/resolvers/transports/credential stores/process launchers and supervised processes. They synchronize on messages, monitors, barriers or explicit state, never sleeps or liveness polling.

Required suites are:

1. **Extracted-core parity:** port focused engine, provider/SSE, tool/Git/file, MCP, workflow, research, schedule, storage and persistence tests. Golden fixtures compare normalized provider requests, DB rows, event order, tool policies, workflow replay, research reports, schedules, worktrees and teardown against the pinned desktop baseline.
2. **Ownership and concurrency:** three concurrent runs survive navigation, TUI kill and reconnect; queue drains without UI; a schedule fires once; stop/crash leaves zero owned tasks, ports, timers, sockets, process groups and unanswered callers.
3. **Event correctness:** subscribe-before-snapshot, gaps, stale generations, node→text→reasoning→run ordering, exact final bytes and bounded subscribers.
4. **Shared database:** active-desktop pre/post detection refusal; duplicate CLI lease refusal; lease release on clean/crash exit; legacy/exact/unknown schema handshake; migration backup independent restore; source/inode preservation; current-desktop readable additive migrations. A deliberate race test demonstrates that an unmodified desktop can still start after CLI detection, and documentation/tests assert the product reports this residual risk rather than claiming exclusion.
5. **Migrations and recovery:** every released schema fixture, kill/restart at backfill boundaries, busy/disk-full/read-only/corruption, quick/FK checks, row-count equations, quarantine and binary rollback compatibility.
6. **Secrets:** locked/missing stores, two-phase failures/rotation, exact-value scans across DB/events/logs/terminal/crash/argv/env, and proof that new writes persist references only.
7. **Security/adversarial:** path/symlink races, atomic-write fault points, Git option/ref attacks, SSRF/DNS rebinding/redirects, MCP malformed/oversized/reconnect cases, workflow child resource/capability escape attempts and terminal-control/bidi/paste fuzzing.
8. **TUI:** pure reducer tests, exact cell/style/cursor goldens at representative sizes and color modes, sustained Unicode editing/paste, resize/tmux/SSH, auto-follow, modal focus and 1,000 terminal restoration cycles for normal/error/INT/TERM/TSTP.
9. **Resource:** locked fixtures with post-GC memory, process/port/query/render counts, linear streaming, bounded mailboxes/collectors and golden output equivalence.
10. **Final artifacts and installer:** offline clean-host boot without developer runtimes, PTY/plain/NDJSON, SQLite create/migrate/reopen, deterministic fake run, Git diagnostic, signal/child cleanup, hostile archives, failed/cancelled/concurrent updates, rollback and uninstall-preserves-data on all four targets; signing/notarization/quarantine on both Macs.

## 12. Delivery phases and gates

### Phase 0 — contracts and spikes

Record source rights/provenance, create the desktop compatibility `.specs` document, freeze the shared schema/lease protocol, prove the macOS desktop detector and duplicate CLI lease, spike the exact-pinned ExRatatui scenes, and produce minimal native Mix releases on all four targets.

**Gate:** no source publication without rights; no renderer commitment before its native/input/lifecycle suite; no canonical DB write before lease, handshake and verified backup fixtures pass.

### Phase 1 — daemon and headless core spine

Extract the core, remove Web/Desktop couplings, implement foundation/bootstrap/runtime supervision, IPC, typed event/query APIs, credential adapters, atomic launch, command dispatcher and conversation coordinator. Ship deterministic chat/Plan/Swarm vertical slices in headless and plain modes.

**Gate:** core boots without Phoenix/Desktop, queued turns progress headlessly, concurrent runs survive client loss, and shutdown has no descendants.

### Phase 2 — terminal workspace

Implement Scene/action adapter, responsive shell, transcript/run cards, composer, Navigator/Inspector, Activity Center, tools/reasoning, questions/approvals, projects, modes, queue, history, attachments and lifecycle controls.

**Gate:** the milestone scenario—three streams, navigation, preserved multiline draft, Inspector use, answer a waiting question, return with exact scroll/state—passes on native macOS and Ubuntu.

### Phase 3 — complex parity and hardening

Complete goals, edit/fork/rewind, worktrees/Changes/Timeline, full Consensus and plan gate, workflows/Ultra/Compact, sandbox broker, Deep Research, MCP/search/provider/settings and adversarial security suites.

**Gate:** cross-repo goldens and lifecycle/security gates pass with no canonical data loss or unowned effect.

### Phase 4 — durable background and administration

Complete schedules/service onboarding, usage/pricing/budget, storage cleanup/retention, notifications and full settings. `launchd`/`systemd --user` enablement is explicit; service removal preserves data.

**Gate:** scheduled occurrence fires exactly once across restart, credentials-lock behavior is fail-closed, and every administrative action is reversible or explicitly destructive.

### Phase 5 — public distribution

Complete four native release jobs, signing/notarization, SBOM/provenance, immutable GitHub Release, unauthenticated one-command installer, update/rollback/uninstall and clean-host acceptance.

**Gate:** every delivered byte passes artifact tests. Mac production wording requires valid signing/notarization. Release notes prominently state that desktop/CLI concurrency remains unsupported and the startup race remains until desktop implements the reciprocal lease.

Phases sequence delivery; they do not reduce the full-parity definition.

## 13. Acceptance criteria

The architecture is accepted only when all of the following hold:

- the new umbrella builds and boots without Phoenix, LiveView, Desktop, wx or distributed Erlang;
- provenance maps every extracted file/test/spec to an authorized upstream commit and hash;
- macOS CLI uses the existing canonical SwarmCode database, Ubuntu uses its XDG canonical database, and no normal-operation copy/import divergence is introduced;
- one CLI daemon owns the canonical DB lease; it refuses an active macOS desktop before any Repo/migration/bootstrap side effect; schema incompatibility refuses without mutation;
- a new numbered desktop compatibility spec fully defines reciprocal lease acquisition, schema/credential handshake and startup order, while no desktop implementation file is changed;
- user-facing documentation accurately states that current desktop non-enforcement leaves a residual post-detection startup race and that concurrent operation is unsupported; no test or copy claims otherwise;
- every migration or data repair has a verified, independent, mode-`0600` backup/manifest and lossless quarantine where rows change;
- the daemon owns runs, research, workflows, MCP and schedules independently of clients, preserves canonical event/final-byte ordering and leaves no descendant or waiter after stop;
- TUI, plain and headless surfaces call the same command/query/event contracts and cover the complete parity inventory;
- ExRatatui passes its four-target gate or is replaced through the renderer-neutral adapter by the specified fallback;
- external text cannot control title, clipboard, cursor, terminal modes or trusted approval chrome; plain/NDJSON contains no controls;
- new secret writes use Keychain/Secret Service references only, fail closed without a persistent store, and exact secrets never reach noncredential persistence or output;
- workflows are out-of-process and capability-brokered; filesystem, Git, command, network and MCP effects pass their effect-time security and ownership tests;
- each of the four runtime-only artifacts starts offline on a clean supported host with no Erlang/Elixir/Rust/compiler, and Git absence produces an actionable feature diagnostic;
- public GitHub assets download without login, the installer verifies before installation, updates are atomic/rollback-aware and uninstall preserves user data;
- all focused and parity suites plus repository precommit checks pass before a release claim.

## 14. Evidence base

This specification synthesizes the read-only research in:

- [consensus architecture](../../research/2026-09-01/consensus-architecture.md)
- [engine architecture](../../research/2026-09-01/engine-architecture.md)
- [feature inventory](../../research/2026-09-01/feature-inventory.md)
- [packaging](../../research/2026-09-01/packaging.md)
- [security and asynchronous runtime](../../research/2026-09-01/security-async.md)
- [TUI stack](../../research/2026-09-01/tui-stack.md)
- [TUI UX](../../research/2026-09-01/tui-ux.md)

Where the consensus ADR required a separate CLI database, the subsequently approved product decision in this specification supersedes it for macOS: desktop and CLI share the canonical database sequentially. The lease, handshake, conservative migration epoch and explicit residual-race warning are mandatory consequences of that change.
