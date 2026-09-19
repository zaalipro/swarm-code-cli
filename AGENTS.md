# AGENTS.md

Guidance for coding agents (Claude Code, Codex, jcode) working in this repository.
Claude Code reads this file directly when the project has no `CLAUDE.md`; do not add a
`CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`, they would stop this file from loading.

## What this is

SwarmCode CLI: a standalone, local-first Elixir/OTP umbrella that gives the SwarmCode domain a
full-screen terminal UI, an append-only plain presenter and headless commands. It shares the
canonical SQLite database with the macOS desktop app (`~/dev/swarm-code`, a read-only reference;
never modify that repo). The approved architecture is
`docs/superpowers/specs/2026-09-01-swarm-code-cli-design.md`; the renderer decision (ExRatatui
rejected, project-owned Rust port adopted) is `docs/decisions/tui-renderer.md`.

Toolchain is pinned by `.tool-versions` through mise (Erlang 28.4.2, Elixir 1.18.4-otp-28,
Rust 1.97.1). Run every Mix command as `mise exec -- mix …` from the umbrella root unless a
command below says otherwise. Native builds also need `cc` (C11), `python3`, and on macOS
`/usr/bin/clang` plus `codesign`.

## Commands

| Task | Command |
| --- | --- |
| Fetch deps | `mise exec -- mix setup` |
| Build the Rust terminal port (required before any real TUI launch or release) | `scripts/dev/check_terminal_port.sh` → `_build/terminal-port/debug/swarm-terminal-port`; also runs `cargo fmt --check`, `cargo test --locked` and the license-manifest check; installs nothing |
| Full contributor gate | `mise exec -- mix precommit` (runs in `MIX_ENV=test`: format check, `compile --warnings-as-errors`, `deps.unlock --check-unused`, all tests, provenance verify, schema-snapshot check, Unicode source checks) |
| All tests (authoritative, ~15 min, three apps in-process) | `mise exec -- mix test` |
| One file or one test | `mise exec -- mix test apps/swarm_code_core/test/swarm_code/protocol/chunk_buffer_test.exs:6` |
| Format | `mise exec -- mix format` |
| Regenerate the keyboard reference after touching the binding table | `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --write)`; `--check` verifies. Not part of precommit |
| PTY suites (create and clean their own terminals) | `PYTHONDONTWRITEBYTECODE=1 python3 scripts/dev/test_terminal_port_pty.py`, `test_terminal_demo_pty.py`, `test_live_session_pty.py`, `test_saved_session_pty.py` |
| Plain demo (no daemon, no user data) | `(cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)` |
| Interactive fake demo | `scripts/dev/run_terminal_demo.sh` (synthetic data; it never answers a prompt) |
| SVG cell gallery | `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.demo.cells)` → `_build/cell-previews/` |
| Real saved session (canonical DB, resumes latest conversation of `SWARM_PROJECT_ROOT`) | `scripts/dev/run_saved_session.sh` |
| Real unsaved session | `scripts/dev/run_live_session.sh` |
| Headless session, one command per line on stdin | `scripts/dev/run_plain_session.sh [--ndjson]` |
| Release / install | `scripts/dev/build_release.sh` → `_build/prod/rel/swarm_code_cli`; `scripts/install.sh` installs `swarmcode` |

Provider settings (`SWARM_PROVIDER`, `SWARM_MODEL`, `SWARM_BASE_URL`, `SWARM_API_KEY`, …) come
from `~/.secrets` (or `SWARM_ENV_FILE`) unless already exported; an exported stale value shadows
the file. On macOS quit the desktop app before a saved session; they cannot share the database.

### Test gotchas

- Only the umbrella-root `mix test` is trustworthy. `mix test` inside an app directory, or
  `mix cmd --app swarm_code_daemon mix test`, fails or does not compile because cross-app test
  support modules are missing from the code path. Use those only for subsets that avoid
  cross-app test files.
- `demo/cells_test.exs` fails when `MIX_QUIET=1` is exported in the shell that runs the suite
  (the child `mix` prints nothing). Unset it.
- `ui/renderer/locked_branch_test.exs` fails whenever `_build/prod` exists (after
  `build_release.sh`) or inside a git worktree whose `deps` is a symlink. A green suite means:
  main checkout, no `_build/prod`, no `MIX_QUIET`.
- Git worktrees need `deps` and `apps/swarm_code_daemon/priv/native` symlinked from the main
  checkout before they compile.
- Nothing hits a remote API: LLM and tool tests use a loopback HTTP server, and every schema test
  builds fixture databases under `apps/swarm_code_daemon/priv/schema/fixtures`, never the real one.
- The plain-demo golden `apps/swarm_code_cli/test/fixtures/plain/three_run_output.txt` is
  regenerated from `SwarmCodeCLI.Demo.Plain.run(:complete, …)` whenever the fake script changes.

## Architecture

Three umbrella apps with deliberate ownership boundaries (`apps/*/mix.exs`):

- **`swarm_code_core`**: small and dependency-light. `SwarmCode.Protocol.*` is the client/daemon
  wire (length-prefixed versioned JSON frames, envelopes, scope, `JsonLimits`, service
  handshake/request), `SwarmCode.Commands` the slash-command registry, and
  `SwarmCode.Governance.Provenance` the extraction audit.
