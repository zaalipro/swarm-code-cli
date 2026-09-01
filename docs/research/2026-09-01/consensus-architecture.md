# ADR: Standalone SwarmCode CLI/TUI architecture

**Status:** Proposed for prototype  
**Date:** 2026-09-01  
**Scope:** New `swarm-code-cli` repository only. The desktop repository remains unchanged, except that a later compatibility contract may be documented under its `.specs/` directory if needed.

## Decision drivers

The target must preserve these user constraints:

1. **All existing functionality eventually**: chat, goals, swarms, plans, consensus, Ultra, deterministic workflows, deep research, compact, scheduling, MCP, tools/Git/files, settings, history, storage, and the exact asynchronous lifecycle semantics.
2. A **beautiful, terminal-native asynchronous TUI**, not a flat chat wrapper. Full-screen, plain-text, and headless modes use one domain core.
3. **Elixir is bundled**: users install no Erlang, Elixir, or Mix. This means a self-contained release with ERTS and the Elixir applications needed at runtime; it does not expose a general-purpose `mix`/`iex` toolchain.
4. **Ubuntu and macOS**, initially x86_64 and arm64, with a public, no-login, one-command install.
5. **No implementation changes in `~/dev/swarm-code`**. Source reuse, synchronization, and compatibility work happen from the new repository; only a `.specs/` compatibility document is permitted in the original if later required.

The engine audit also establishes two architectural facts: the reusable core is larger than `Engine` because command dispatch, queued-turn draining, plan gates, and workflow routing currently cross the LiveView boundary; and the current `RunSupervisor -> RunSup -> RunServer -> AgentSup -> operations` ownership tree must be retained rather than flattened. See [engine-architecture.md](./engine-architecture.md) and [feature-inventory.md](./feature-inventory.md).

## Three viable approaches

All three can ultimately meet the product constraints. They are coherent implementation bundles rather than claims that renderer, source, and process choices are inseparable.

| Approach | Shape | Advantages | Material costs / risks | Verdict |
|---|---|---|---|---|
| **A. Provenance-preserving core extraction + local daemon + ExRatatui client** | Extract core and focused tests at a pinned desktop commit into a new umbrella; one per-user daemon owns core/DB/schedules; TUI/headless clients use a versioned Unix-socket protocol; ExRatatui is pinned behind a SwarmCode-owned scene/input adapter. | Fastest path to behavioral parity; preserves proven OTP ownership; ExRatatui already has the chat-list, Markdown, textarea, popup, table, focus, input, true-color, and headless-test primitives needed; daemon makes schedules and runs independent of terminal lifetime. | Extracted code can drift while the desktop cannot consume a shared package; ExRatatui is young and its Rust NIF shares BEAM crash fate; daemon and IPC need rigorous lifecycle/security work. | **Recommended**, conditional on the gates below. |
| **B. Provenance-preserving extraction + local daemon + Ratatui OS-process client/sidecar** | Same extracted core and daemon, but a supervised Rust Ratatui/Crossterm process owns terminal rendering/input and communicates through a bounded scene/action protocol. | Mature renderer ecosystem and a real crash boundary between terminal-native code and the core BEAM. | Two languages, an additional protocol/state machine, `/dev/tty` ownership complexity, four extra native artifacts, signing/notarization burden, and slower UI iteration. It does not remove the daemon protocol. | **Fallback when NIF isolation is the only failed gate**, not the starting point. |
| **C. Clean-room core reimplementation + local daemon + TermUI client** | Rebuild behavior from numbered specs, public interfaces, fixtures, and black-box/golden tests; use the mostly-Elixir TermUI stack behind the same scene boundary. | Avoids copying source if redistribution rights are unavailable; minimizes custom Rust bridge code and removes ExRatatui's in-process Ratatui NIF (although TermUI's Markdown dependency is still native). | Highest parity and schedule risk across 43 migrations and hundreds of behaviors; easy to miss product semantics that currently live in LiveView; TermUI's Unicode width, paste/focus, resize, and test-integration gaps require their own spike. | **Rights-constrained fallback**. Viable, but substantially slower and less faithful. |

