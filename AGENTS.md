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
| Full contributor gate | `mise exec -- mix precommit` (runs in `MIX_ENV=test`: format check, `compile --warnings-as-errors`, `deps.unlock --check-unused`, all tests, provenance verify, `provenance.sync --check`, schema-snapshot check, Unicode source checks) |
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
| Packaged entry points | `bin/swarmcode [DIR] [--new\|--continue\|--resume ID] [--model M] [-p PROMPT [--json]] [--plain [--ndjson]]`; the launcher validates flags in bash (usage exits 2 before any VM), the TUI is `bin/swarm_code_cli start` with `SWARM_RELEASE_TUI=1`, `-p`/`--plain` are `bin/swarm_code_cli eval 'SwarmCodeCLI.Release.main(System.argv())' …`; `-p` starts a new conversation unless `-c`/`--resume`/`SWARM_CONVERSATION` names one (pass 71). Exit codes 0 done, 1 failed, 2 usage, 3 startup refused |
| Re-derive the desktop domain | `mise exec -- mix swarm_code.provenance.sync --ref <desktop sha>` (read-only `git` on `~/dev/swarm-code` or `$SWARM_CODE_UPSTREAM`); `--check` verifies (in precommit) |
| Re-pin a hand-edited ledger file outside the sync mappings | `mise exec -- mix swarm_code.provenance.repin <path> …` |