- **`swarm_code_daemon`**: the domain extracted from the desktop app plus the daemon shell.
  `SwarmCode.Domain.*` is the desktop lineage (Ecto SQLite Repo via vendored `exqlite`,
  conversations, `Engine` with run/agent supervisors, LLM adapters, tools, workflows, research,
  scheduler, MCP, settings). `SwarmCode.Daemon.*` wraps it: `FoundationGate` (canonical paths,
  process identity, private directories, signed macOS desktop detector, `CrossAppLease`, audited
  `Schema.Contract` probe, verified backup gate), `RepoLauncher`, and `Service.*` (owner-only Unix
  socket `Connection`, `RequestRouter`, `CommandDispatcher`, durable `CommandLedger`,
  `PersistedBackend` for saved sessions vs `LiveBackend` for unsaved ones, projections).
  `Daemon.Runtime.Run` is the transient in-memory runtime the live launcher uses; saved sessions go
  through `Domain.Engine` and the guarded Repo. The socket listener never starts with the
  application; launchers own it. A custom Mix compiler (`:schema_snapshot`, top of
  `apps/swarm_code_daemon/mix.exs`) compiles the C helpers and the macOS helper into
  `priv/native/` (gitignored).
- **`swarm_code_cli`**: the client. `SwarmCodeCLI.UI.*` is a renderer-neutral pipeline:
  `DataSource` (`Daemon` socket transport or `Fake`) → typed `DTO`/`Delta` → `Reducer` (pure;
  owns only focus, scroll, drafts, layout, modal state, subscriptions) → `State` → `Projector`
  (pure; `State` → `Scene` plus opaque action targets) → `Paint` (Scene → bounded cell `Plan`) →
  `Renderer.RatatuiPort` (Elixir owner of the Rust process in `native/terminal_port`, credit-
  controlled wire in `docs/implementation/terminal-port-wire-v1.md`). Input flows Rust decoder →
  `UI.Input` → `Keymap` (one table, `Keymap.Bindings`) → `Action`. `SafeText` and `Width`
  (Unicode 17 tables) gate every string that reaches the terminal. Sibling presenters: `Plain.*`
  (append-only stdin/stdout), `Companion.*` (localhost web mirror served from `priv/companion`),
  `Demo.*` (synthetic fixtures), `Release` (packaged entry point). `scripts/dev/*_session.exs`
  are the launchers that wire daemon, data source and renderer together.

Invariants that the code base defends and tests pin:

- Renderer structs and native key names never enter core, the reducer or persisted state.
- Reducer and projector are pure; clocks, identifiers and external facts come from the owner.
- Clients never make policy or liveness decisions; approvals are server-side compare-and-set.
- Runtime input never selects modules or creates atoms; JSON and text have byte, count and
  nesting ceilings that return errors rather than truncating.
- The canonical database is never reset, recreated or repaired. An unknown schema fails closed
  with `StartupError{code: :schema_incompatible}` ("could not pass the read-only schema probe").
  When the desktop repo gains migrations, re-pin: add a `Schema.Contract` entry for the upstream
  commit, regenerate with `apps/swarm_code_daemon/priv/schema/generate_manifest.exs` using
  absolute `--output`/`--fixtures-dir` paths, then update the `FoundationGate` manifest source,
  the provenance pins and the pinned counts in the daemon schema tests.

## Provenance and vendored sources

`provenance/extracted-files.json` lists every file copied from the desktop repo (most of
`Domain.*`, `llm/`, `tools/`, the migrations, a few tests) with upstream path, commit and hashes.
`mix swarm_code.provenance.verify` (in precommit) rejects drift, so an edit to a listed file
must update its manifest entry. `third_party/` and `vendor/exqlite` are pinned copies checked
by `scripts/dev/sync_unicode_width.exs --check`, `sync_unicode_variants.py --check` and
`verify_terminal_port_licenses.py`. Hex deps are pinned with `==` and
`deps.unlock --check-unused` is a gate: do not add packages casually.

## TUI facts that constrain changes

- Bindings live only in `UI.Keymap.Bindings`; the help sheet, status hints and
  `docs/keybindings.md` derive from it. Never bind Ctrl-K (a window-manager chord). Alt is
  unreliable on macOS ghostty, so nothing essential may be Alt-only. Enhanced keys (kitty
  protocol) are always unavailable. A bare Esc resolves after 40 ms.
- Letters arrive as `{:text_fragment, …}`, only special keys as `{:key, …}`; keymap tests for
  bare letters must set `focus: "main"` or the letter is treated as typing.
- Measure glyphs with `SwarmCodeCLI.UI.Width.cells/2` under both ambiguous-width policies before
  drawing. Box drawing, half blocks and emoji are ambiguous or wide. Progress is the `▐` tick
  bar, not a solid fill. Colours come from `UI.Theme` (the web app's Carbon tokens); never invent
  a palette.
- To drive the real TUI end to end, do not sleep inside the Python pty harness: it stops draining
  the pty and the port dies with fake `:draw`/`:restoration` errors. Use GNU screen
  (`screen -dmS name …`, then `screen -S name -p 0 -X width -w 170 45`, `-X stuff`,
  `-X hardcopy`), and always quit the TUI with `q` before closing the window.
- The plain launcher closes at stdin EOF, so hold stdin open to see a model reply.