A full-source subtree/submodule, a Mix dependency on the desktop application, or runtime RPC into the desktop is not a fourth candidate: the existing project is not a core package, pulls Phoenix/Desktop deployment into compilation, gives a poor public/offline install story, and/or ceases to be standalone. A shared `swarm_code_core` package is the clean long-term no-drift state only if the desktop repository is someday allowed to consume it; until then drift can be detected, not structurally eliminated.

## Decision

Adopt **Approach A**, with explicit fallbacks to B or C only when its relevant gate fails.

### 1. Repository and source boundary

Create a new umbrella with three logical responsibilities:

- `swarm_code_core`: persistence, providers, tools, MCP, engine/run tree, workflows, research, scheduler, storage, command dispatcher, and typed event/query APIs;
- `swarm_code_daemon`: bootstrap gate, exclusive data-directory ownership, credential broker, local IPC, notification/service adapters;
- `swarm_code_cli`: ExRatatui presentation, plain presenter, NDJSON/headless commands, completion/help, and installer-facing commands.

One installed release may expose these as different boot modes; they remain different ownership boundaries even if packaged together.

Extract from the exact upstream commit current when work begins (the audit baseline was `f51c8d48eb666e538ac987cac17e512c55c7702d`). Preserve the `SwarmCode.*` module namespace initially. Record source path, upstream commit, and SHA-256 for every mapped file in a machine-readable provenance manifest. Port focused Fake-driven tests and maintain read-only upstream-diff CI plus normalized golden fixtures for provider requests, messages/runs/nodes, event ordering, tool policies, workflow replay, research output, schedules, worktrees, and teardown.

Do not extract only `lib/swarm_code/engine/**`. Move/reimplement command dispatch, workflow slash routing, queue draining, edit/resend, plan approval, transcript projection, and safe Markdown currently owned by Web into core services. Do not bring Phoenix, LiveView, Bandit, `elixir-desktop`, assets, or desktop window code into the core release.

### 2. Runtime: daemon-owned core, disposable clients

The production topology is one **non-distributed, per-user daemon per CLI data directory**. The daemon owns the Repo, migrations, bootstrap/recovery, run trees, workflows, research, scheduler, MCP clients, and canonical event hub. A TUI crash or disconnect cancels only view-owned work; it does not stop runs or schedules. A foreground `--no-daemon` mode remains useful for development, recovery, and tests, but it is not the parity topology.

Clients connect over a user-owned Unix socket (`0600` beneath a `0700` runtime directory), with peer-UID validation, a random instance nonce, length-prefixed versioned messages, byte/count bounds, request references, scopes, sequence numbers, and snapshot resynchronization after gaps. Do not use TCP, Phoenix, distributed Erlang, EPMD, cookies, or ETF from an untrusted client. Service autostart is explicit during first-run onboarding; enabling schedules should offer a per-user `launchd` agent or `systemd --user` unit.

Retain the existing significant-child run/agent supervision shapes. Add owned workers for blocking Repo/Git/network/finalization work, a core `CommandDispatcher`, and one conversation coordinator so queued turns progress without an attached UI. Model-authored Elixir workflows execute in a disposable, non-distributed child BEAM through a capability-checking, journal-owning broker rather than `Code.eval_*` in the core VM.

### 3. TUI: ExRatatui, not Burrito

Pin the reviewed ExRatatui 0.13.x release for the prototype and wrap it behind `Cli.Ui.Scene` and normalized action intents. Renderer structs and NIF resources never enter core state. The reducer owns only focus, scroll, draft, selection, responsive layout, and subscriptions; network, Git, database, workflow, MCP, and agent work remain daemon-owned.

Render viewport windows, not full history. Apply all scoped semantic events, coalesce only redraws, and preserve the current stream ordering. Provide the Carbon-derived true-color theme plus 256/16/no-color and responsive one/two/three-pane layouts. `--plain` is a permanent append-only, screen-reader/non-TTY surface, and NDJSON has a versioned control-free schema.

Only the renderer emits control sequences built from fixed enums. Model, MCP, repository, Git, command, URL, and log data are sanitized into inert spans; external ANSI/OSC/DCS, clipboard, title, hyperlink, bidi, and control bytes are never passed through. See [tui-stack.md](./tui-stack.md), [tui-ux.md](./tui-ux.md), and [security-async.md](./security-async.md).