Providers (pass 70, decision D3): the database's providers and the conversation's own choice
decide the model, exactly like the desktop (`Providers.effective_model/2`). `SWARM_*` never
create provider rows or rewrite a conversation; only when the database has no usable provider at
all does the first run create one row from `SWARM_MODEL`/`SWARM_BASE_URL`/`SWARM_API_KEY` and say
so (a toast in the TUI, a stderr line headless). `swarmcode --model M` (env
`SWARM_MODEL_OVERRIDE`, set only by the launcher) is an in-memory session override applied at
each `Engine.start_*`; an explicit `/model` ends it. The launchers load only `SWARM_*`,
`OPENAI_*` and `ANTHROPIC_*` from `~/.secrets` (or `SWARM_ENV_FILE`), never the whole file, and
the synced engine scrubs secrets from model-run shells. Logger output goes to
`~/Library/Logs/SwarmCode/cli.log` (0600, rotated; XDG state on Linux), never to the tty. On
macOS quit the desktop app before a saved session; they cannot share the database.

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
  `SwarmCode.Domain.*` is the desktop lineage, re-derived from desktop `6dd8d82` (pass 69) by
  `mix swarm_code.provenance.sync`; CLI-local files (`domain/runtime.ex`, `paths.ex`,
  `notifications.ex`, `pub_sub.ex`, `feature_catalog.ex`, `html.ex`,
  `engine/pending_interactions.ex`) are never synced (Ecto SQLite Repo via vendored `exqlite`,
  conversations, `Engine` with run/agent supervisors, LLM adapters, tools, workflows, research,
  scheduler, MCP, settings). `SwarmCode.Daemon.*` wraps it: `FoundationGate` (canonical paths,
  process identity, private directories, signed macOS desktop detector, `CrossAppLease`, audited
  `Schema.Contract` probe, verified backup gate), `RepoLauncher`, and `Service.*` (owner-only Unix
  socket `Connection`, `RequestRouter`, `CommandDispatcher`, durable `CommandLedger`,
  `PersistedBackend` for saved sessions vs `LiveBackend` for unsaved ones, projections).
  `Daemon.Boot` is the desktop's `Bootstrap` (interrupted runs, seeded providers, MCP, research
  sweep, attachment prune, delayed isolation sweep; never the Scheduler, which the desktop
  owns) and `Daemon.Shutdown` its `Quit` (stop runs, kill background commands, wait for the
  flush, stop run/research/MCP/LSP subtrees): quitting a session stops its runs.
  `domain/runtime.ex` starts the domain's children, including `Tools.BackgroundProcs`,
  `Hooks.TaskSupervisor` (every tool call's post-hook needs it) and `LSP.Supervisor`.
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
  An approval row (`RunServer.pending_interactions/1`, CLI-local projection) names the waiting
  **op** node; its decisions are `approve` (`y`), `approve_run` (`Y`, the engine's `:always`),
  `always_prefix` (`A`, the server's own command family, never the client's), `deny` (`d`) and
  `deny_stop` (`D`). The project's approval mode and trust are the desktop's: a new project is
  `read_only` until `/trust`; `/approval read-only|auto|full` changes it. In `auto`, writes and
  `:safe` commands (`ls`, `git status`) run without asking and other commands ask.
- Runtime input never selects modules or creates atoms; JSON and text have byte, count and
  nesting ceilings that return errors rather than truncating.
- The canonical database is never reset, recreated or repaired. An unknown schema fails closed
  with `StartupError{code: :schema_incompatible}`. The contract `desktop-6dd8d82` has 57
  migrations; its `forward_compatible` allowlist lets a 53-migration database (desktop pass 63)
  be backed up and migrated, and `Schema.Gate.admit_migration/2` refuses any other pending
  migration ("Open the SwarmCode app once to upgrade the database") or a database ahead of the
  manifest (`Schema.Refusal` holds both sentences). When the desktop repo gains migrations,
  re-pin: sync the domain (`mix swarm_code.provenance.sync --ref <sha>`, which brings the
  migrations), add a `Schema.Contract` entry for the commit, regenerate with
  `apps/swarm_code_daemon/priv/schema/generate_manifest.exs` using absolute
  `--output`/`--fixtures-dir` paths, update the `FoundationGate` manifest source and the
  allowlist, then the pinned counts in the daemon schema tests.

## Provenance and vendored sources

`provenance/extracted-files.json` lists every file copied from the desktop repo (most of
`Domain.*`, `llm/`, `tools/`, the migrations, built-in agents/workflows/skills, pure upstream
tests) with upstream path, commit and hashes. `mix swarm_code.provenance.verify` (in precommit)
rejects drift. Files under a mapping of `provenance/sync-rules.json` (the pin, the ordered
namespace rewrite rules, mappings, exclusions) are derived as `format(rewrite(upstream@pin))`
plus a recorded CLI patch `provenance/patches/<destination>.diff`; after a deliberate edit of
one, run `mix swarm_code.provenance.sync --ref <pinned sha>` to record the patch, and
`--check` (in precommit) fails otherwise. A sync to a newer desktop commit 3-way merges patched
files and stops on a conflict, writing only `<destination>.sync-conflict` (resolve, then rerun
with `--resolved <destination>`). Ledger entries outside every mapping (the live-runtime copies
`lib/swarm_code/{llm,tools}`, `daemon/runtime/run.ex`, core `commands.ex`,
`service/command_dispatcher.ex`, the web shims) are frozen: after editing one, run
`mix swarm_code.provenance.repin <path>`. `third_party/` and `vendor/exqlite` are pinned copies checked
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
- The keyboard is composer-first (pass 70, D5): letters always type; Esc stops the streaming
  turn or closes the top layer and never moves focus; Ctrl-C closes a layer, else clears the
  draft (Ctrl-Z restores it), else stops the turn (also the turn Enter just sent, before it
  shows), and none of those arms the quit; two idle Ctrl-C presses within 1.5 s quit (pass71
  R1, asking "Stop N live runs and quit?" when runs are live); Enter before the conversation
  has loaded is kept and sent once it has (R2); `q` closes or quits only in select
  mode (Ctrl-T), dialogs and pickers. Ctrl-J (the port decodes a bare LF as Ctrl-J) and Ctrl-O insert a
  newline; Ctrl-X edits the draft in `$VISUAL`/`$EDITOR`. An approval card opens over the
  conversation by itself with `y Y A d D n`; only the letters of the decisions it offers answer it,
  and only while the draft is empty, whether it opened by itself or was focused with Ctrl-N, `n` or
  a badge (pass73 G2; there is no `a`); a draft typed under it is the composer's (pass73 G1: its
  `/` list, Enter, Tab, arrows, Ctrl-A/E/U/W, Ctrl-S, Alt-Enter; Ctrl-C clears it before it puts
  the card aside; Esc and PgUp/PgDn stay the card's), and with the draft empty Enter shows the
  whole command, then folds it (`Keymap.show_all?/2`). A run this session already asked to
  stop (`State.stops_asked`) is no longer "the turn", so the next Ctrl-C stops another or arms the
  quit. Wheel reports are on by default (pass73 T9): the wheel scrolls the pane under the pointer;
  Shift-drag (Option-drag in Terminal.app/iTerm2) selects text; `/mouse off` (kept in cli.json) or
  `SWARM_MOUSE=0` turns them off. Enter on the `/` list takes the highlighted command (runs it when
  it takes no argument); a message naming a workflow goes as `/create-workflow`, Ctrl-S sends it
  plain. `SwarmCodeCLI.UI.Composer.enter_action/1` is the one answer to "what does Enter do now"
  (send, steer, queue, run, complete, show all, fold) for the keymap, the footer and the pending
  marks.
- Measure glyphs with `SwarmCodeCLI.UI.Width.cells/2` under both ambiguous-width policies before
  drawing. Box drawing, half blocks and emoji are ambiguous or wide. Progress is the `▐` tick
  bar, not a solid fill. Colours come from `UI.Theme` (the web app's Carbon tokens); never invent
  a palette. The launchers build the capabilities by hand: the rich glyph tier (thin `▏` rails)
  needs truecolor and a `TERM` naming ghostty, kitty, wezterm or iTerm
  (`Capabilities.glyph_tier/4`), and the palette starts as `Theme.mode/3` (`SWARM_THEME` >
  cli.json `theme` > the desktop settings' `mode` > dark, through
  `Release.PersistedSession.start_preferences/3`); `/theme` switches it live
  (`{:terminal_preferences, …}` to the port owner, which also sends the port's tag-8 wheel
  command for `/mouse`). `/diff off` draws every tool row on one line.
- To drive the real TUI end to end, do not sleep inside the Python pty harness: it stops draining
  the pty and the port dies with fake `:draw`/`:restoration` errors. Use GNU screen
  (`screen -dmS name …`, then `screen -S name -p 0 -X width -w 170 45`, `-X stuff`,
  `-X hardcopy`; macOS's screen 4.00 does not pass `width -w` on to a detached window's app, so
  start it as `stty cols 170 rows 45; <command>` in the window's shell, and set
  `-X logfile flush 1` so a `-L` log holds the last frame), and always quit the TUI with its own quit path (Ctrl-C twice, and a third time if
  it asks "Stop N live runs and quit?") before closing the window. Screen sets `TERM=screen`
  inside its window, so pass `TERM=xterm-ghostty COLORTERM=truecolor` in the command to see the
  rich tier. The release prints a short exit summary to the main screen after it leaves the
  alternate screen (the runs the quit stopped, and `swarmcode --resume <id>` for the
  conversation on screen). `rel/env.sh.eex` starts the VM with `+Bd`, so a Ctrl-C in a cooked
  terminal (boot, `-p`, the moment after the summary) ends the process instead of opening the
  Erlang BREAK menu, and runs it under `umask 077` while keeping the user's umask in
  `SWARM_USER_UMASK` for the commands and hooks the model runs in the project
  (`RunCommand.umask_prefix/0`); the locked-branch test pins that file's hash. In screen, `hardcopy` mangles non-ASCII; the `-L` logfile keeps the raw bytes (use it
  to measure output per keystroke or per reply).
- The side panel (pass 72, direction D): `Projector.Panel` (full, compact), `Projector.Strip`
  (under 120 columns) and `Projector.PanelOrder` (the entries hint mode and the overlay walk)
  read S's wire facts (`AgentSummary.panel_state/now/lane/finding…`, `RunSummary.needs_you/
  reported/phases…`, derived in `daemon/service/panel_facts.ex`). `State.panel_mode` cycles on
  Ctrl-B and persists in `cli.json` beside the database (`Release.preferences_path/0`, 0600);
  `State.hint` (Ctrl-F, labels from `UI.Hint.labels/1`, also over an approval card) and
  `State.overlay` (`Projector.Overlay`, `Reducer.Overlay`, the `agent.detail` query, a steer
  with the agent's `node_id`) are O's. The overlay's `x` stops its agent through the undrawn
  `{:stop_agent, …}` keyboard action.
- Watch flow control (pass 72 F): the persisted backend sends up to 8 deltas ahead of the
  client's credit (the connection allows 16 frames, 512 KiB), a changed run re-sends only the
  transcript items that changed, and a `watch_ready` names its own body's revision. Before,
  a busy swarm overflowed the 128-delta queue every few seconds and a resync mid-run was
  rejected ("watch_ready rejected: revision"), closing the session on "the daemon connection
  closed". `cli.log` now carries the app's own `Logger` lines (the handler sets its filters; a
  `:default` handler without them keeps only OTP reports): look for `watch queue overflow`,
  `the daemon asked for a fresh … snapshot (reason)`, `watch_ready rejected: <check>`,
  `event rejected: <check>`, `closing the daemon connection: <why>` and `data source lost`.
- Scrolling counts an item's rows with `ScrollMetrics.height/3`, which is `Turns.height/3`, the rows
  the painter draws. An item that draws nothing (a thinking item with no text, a worker's call
  under a folded lane) counts 0 rows in `Scroll` too (pass 73 F9): clamped to 1, the first wheel
  notch from the bottom of a tool-using turn moved nothing.
- Nothing is refused because work runs (pass 73 T3/T8, `PersistedBackend` `dispatch_send`):
  run-launching commands (`/swarm`, `/plan <task>`, `/consensus`, `/create-workflow`, workflows,
  goals) start beside the live runs; a plain message while this conversation's chat run is
  registered steers the newest one (`Engine.steer/4`); `/compact` during a turn, and a message
  during a compaction, wait on the conversation's queue and drain when it ends. The `Outcome`
  says where a send went (`disposition` started | steered | queued) and a refusal why
  (`reason: %Refusal{code, text}`; the text is shown as is); the transcript marks a steered
  message (`target_kind: :steer`) and draws `queued_texts` after the live turn. User-facing
  words never say "the daemon".
- Busy sessions stay up (pass 73 T11): an ack for a dropped watch is answered, request ids are
  recent windows (4,096 daemon, 256 client), watches have their own 16 slots and the 33rd request
  gets `capacity_exceeded`, `send_timeout` is 45 s, the client's read backlog applies
  backpressure. Every close is logged on both sides with a redacted reason
  (`SwarmCode daemon closed a client connection: <why>`, `the client closed its connection`,
  `SwarmCode daemon refused a command (<op>): <code>`).
- A transcript item carries at most 8 KB of a prompt or reply and 2 KB of a tool's output
  (`PersistedBackend` `@reply_bytes`, the projection's `substr`), with a `detail_ref` for the
  rest; the transcript says how much is left and Enter (or `o`) on the item opens it whole. A
  snapshot that would not fit its byte limit falls back to 2 KB items (pass 71).
- The plain launcher closes at stdin EOF, so hold stdin open to see a model reply.
