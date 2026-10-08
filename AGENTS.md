# AGENTS.md

Guidance for coding agents (Claude Code, Codex, jcode) working in this repository.
Claude Code reads this file directly when the project has no `CLAUDE.md`; do not add a
`CLAUDE.md`, `.claude/CLAUDE.md` or `CLAUDE.local.md`, they would stop this file from loading.

## What this is

Product name (v0.2.0): **ncode**, lowercase; the installed command is `ncode`
(`rel/overlays/bin/ncode`), with `swarmcode` and `swarm-code` kept as deprecated aliases that
exec it. Internal names are unchanged on purpose: modules (`SwarmCode.*`, `SwarmCodeCLI.*`), OTP
apps and the release (`swarm_code_*`), Mix tasks, the data folder
`~/Library/Application Support/SwarmCode`, `swarm_code.db`, the logs, `.swarm_code/`, the desktop
bundle id `com.zaali.swarmcode`, the `SWARM_*` names the release reads, the cli.log `SwarmCode:`
prefixes and the export format `swarmcode-settings` (import also takes `ncode-settings`). The
launcher and the provider-file loader copy `NCODE_X` over `SWARM_X` (NCODE first, SWARM the
fallback; the list is in both files, pinned by `entry/ncode_alias_test.exs`). Model-facing and
other strings inside provenance-ledger files still say SwarmCode until they are recorded as
provenance patches.

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
| Release / install | `scripts/dev/build_release.sh` → `_build/prod/rel/swarm_code_cli`; `scripts/install.sh` installs `ncode` |
| Packaged entry points | `bin/ncode [DIR] [--new\|--continue\|--resume ID] [--model M] [-p PROMPT [--json]] [--plain [--ndjson]]`; the launcher validates flags in bash (usage exits 2 before any VM), the TUI is `bin/swarm_code_cli start` with `SWARM_RELEASE_TUI=1`, `-p`/`--plain` are `bin/swarm_code_cli eval 'SwarmCodeCLI.Release.main(System.argv())' …`; `-p` starts a new conversation unless `-c`/`--resume`/`SWARM_CONVERSATION` names one (pass 71). Exit codes 0 done, 1 failed, 2 usage, 3 startup refused, 4 changed elsewhere (`ncode config`), 129 SIGHUP, 143 SIGTERM (cli020 B9) |
| Settings (pass 74) | `ncode settings [QUERY]` opens the layer (`/settings`, F2); `ncode config help` lists the headless commands (`list/get/set/reset/keys/path/records/record/secret --stdin/search/mcp/export/import/doctor`) |
| Re-derive the desktop domain | `mise exec -- mix swarm_code.provenance.sync --ref <desktop sha>` (read-only `git` on `~/dev/swarm-code` or `$SWARM_CODE_UPSTREAM`); `--check` verifies (in precommit) |
| Re-pin a hand-edited ledger file outside the sync mappings | `mise exec -- mix swarm_code.provenance.repin <path> …` |

Providers (pass 70, decision D3): the database's providers and the conversation's own choice
decide the model, exactly like the desktop (`Providers.effective_model/2`). `SWARM_*` never
create provider rows or rewrite a conversation; only when the database has no usable provider at
all does the first run create one row from `SWARM_MODEL`/`SWARM_BASE_URL`/`SWARM_API_KEY` and say
so (a toast in the TUI, a stderr line headless). `ncode --model M` (env
`SWARM_MODEL_OVERRIDE`, set only by the launcher) is an in-memory session override applied at
each `Engine.start_*`; an explicit `/model` ends it. The launchers load only `SWARM_*`,
`NCODE_*`, `OPENAI_*` and `ANTHROPIC_*` from `~/.secrets` (or `NCODE_ENV_FILE` /
`SWARM_ENV_FILE`), never the whole file, and
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
  `build_release.sh`; `rm -rf _build/prod` before the next `mix test`) or inside a git worktree
  whose `deps` is a symlink. A green suite means: no `_build/prod`, no `MIX_QUIET`, and a main
  checkout or a worktree prepared as below. New release tests go under
  `apps/swarm_code_cli/test/swarm_code_cli/entry/`: `test/swarm_code_cli/release/` is one of
  that test's conditional paths and must not exist.