ExRatatui and Burrito solve different problems: the former is a renderer bridge; the latter is a self-extracting packaging wrapper. Choosing ExRatatui does **not** imply Burrito.

### 4. Persistence and credentials: separate DB, explicit import

The CLI always uses its **own SQLite database, application identity, migrations, and exclusive data-directory lock**. It never opens the desktop database for ordinary operation. WAL cannot reconcile two registries, boot recovery processes, schedulers, migration owners, or secret models even though it allows some concurrent SQLite access ([SQLite WAL](https://www.sqlite.org/wal.html)).

Provide an explicit, initially empty-destination `swarm-code import desktop` command. For v1, require the desktop and CLI daemon stopped; use SQLite's online backup API to create a consistent mode-`0600` snapshot, produce and independently verify a manifest, hashes, row counts, `quick_check`, `foreign_key_check`, and restore, then import into the CLI DB without changing source bytes ([SQLite Online Backup API](https://www.sqlite.org/backup.html)). Imported active work becomes interrupted; schedules, retention, and MCP servers remain disabled until reviewed. Move legacy plaintext credentials directly to the credential broker and store only opaque references in the destination.

Use platform path adapters: XDG config/data/state/cache/runtime conventions on Ubuntu and Application Support/Logs/Caches plus a verified per-user runtime directory on macOS. Use macOS Keychain, Linux Secret Service/libsecret, an isolated in-memory test adapter, and environment/session-only input when a headless secret service is unavailable. Never silently fall back to plaintext SQLite or a credentials file.

### 5. Distribution: public Mix releases and verified one-command install

Use target-native, relocatable `mix release` archives with `include_erts: true` as the production baseline. Official Mix releases are self-contained and recommend including ERTS; they still must be built for the target OS/ABI ([Mix release documentation](https://hexdocs.pm/mix/Mix.Tasks.Release.html)). Initial artifacts:

- macOS arm64 and x86_64, recommended floor macOS 14;
- Ubuntu 22.04/glibc 2.35 arm64 and x86_64, tested forward on supported Ubuntu LTS releases.

Build and inspect Exqlite, ExRatatui, ERTS executables, NIFs, and linked libraries natively for each target. No runtime, NIF, or asset may download on first start.

Publish immutable **public GitHub Release assets** so downloads require no GitHub account or token. A small public HTTPS installer (`curl --proto '=https' --tlsv1.2 -fsSL … | sh`) selects OS/CPU, downloads an immutable version, verifies SHA-256 and available signature/provenance, extracts into a private staging directory, self-checks, and atomically switches version directories. “Unauthenticated” describes download access; it does not mean unverified bytes. Install is per-user/no-root, repeatable, rollback-capable, and uninstall preserves data by default. Homebrew can consume the same artifacts later. GitHub release immutability and attestations are documented at [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases) and [Artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations).

Do **not** use Burrito for the first production line. Its one-file property is not needed for a one-command install, while its own documentation describes the approach as experimental and it adds first-run extraction, rollback, cross-target NIF, and macOS signing risk ([Burrito README](https://github.com/burrito-elixir/burrito#disclaimer)). Run a later bounded Burrito experiment only after the same four-target release suite passes; adopt it only if a literal single file proves user value without weakening rollback, signing, or offline startup.

System Git is a documented prerequisite for Git features; `gh` and arbitrary MCP runtimes remain optional/user-provided. Bundling Elixir does not imply bundling every external developer runtime.

## Consequences

**Positive**

- Full asynchronous and scheduling parity has a stable owner independent of terminal state.
- The desktop repository and live data remain untouched.
- Source parity starts from proven behavior while adapter and golden-test boundaries contain drift.
- The renderer, plain mode, daemon, and installer can evolve independently.
- One-command installation is achieved with the lower-risk official release mechanism.

**Negative / accepted debt**

- Until the desktop consumes a shared core, synchronization is procedural and requires sustained CI discipline.
- A local daemon and versioned protocol add meaningful implementation and security scope.
- ExRatatui must earn adoption through a hard native/input/lifecycle gate; fallback may add schedule.
- Separate data means import rather than transparent shared history.
- macOS public distribution requires signing/notarization operations in addition to compiling code.

## Non-negotiable prototype exit gates

1. **Rights/provenance:** no desktop source is copied into a public repository until extraction authorization, copyright, license, and NOTICE terms are recorded. Every copied file maps to an upstream commit/hash.
2. **Headless core boundary:** the extracted core compiles and boots without Phoenix/Desktop, and representative Fake-driven chat, swarm, plan/consensus, compact, workflow, research, scheduled, MCP, tool, and recovery tests pass. Command dispatch and queued-turn draining work with no TUI attached.
3. **Daemon ownership:** one daemon lock per data dir; bounded peer-authenticated socket; three concurrent runs continue through TUI navigation, client kill, and reconnect; a scheduled occurrence fires once; stop/shutdown leaves zero owned tasks, ports, timers, sockets, OS descendants, and unanswered callers.
4. **Event correctness:** subscribe-before-snapshot/gap recovery, scope/generation rejection, node→text→reasoning→run ordering, exact final bytes, and bounded client queues are proven without dropping canonical data.
5. **ExRatatui go/no-go:** representative chat, swarm, consensus, and research scenes pass on native Ubuntu/macOS with sustained typing/paste, the Unicode fixture set, resize/tmux, tiny terminals, terminal restoration under normal/error/INT/TERM/TSTP, bounded memory/mailboxes, and acceptable interactive latency. Any reproducible valid-input BEAM crash, NIF hang, persistent lost input, terminal corruption, or target requiring an end-user compiler triggers the documented TermUI or Ratatui-sidecar fallback.
6. **Terminal trust:** fuzz every external-text source and control-sequence split point. Only assigned cells may change; clipboard, title, terminal modes, input, and trusted approval chrome must remain unaffected. Plain/NDJSON output contains no controls.
7. **Persistence/import:** CLI and desktop paths are distinct; the exclusive lock works; a fixture desktop import leaves the source byte-for-byte unchanged, restores independently from its manifest, migrates idempotently, disables executable automation, and persists no plaintext secret.
8. **Security boundaries:** Keychain and Secret Service adapters, fail-closed headless behavior, exact-secret redaction, out-of-process workflow execution, effect-time capability checks, owned/bounded MCP calls, redirect/DNS-aware `web_fetch`, atomic confined writes, and process-group cleanup have focused adversarial tests before real-provider dogfooding.
9. **Four final artifacts:** each packaged artifact boots offline on a clean target with no Erlang/Elixir/Rust/compiler, opens/migrates/reopens SQLite, renders a PTY and plain mode, runs a deterministic fake job, and exits without orphans. Both Mac artifacts pass nested signing, notarization, quarantine, and Gatekeeper checks before a production claim.
10. **Installer/update safety:** public no-auth download selection, checksum/provenance verification, hostile-archive rejection, atomic install, cancelled/failed/concurrent update preservation, rollback compatibility, and uninstall-preserves-data all pass against draft release assets.

## Questions that truly block work

Only these require owner input; other choices above have defaults and should not delay implementation.

1. **Before copying or publishing source:** what license/copyright/NOTICE should the public CLI repository use, and does the owner explicitly authorize extraction of the listed desktop files? If this is not authorized, start Approach C instead.
2. **Before production macOS release:** provide the Apple Developer team/bundle identity plus Developer ID signing and notarization credentials, or explicitly accept a non-production/internal Mac beta until they exist.
3. **Before claiming persistent credentials on headless Ubuntu:** choose whether Linux Secret Service is a required dependency or whether a separately specified encrypted-vault adapter is required. The safe interim behavior is environment/session-only input and a hard failure for persistence—never plaintext fallback.

Not blocking: the default artifact contract is runtime-only bundled Elixir; Git remains a prerequisite; the initial OS/CPU matrix and daemon choice are decided above; the public installer and release assets require no user authentication; and delivery may be phased, but the parity inventory is not reduced.

## Evidence base

This ADR synthesizes all six read-only reports in this directory: [engine architecture](./engine-architecture.md), [feature inventory](./feature-inventory.md), [packaging](./packaging.md), [security/async](./security-async.md), [TUI stack](./tui-stack.md), and [TUI UX](./tui-ux.md). Those reports contain the exhaustive numbered-spec, implementation/test, dependency, platform, and upstream citations; only sources necessary to verify the disputed decisions are repeated here.