- Git worktrees (cli020 §4.1): clone, never symlink, from the main checkout before the first
  compile (APFS copy-on-write, so a worktree costs no disk until it diverges):

  ```sh
  git worktree add ~/dev/swarm-code-cli-wt/<name> -b <branch> main
  cd ~/dev/swarm-code-cli-wt/<name>
  cp -cR /Users/zaali/dev/swarm-code-cli/deps ./deps
  cp -cR /Users/zaali/dev/swarm-code-cli/_build ./_build      # includes _build/terminal-port
  mkdir -p apps/swarm_code_daemon/priv
  cp -cR /Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/priv/native apps/swarm_code_daemon/priv/native
  rm -rf _build/prod
  mise exec -- mix compile                                    # warning-free before you start
  ```
- Run test files as `env -u MIX_QUIET mise exec -- mix test <file>`, one app per call.
- Nothing hits a remote API: LLM and tool tests use a loopback HTTP server, and every schema test
  builds fixture databases under `apps/swarm_code_daemon/priv/schema/fixtures`, never the real one.
- `mix test` with files of two apps in one call fails ("paths given to mix test did not
  match"): run one call per app.
- The plain-demo golden `apps/swarm_code_cli/test/fixtures/plain/three_run_output.txt` is
  regenerated from `SwarmCodeCLI.Demo.Plain.run(:complete, …)` whenever the fake script changes.

## Architecture

Three umbrella apps with deliberate ownership boundaries (`apps/*/mix.exs`):

- **`swarm_code_core`**: small and dependency-light. `SwarmCode.Protocol.*` is the client/daemon
  wire (length-prefixed versioned JSON frames, envelopes, scope, `JsonLimits`, service
  handshake/request), `SwarmCode.Commands` the slash-command registry, and
  `SwarmCode.Governance.Provenance` the extraction audit.
- **`swarm_code_daemon`**: the domain extracted from the desktop app plus the daemon shell.
  `SwarmCode.Domain.*` is the desktop lineage, re-derived from desktop `7b8f379f` (desktop pass
  72, CLI 0.2.0) by `mix swarm_code.provenance.sync`; CLI-local files (`domain/runtime.ex`, `paths.ex`,
  `notifications.ex`, `pub_sub.ex`, `feature_catalog.ex`, `html.ex`,
  `engine/pending_interactions.ex`, `tools/agent_title.ex`) are never synced (Ecto SQLite Repo via vendored `exqlite`,
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
  `read_only` until `/trust`; `/approval read-only|auto|full` changes it (Shift-Tab in the
  composer cycles them), and like the desktop's `set_approval_mode` any manual pick also marks
  the project trusted (`Daemon.Service.ApprovalPick`, cli020 fix S3), saying so: `Approvals:
  read-only → auto · this project is now trusted` (the client's one Shift-Tab notice, fix U1,
  appends that remark when the answer's text contains `trusted`; keep the word). In `read_only` every write and command asks with the card's `y once ·
  d deny` (desktop pass 72 F1; the row's `allowed_decisions` are `approve`, `deny`, `deny_stop`
  and it carries `approval_mode`), headless counts the denials (`--fail-on-denied`). In `auto`,
  writes and `:safe` commands (`ls`, `git status`) run without asking and other commands ask.
  `ncode -p --approval read-only|auto|full` runs that session's runs in the mode (F8's
  `approval_mode:`, in memory; `auto`/`full` refused with exit 3 in an untrusted project). The
  project's `.swarm_code/config.json` `permissions` (`allow`/`ask`/`deny`, F10's
  `Engine.Rules`, trusted projects only) are decided before the mode.
- Runtime input never selects modules or creates atoms; JSON and text have byte, count and
  nesting ceilings that return errors rather than truncating.
- The canonical database is never reset, recreated or repaired. An unknown schema fails closed
  with `StartupError{code: :schema_incompatible}`. The domain is synced to desktop `4c7c577a`
  (desktop 0.2.0), re-synced to `7b8f379f` (desktop pass 72, no migration); its schema contract is
  `desktop-4c7c577` (58 migrations, `apps/swarm_code_daemon/priv/schema/desktop-4c7c577.json`),
  and `forward_compatible` lets the CLI run `20261015000004`, `20261016000001`,
  `20261016000002`, `20261017000004` and `20261018000001` itself after the verified backup.
  `mix swarm_code.provenance.drift` (in `mix precommit`; `--strict` in
  `scripts/dev/build_release.sh`, override `NCODE_ALLOW_DRIFT=1`) fails when the desktop's `main`
  has migrations the pin lacks: re-pin (sync, contract, manifest) before any release; the
  desktop's `mix ncode.cli_lockstep` is the same check from the other side.
  `Schema.Gate.admit_migration/2` refuses any other pending
  migration ("Open the SwarmCode app once to upgrade the database") or a database ahead of the
  manifest (`Schema.Refusal` holds both sentences). A database file (or its `-wal`/`-shm`) of
  this user whose mode is not 0600 is refused first, in `Schema.Probe`, with its own sentence
  and `chmod 600 <path>` (`Schema.Refusal.database_mode/1`, cli020 fix S4; the launcher's
  `PersistedSession.startup_words/3` lists it). When the desktop repo gains migrations,
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
`lib/swarm_code/tools`, `providers/provider.ex`, `daemon/runtime/run.ex`, core `commands.ex`,
`service/command_dispatcher.ex`, the web shims) are frozen: after editing one, run
`mix swarm_code.provenance.repin <path>`. A frozen copy that nothing calls any more is deleted
and its entry dropped with the sync tooling's writer
(`SwarmCode.Governance.ProvenanceSync.Ledger.load/1` + `write/2` from `mix run --no-start`),
never by hand; `verify` and `sync --check` must pass after. When two branches both change the
ledger or a recorded patch, take one side of `extracted-files.json` and the `.diff`, then re-run
`sync --ref <pinned sha>` and `repin` on the union of the frozen paths both sides changed
(`git checkout --ours` drops the other side's non-conflicting repins too). `third_party/` and `vendor/exqlite` are pinned copies checked
by `scripts/dev/sync_unicode_width.exs --check`, `sync_unicode_variants.py --check` and
`verify_terminal_port_licenses.py`. Hex deps are pinned with `==` and
`deps.unlock --check-unused` is a gate: do not add packages casually.

## TUI facts that constrain changes

- Bindings live only in `UI.Keymap.Bindings`; the help sheet, status hints and
  `docs/keybindings.md` derive from it. Never bind Ctrl-K (a window-manager chord). Alt is
  unreliable on macOS ghostty, so nothing essential may be Alt-only. Enhanced keys (kitty
  protocol) are used when the terminal offers them: the port probes `CSI ? u` + DA1 on the
  first alternate-screen activation (Ready waits for the DA1 answer, at most 500 ms), pushes
  `CSI > 1 u` (disambiguate) through the guard and pops it on every restore, suspend and
  emergency exit; Ready's bit 128 reports it and Shift-Enter then inserts a newline. A terminal
  that never answers starts normally. A bare Esc resolves after 40 ms.
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
  quit. Wheel reports are off by default (cli020 D5, cli.json `mouse`): the port writes
  `CSI ? 1007 h` (alternate scroll), the terminal sends the wheel as arrows, and one read of two
  or more identical Up/Down arrows is the Scroll input (`{:scroll, :up | :down, 1..32}`), which
  scrolls what the wheel scrolls by `count × terminal.wheel_lines`; the terminal selects text.
  `/mouse on` (or `SWARM_MOUSE=1`) sends wheel reports instead (Shift-drag selects). Enter on the `/` list takes the highlighted command (runs it when
  it takes no argument); a message naming a workflow goes as `/create-workflow`, Ctrl-S sends it
  plain. `SwarmCodeCLI.UI.Composer.enter_action/1` is the one answer to "what does Enter do now"
  (send, steer, queue, run, complete, show all, fold) for the keymap, the footer and the pending
  marks. Pass 75: an `ask_user` call is one note, layer `{:question, node_id}` (`UI.Question`, `Projector.Interview`): digits pick or tick, Space ticks (multi-select only), Tab moves list↔other, ←/→ step questions (`:dialog_right`/`:dialog_left`, else the focus cycle), Enter confirms, steps or sends (N `question.answer` requests at the final Enter), and Esc keeps the held answers (^N reopens).
- Measure glyphs with `SwarmCodeCLI.UI.Width.cells/2` under both ambiguous-width policies before
  drawing. Box drawing, half blocks and emoji are ambiguous or wide. Progress is the `▐` tick
  bar, not a solid fill. Colours come from `UI.Theme` (the web app's Carbon tokens); never invent
  a palette. The launchers build the capabilities by hand: the rich glyph tier (thin `▏` rails)
  needs truecolor and a `TERM` naming ghostty, kitty, wezterm or iTerm
  (`Capabilities.glyph_tier/4`), and the palette starts as `Theme.mode/3` (`SWARM_THEME`, which
  `bin/ncode` sets from `NCODE_THEME`, > cli.json `theme` > the desktop settings' `mode` > dark, through
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
  alternate screen (the runs the quit stopped, and `ncode --resume <id>` for the
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
  `{:stop_agent, …}` keyboard action. Pass 75 (V2): one row per agent sorted by attention (`Panel.Model.attention/2`) with an AI name (`spawn_agent`'s optional `title`, cleaned by `Domain.Tools.AgentTitle.clean/2`, stored in `nodes.title`; the slug shows only dim in the ^F overlay), a status line (`summary` from the `Daemon.Service.AgentStatus` Summarizer that `PersistedBackend` drives, off in test config `:summarize_agents`, cli.json `agent_summaries`, `/panel summaries on|off`) and one figure; a turn-limit stop (`stop_reason "turn_budget"`) is the client state `:turn_limit` and never a report; `$` only when `cost_usd` is a number; no lanes, legend, fills or ghost text in the panel. Workflow and consensus runs also draw their kind sections (`Shapes.before_agents/4`, `after_agents/4`) between the band and the found blocks (owner decision P-1).
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
- Settings (pass 74, `docs/research/2026-09-25-cli74-settings-outcome.md`): the catalogue is
  `SwarmCode.Settings.Registry` in core (171 entries: key, section, home layer
  `global|project|conversation|cli`, type, default, synonyms); a new setting is a registry entry
  plus its section's row, and `c74_acceptance_test.exs` (A3) fails until it is on its page once.
  The daemon side is `SwarmCode.Daemon.Service.Settings.*` (`Router`, one handler per area,
  `Values` with compare-and-set on every write, `Tasks` for slow work in the settings job pool,
  `Secrets.mask/1` → `%{"set", "hint"}`); the wire is `settings.query`/`settings.command` with
  `settings_update`/`settings_task` deltas on the shell watch, bounded by `Settings.WireBounds`
  (string keys only: a decoded secret field is `%{set:, hint:}` and `UI.Settings.Wire` turns it
  back into JSON). The client is `UI.Settings.*` (`Layer`, `Nav`, `Sections`, `Wire`, `Paste`,
  `DeepLink`), `UI/reducer/settings/*` and `UI/projector/settings.ex`; `Fake.Settings` +
  `Fake.SettingsIntegrations` serve the demos and most tests and must agree with the service
  (the search order compare-and-set is the whole list, readers too). Pasted keys travel once in
  the command's `secrets`, never in attributes, rows, undo, logs or exports (`c74_secret_canary_test`).
  `ncode config` (`Release.ConfigCommand`) uses the same service headless; while a session
  holds the data lease, database settings exit 3 and `cli.json` settings still work.
  `c74_client_e2e_test.exs` opens every section through the real socket, backend and handlers
  (`C74_E2E_OUT=<dir>` writes each page's rows and screen text).
  `cli.json` is `SwarmCode.Settings.CliFile` (64 KB bound, unknown keys and legacy values kept,
  0600 after every write, a symlink refused); its keys are the registry's `cli` entries
  (`terminal.*`, including `keys`, which `Keymap.Overrides` compiles over `Keymap.Bindings`).
  Settings work runs in a pool of 4 jobs per session (a 5th query `capacity_exceeded`, a 5th
  command `busy`) and at most 8 tasks (`Settings.Tasks`). The layer's key contexts are the
  seven Settings chapters of `docs/keybindings.md` (`mix swarm_code.keymap --check`);
  `docs/settings.md` is generated by `mix swarm_code.settings --write` (`c74_settings_docs_test`).
  Pass 75 (E, Strata): `Settings.Grid` owns the layout (`:wide` ≥160 rail 2/24 · page 30/82 ·
  note 116/118/40; `:rail` 120-159; `:strip` 90-119; `:small` 80-89); no `│` rules — regions are
  gutters; spines `╭ │ ╰` in `Settings.Strata.role/1` hues (session l1, project l2, env l4,
  flag l5, cli.json judge, global muted, default faint); the focus band is `{role, :on, :band}` →
  `chip_accent` background (reverse video in ansi16/mono); `:text_ghost`/`:border` are remapped
  to `:text_faint` in settings; the twin (`Glyphs.twin?/1`) draws `* | ! >`; editors keep the
  `%{value, lines, popover, context, footer}` map.

## CLI 0.2.0 (cli020) facts

The pass's binding contract is `docs/superpowers/plans/2026-10-07-cli-0.2.0/00_contract.md`, its
lane notes are in `notes/`, the outcome is `docs/research/2026-10-07-cli020-outcome.md`.

Provenance and domain (lane A):

- `SwarmCodeWeb.Format` maps to the frozen `SwarmCode.Domain.Format` (the pure `preview/2`,
  `clip_line/3`, `window/2`); repin it by hand when the desktop changes them.
- The CLI keeps its own Ultra (workflow + swarm tools, the CLI `@ultra` text): two recorded
  patches in `domain/tools.ex` and `domain/engine/prompts.ex`; keep them on every sync until the
  missions pass.
- The live runtime (`Daemon.Runtime.Run`, unsaved sessions) streams through the synced
  `SwarmCode.Domain.LLM` adapters (cli020 fix L, A5), chosen by the live kind in `Run`
  (`openai` → `OpenAI`, `anthropic` → `Anthropic`; no `:llm_providers` registry needed);
  `SwarmCode.Providers.Provider` stays its database-free configuration and becomes a synced
  provider row in `Run`. The frozen `lib/swarm_code/llm/**` copies are gone. Their CLI
  behaviours are recorded patches on `domain/llm/{http,anthropic,openai}.ex`, kept on every
  sync: the owned transport (the no-progress deadline and the hard cap are exact on a silent
  socket), `HTTP.with_call_clock/1` (one hard cap per provider call), the
  `:llm_max_response_bytes` ceiling (16 MiB) while reading, `HTTP.redact_key/2` (the request's
  key at any length, before the snippet is cut), no redirect URL or host in the logs, and a
  non-JSON SSE event fails the call (`notes/fix-L.md`). Saved sessions use the same patched
  adapters. One more patch on `domain/llm/http.ex` (fix S2): the retry callback gets
  `HTTP 500` when the retry came from a status, else the reason word, so the status line says
  `retrying 2/5 · HTTP 500`; upstream it to the desktop.
- Test fixtures the mapped tests call from `SwarmCode.Fixtures` live in
  `apps/swarm_code_daemon/test/support/domain_fixtures.ex` (`assistant_identity/0`, `eventually/2`).
- The CLI domain has no `LLM.Fake`: engine tests use the loopback OpenAI-compatible server
  (`SwarmCode.Test.LoopbackHTTP`, `SwarmCode.Test.C020Backend`).

Headless and release (lane B):

- **Headless (`-p`).** The launcher owns the grammar and exports; the release re-validates.
  `-p TEXT` with a pipe or file on stdin sends the stdin after the prompt
  (`SWARM_STDIN_PIPED=1`, set only by the launcher); `-p -` reads the prompt from stdin.
  `--json`/`--output-format json` print one object even on failure (`state: not_started`);
  `--output-format stream-json` prints the `--plain --ndjson` records and ends with
  `{"type":"summary",…}`. `--max-turns`/`--max-budget-usd` stop the owned run (exit 1);
  `--fail-on-denied` fails a done run that had denials. Denials are said in one stderr line.
  `--approval MODE` (`SWARM_HEADLESS_APPROVAL`) is a `PersistedBackend` start option passed to
  the runs it starts (plain prompts, prompts and slash commands drained from the queue, the
  dispatcher's chat/swarm launches and `retry_run`'s swarm; cli020 fix S1). Workflow runs keep
  the project's mode until the desktop's `Workflows.launch/1` takes an `approval_mode`
  (`notes/fix-S.md`); `/compact` has no tools, so no approval to carry.
- **Exit codes:** 0 done, 1 failed, 2 usage, 3 refused, 4 changed elsewhere (`ncode config`),
  129 SIGHUP, 143 SIGTERM (`Release.Signals`; SIGINT stays under `+Bd`).
- `--resume` takes an exact title or a 6+ character id prefix (`SessionSelection.resolve/2`);
  bare `--resume` opens the picker (`SWARM_RESUME_PICKER=1`, TUI only).
- The TUI exit summary (`PersistedSession.summary_text/1`) starts with `\r\e[2K` (it erases
  the launcher's `Starting ncode…`), then the last `exit_transcript` exchanges, then the block
  with `Spent`. Never in `-p`/`--plain`.
- `Details: <cli.log>` is printed only for a non-empty log and never for refusals the sentence
  itself fixes; logs are flushed before every `System.halt`.
- Stale `/tmp/scl-p-*`/`scl-h-*` folders are swept at start (`Release.SocketSweep`).

Service (lane C):

- The composer's `!cmd` runs in an owned task of the backend (`Daemon.Service.ShellEscape`, no
  approval: the user typed it) and is persisted as a `shell` message (the next turn reads it),
  sent as `DTO.ShellItem` entities, not transcript items. Clipboard images go through
  `Daemon.Service.ClipboardInbox` slots (`<config_dir>/cli-inbox`, 0700, 4 slots, 60 s); the path
  is always rebuilt from the token, never taken from the client. Rewind (`rewind.turns`,
  `rewind.apply`) lives in `Daemon.Service.Rewind` (`Conversations.supersede_from/2`, then the
  checkpoints); history search (`history.search`) and conversation search in
  `Daemon.Service.MessageSearch`, both project-filtered in SQL before the limit. Git facts
  (`git_branch`, `git_dirty`) come from one owned task at a time, 2 s bound; never read Git in
  a backend callback.

Keys and terminal (lane D):

- Option/Ctrl-←/→ and Alt-b/f move by word, Alt-d deletes one; Shift-Tab in the composer cycles
  Ask → Auto → Plan (`/approval`, `/plan`); `!cmd` runs a shell command (Ctrl-S sends it plain,
  Esc stops it); Ctrl-V attaches the clipboard's image (macOS, osascript/sips); Ctrl-L repaints
  every cell; Ctrl-R in the composer searches the project's prompt history (Switch run stays on
  Ctrl-R elsewhere); Esc Esc on an empty draft opens the rewind list; `r` in select mode retries a
  failed or stopped run; Enter/`o` on a tool row open its full output. Large pastes collapse to
  `[Pasted text #N · L lines]` and are expanded on send (`Draft.Pastes`). A `/search` with hits
  opens the palette on its `?` rows (`State.search_results`).
- Attention (D3): while the terminal reports focus lost, a new approval/question or the end of a
  run this session started rings once per 2 s as BEL, OSC 9 or an OS notification
  (`terminal.notify`), and the window title says `ncode · <project>` [`· working`, `· needs
  you`, `· done`] (`terminal.title`); the port saves and restores the terminal's own title.
- Copy (D4): `y` uses `/usr/bin/pbcopy` on macOS outside SSH, otherwise OSC 52 (tmux
  passthrough when `TMUX` is set); the notice says which.
- A failed screen update keeps the last good frame; only five failures in a row close the
  session (D12). New client-to-daemon ops go through `UI.Reducer.Remote`.
- A slow terminal slows the TUI, it never ends it (cli020 fix R): the port's frame writes
  (`FdWriter::patient`) wait for the terminal (a macOS pty holds about 1 KiB unread); only a
  gone terminal (EIO, POLLHUP/POLLERR) or termination ends them; restoration and the guard's
  mode writes (resume activation, `/mouse`, kitty push) stay bounded at 500 ms. The owner keeps
  shutdown, suspend, resume, redraw and mouse controls in a bounded outbox while the port is
  busy (one `:busy_retry` timer, the phase deadline bounds it, then `:terminal_timeout`), and
  answers every draw request within 400 ms (stale if the busy port could not take the frame;
  the next request draws the newest state). Regression: `scripts/dev/test_terminal_stall_pty.py`.
- Fix round U: the failure hint names the key that works where the focus is (`Ctrl-P → Retry
  failed run` in the composer, `r` in select mode); Alt-Left in an empty composer goes back
  (`:back`, else the run's conversation), with a draft it moves by word; the queue list has a
  cursor (Enter takes the prompt back into the composer through `queue.edit`, `d` drops it); list
  dialogs and pickers are as tall as their rows, and `N of M` counts selectable rows only.
- `State.panel_mode`'s struct default is `:full` (tests that build a state without
  preferences); the launch default is `:auto` through cli.json `panel` and `Init.Preferences`.

Projector, theme, settings (lane E):

- Palettes (E27): `terminal.palette` (cli.json `palette`) picks one of the desktop's eight
  themes; `Theme.palettes/0`, `Theme.palette_value/3` and `Paint.Options.palette`. The tables in
  `ui/theme.ex` are derived token by token from `~/dev/swarm-code/assets/css/themes.css` with faint
  and ghost raised to 4.5:1 / 3:1 on the surface and the card; change a palette only from that file
  and keep `cli020/e27_palettes_test.exs` (contrast per palette and mode) green. High contrast
  (`terminal.colors` = `high_contrast`, `Theme.put_high_contrast/1`) is a `:persistent_term` flag:
  tests that set it are `async: false`.
- Status line (E28): `terminal.status_items` (cli.json `status_items`) lists the items and their
  order; `projector/status.ex` reads it from `state.prefs`. New status facts join an item or the
  always-drawn tail (provider, rate limit, connection), never a free position.
- Markdown rows (E31): transcript Markdown goes through `Projector.MarkdownRows.rows/3`, keyed by
  `{sha256(text), inner, ambiguous, glyph tier, ascii?}`; anything new that changes
  `Markdown.rows/4`'s output must join the key. `Projector.project_reporting/1` returns the frame's
  computed rows beside the action table (the table stays `binary id => target`); the runtime owns
  the bounded cache. Measure with `scripts/dev/bench_markdown.exs` on
  `UI.Fixtures.long_conversation/3`; `cli020/e31_markdown_cache_test.exs` is the golden
  equivalence test (empty, warm, half-evicted).
- Settings registry counts (`c74_registry_test`): 180 entries, 140 scalar keys, 27 cli entries
  after cli020 E; a new entry updates the counts, its section's key list and `docs/settings.md`
  (`mix swarm_code.settings --write` from `apps/swarm_code_cli`).
- Lane-E test helpers: `test/support/cli020_e_helpers.ex` (`fixture/3`, `screen/1`,
  `put_workspace/2` which `Map.merge`s fields other lanes add, `cell_style/3`, `item/2`).
