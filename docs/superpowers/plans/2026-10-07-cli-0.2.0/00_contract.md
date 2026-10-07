# ncode CLI 0.2.0: binding contract (2026-10-07)

This contract is binding for every lane owner of the CLI 0.2.0 pass. Follow it literally. If the
code contradicts a line here, stop, write the contradiction in your lane notes
(`docs/superpowers/plans/2026-10-07-cli-0.2.0/notes/<LANE>.md`), take the smallest change that
keeps the intent, and say so in your done commit. Do not redesign anything silently.

Inputs: `~/.cache/ncode/cli-review-1007/report.md`, `findings.json` (`kept`, 106 ids), and the
screens in `ux-live/shots/*.txt`. Every finding id below is the id in `findings.json`.

## §1 Baseline and goal

| Item | Value |
| --- | --- |
| CLI repo | `/Users/zaali/dev/swarm-code-cli`, `main` = `c0808ea` = tag `v0.1.0` (the shipped CLI 0.1.0) |
| CLI versions today | `0.1.0` in `mix.exs`, `apps/swarm_code_core/mix.exs:7`, `apps/swarm_code_cli/mix.exs:7`, `apps/swarm_code_daemon/mix.exs:126` |
| CLI domain pin | desktop `6dd8d82ef29f9a6608b942259e1801846bb87ed9` (`provenance/sync-rules.json:3`), 57 migrations, contract `desktop-6dd8d82` |
| Frozen live-runtime copies | 34 ledger entries outside every sync mapping, all at `fb1b4ff8` (llm/*, tools/*, runtime/run.ex, core `commands.ex`, `commands/files.ex`, `service/command_dispatcher.ex`, their tests) |
| Desktop repo | `/Users/zaali/dev/swarm-code`, `main` = `4c7c577a` = desktop 0.2.0 `68512b59` + one commit that changes 3 test files only |
| Desktop schema | 58 migrations, last `priv/repo/migrations/20261018000001_mission_validator_models.exs` (additive: 3 columns on `conversations`, 3 on `settings`) |
| Pin distance | `git rev-list --count 6dd8d82..4c7c577a` = 432 |
| Site repo | `/Users/zaali/dev/llmotions-wt/ncode-site` (worktree of `~/dev/llmotions`, branch `ncode/site`, `9eedde7`) |

What 0.2.0 means, all of it, in one release (no 0.1.1):

1. The CLI opens a database that desktop 0.2.0 has migrated (58 migrations), and the domain is
   re-derived from the desktop (first `4c7c577a`, then the desktop commit that carries lane F).
2. A drift gate makes it impossible to build a CLI release (or a desktop installer, lane F) that
   silently locks the other app out of the shared database.
3. Read-only mode asks for each write and command (y once / d deny) in both apps.
4. The nine harness features of decision 4, the report's bug and UX fixes assigned in §5, and
   the desktop's words ("Worker model", "Validator model").
5. Version `0.2.0` everywhere the CLI states a version; the installer defaults to `0.2.0`.

## §2 Owner decisions (2026-10-07, binding)

1. One release: CLI 0.2.0, no 0.1.1 hotfix. Version 0.2.0 in all four `mix.exs`, the MCP and LSP
   `clientInfo`, the docs, and the `install.sh` default.
2. `ncode/A` is merged into CLI `main` and tagged `v0.1.0` (done; `main` = `c0808ea`).
3. Read-only mode asks for each write or command with the approval card (y once / d deny) instead
   of refusing, in both apps. The shared policy changes in the desktop first
   (`lib/swarm_code/engine/policy.ex`, the `decide("read_only", …)` clauses), then it is synced
   into the CLI. Headless (`-p`, `--plain`): policy blocks and denials count in `denied`, one
   stderr line says so, and a `--fail-on-denied` flag exists.
4. Features from other CLIs, all in this pass: (a) bell / OS notification and an OSC 2 window
   title when the agent needs you or a turn ends while the terminal is unfocused; (b) Shift-Tab
   cycles the approval and plan modes; (c) a `!cmd` shell escape in the composer; (d) the last
   turns are printed to the terminal's normal scrollback on exit; (e) large pastes collapse to a
   chip; (f) an `/effort` picker; (g) a token and cost line in the exit summary; (h) conversation
   rewind (the conversation as well as the files, like Claude Code `/rewind` and OpenCode
   `/undo`), reusing the desktop's supersede semantics (`messages.superseded_at`, edit and resend
   in place, Checkpoints for the files); (i) pasting images from the macOS clipboard.
5. Accepted defaults: Q2 keep the strict fail-closed schema gate and add a release-time and
   precommit provenance drift check; Q3 shared engine behaviour and bugs are fixed in the desktop
   first, then synced (CLI-only patches only where the desktop already has the fix or the code is
   CLI-only); Q5 mouse capture off by default plus alternate scroll (`CSI ? 1007 h`), so the wheel
   scrolls and native selection works; Q6 relabel `/ultra` honestly now (CLI Ultra runs
   workflows, not desktop missions), missions are ported next pass; Q7 `/consensus <task>` is
   one-shot for that turn; Q8 the side panel is auto (hidden, or a one-line strip, until two or
   more agents or a needs-you item); Q10 installer fixes in the site repo are a small lane.
6. Deferred, do not plan: OS sandbox, MCP OAuth, Linux builds, plugins, ACP/IDE integration,
   multi-client daemon and concurrent sessions, the desktop missions port.
7. Labels: the desktop renamed "Sub agent model" to "Worker model" and added "Validator model"
   (desktop 0.2.0). The CLI uses the same words.

Hard rules for every lane: never touch `~/Library/Application Support/SwarmCode/**` or
`~/.secrets`; never print secrets or private hosts; never run `mix ecto.reset`; tests use
`LLM.Fake`, loopback servers and fixture databases only; no new Hex, npm or Cargo dependency
(`deps.unlock --check-unused` and the `==` pins are gates); every shell command you run finishes
in under 90 s with small output (run long suites with `run_in_background` and poll); no
`Task.start/1`; no atoms from runtime input.

## §3 Lanes and file ownership

Lanes (the orchestrator's split, kept; one change, justified below):

| Lane | Repo, branch, worktree | Scope |
| --- | --- | --- |
| A | CLI, `cli020/A` from `main`, `~/dev/swarm-code-cli-wt/cli020-A` | provenance sync to desktop `4c7c577a`, schema 58, drift gate, version 0.2.0, labels that come from synced code; later A' (re-sync to the desktop commit that carries F) |
| B | CLI, `cli020/B` from A's merge | headless, launcher, onboarding, `ncode config`, plain and one-shot, the exit summary |
| C | CLI, `cli020/C` from A's merge | daemon service backend and the client-daemon wire (both halves) |
| D | CLI, `cli020/D` from A's merge | input, keymap, reducer, terminal port (Rust), session runtime, effects, mouse |
| E | CLI, `cli020/E` from A's merge | projector, screens, copy, theme, core `commands.ex`, settings registry, generated docs |
| F | desktop, `cli020/F-desktop` from `4c7c577a`, `~/dev/swarm-code-wt/cli020-F` | desktop-first shared engine changes |
| G | site, `cli020/G` from `ncode/site`, `~/dev/llmotions-wt/cli020-G` | `code/install.sh` and the public CLI docs |

Changes against the orchestrator's split, with the reason:

- The client half of the wire (`apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/**`,
  `ui/intent.ex`, `ui/request_resolver*`) belongs to C, not D or E: every new request needs its
  daemon handler, its DTO decode and its `Fake` answer to agree, and one owner keeps them
  agreeing (AGENTS.md: "`Fake.Settings` … must agree with the service").
- `apps/swarm_code_daemon/lib/swarm_code/domain/engine/pending_interactions.ex` and
  `daemon/boot.ex` are CLI-local but they consume F's engine change, so they belong to A (A'),
  not C.
- `daemon/foundation_gate.ex` belongs to A (manifest source). C's desktop poll (bugs-6) lives in
  a new C module and calls `FoundationGate.desktop_running?/1`, which A adds (A3).

### Provenance rule (all lanes)

- Files under a `provenance/sync-rules.json` mapping (`domain/**`, the migrations,
  `priv/agents`, `priv/workflows`, `priv/skills`, `priv/spec_master.md`, the mapped domain
  tests) are derived. Only A edits them, and only through `mix swarm_code.provenance.sync`
  (patches are recorded by re-running the sync at the pin). Exceptions: the CLI-local files
  listed in AGENTS.md (`domain/runtime.ex`, `paths.ex`, `notifications.ex`, `pub_sub.ex`,
  `feature_catalog.ex`, `html.ex`, `engine/pending_interactions.ex`, `tools/agent_title.ex`),
  which have owners in the table below.
- The 34 frozen ledger entries may be edited by their owner below; the owner runs
  `mise exec -- mix swarm_code.provenance.repin <path>` in the same commit. Lanes C and E may
  repin only `apps/swarm_code_daemon/lib/swarm_code/daemon/service/command_dispatcher.ex` (C) and
  `apps/swarm_code_core/lib/swarm_code/commands.ex` (E). Conflicts in
  `provenance/extracted-files.json` at merge are resolved by the finisher re-running `repin` on
  the union of those paths, never by hand.
- Shared engine behaviour goes to F (desktop first). A CLI provenance patch exists only where §6
  says so (A5, A6).

### File ownership (one owner per file; paths relative to the repo of the lane)

Prefixes: `core/` = `apps/swarm_code_core/lib/swarm_code/`, `dmn/` =
`apps/swarm_code_daemon/lib/swarm_code/`, `cli/` = `apps/swarm_code_cli/lib/swarm_code_cli/`,
`ui/` = `cli/ui/`. A test file belongs to the owner of the module it tests; a new test file
belongs to the lane that creates it.

| Owner | Files |
| --- | --- |
| A | `provenance/**`, `governance/**`, `SOURCE_AUTHORIZATION.md`, `core/governance/provenance.ex`, `apps/swarm_code_core/lib/mix/tasks/swarm_code.provenance.*.ex` (+ new `swarm_code.provenance.drift.ex`), every synced file under `dmn/domain/**` and its mapped tests, `apps/swarm_code_daemon/priv/{domain_repo,agents,workflows,skills,schema}/**`, `priv/spec_master.md`, `dmn/daemon/schema/**`, `dmn/daemon/foundation_gate.ex`, `dmn/daemon/boot.ex`, `dmn/daemon/shutdown.ex`, `dmn/domain/runtime.ex`, `dmn/domain/engine/pending_interactions.ex`, the frozen live copies `dmn/llm.ex`, `dmn/llm/**`, `dmn/tools/**`, `dmn/providers/provider.ex`, `dmn/daemon/runtime/run.ex`, `dmn/commands/files.ex` and their tests, the four `mix.exs`, `scripts/dev/build_release.sh`, `scripts/dev/check_schema_snapshot.sh`, `README.md` |
| B | `cli/release.ex`, `cli/release/**`, `cli/plain/**`, `cli/demo/plain*.ex`, `apps/swarm_code_cli/test/fixtures/plain/**`, `rel/**`, `scripts/install.sh`, `scripts/dev/load_provider_env.sh`, `scripts/dev/*_session.{sh,exs}`, `scripts/dev/test_saved_session_pty.py`, `scripts/dev/test_launcher_environment.py`, `dmn/daemon/service/session_configuration.ex`, `dmn/daemon/service/session_selection.ex`, `dmn/daemon/service/settings/providers.ex` |
| C | `dmn/daemon/service/**` except the three B files above, `dmn/daemon/service.ex`, `dmn/daemon/application.ex`, `dmn/domain/feature_catalog.ex`, `dmn/domain/paths.ex`, new `dmn/daemon/service/desktop_watch.ex`, `dmn/daemon/service/shell_escape.ex`, `dmn/daemon/service/clipboard_inbox.ex`, `dmn/daemon/service/rewind.ex`, `core/protocol/**`, `ui/data_source/**` (DTOs, `Fake`, `Daemon` transport, `request.ex`), `ui/intent.ex`, `ui/request_resolver.ex`, `ui/request_resolver/**`, `ui/read_model.ex`, `ui/watch_state.ex`, `scripts/dev/test_live_session_pty.py` |
| D | `ui/action.ex`, `ui/effect.ex`, `ui/effect_runner.ex`, `ui/reducer.ex`, `ui/reducer/*.ex` (not `reducer/settings.ex`, not `reducer/settings/**`), `ui/keymap.ex`, `ui/keymap/**`, `ui/input.ex`, `ui/composer.ex`, `ui/draft*.ex`, `ui/draft/**`, `ui/drafts.ex`, `ui/editor*`, `ui/vim.ex`, `ui/hint.ex`, `ui/state.ex`, `ui/init.ex`, `ui/capabilities*`, `ui/scroll*.ex`, `ui/timer_supervisor.ex`, `ui/session_runtime.ex`, `ui/renderer/**`, `native/terminal_port/**`, `docs/implementation/terminal-port-wire-v1.md`, `docs/keybindings.md` (generated), `scripts/dev/test_terminal_port_pty.py`, `scripts/dev/test_terminal_demo_pty.py`, `scripts/dev/check_terminal_port.sh` |
| E | `ui/projector.ex`, `ui/projector/**`, `ui/paint*`, `ui/scene*`, `ui/layout.ex`, `ui/layout/**`, `ui/theme.ex`, `ui/transcript.ex`, `ui/model_picker.ex`, `ui/switcher.ex`, `ui/slash_palette.ex`, `ui/library.ex`, `ui/question.ex`, `ui/layer_spec.ex`, `ui/init/preferences.ex`, `ui/settings/**`, `ui/reducer/settings.ex`, `ui/reducer/settings/**`, `ui/fixtures.ex`, `cli/demo/**` except plain, `core/commands.ex` (frozen entry, repin), `core/settings/**`, `docs/settings.md` (generated) |
| F | desktop: `lib/swarm_code/engine/policy.ex`, `engine/operation.ex`, `engine/run_server.ex`, `engine.ex` (F8, F9 only), `conversations.ex`, `conversations/message.ex`, `conversations/node.ex` (one virtual field), `engine/prompts.ex`, `attachments.ex`, `hooks.ex`, `project_config.ex`, `quit.ex` (F9 only), `tools.ex`, new `tools/update_plan.ex`, new `engine/rules.ex`, `lib/swarm_code_web/components/chat.ex` (approval card and the shell row only), `side_chat.ex` and `swarm_pane.ex` (their `approval_actions` call sites only), `mix.exs` (alias only), new `lib/mix/tasks/ncode.cli_lockstep.ex`, their tests, `CHANGELOG.md`, `AGENTS.md` (one line) |
| G | site: `code/install.sh`, `content/ncode/docs/cli/*.md`, `content/ncode/docs/shared/approvals.md` |
| Finisher | `AGENTS.md` of the CLI (lanes put their AGENTS.md text in their notes file), merge resolution, `docs/research/2026-10-07-cli020-outcome.md` |

Files that more than one lane needs, and how the second lane gets its change:

| File | Owner | Others |
| --- | --- | --- |
| `core/commands.ex` | E | C's dispatcher handles the new server actions `:rename_conversation`, `:delete_conversation`, `:fork_conversation`, `:undo_turn`, `:show_effort` (E3). Slash commands are parsed by the daemon (`command_dispatcher.ex:84-99`); the TUI answers some itself through `Keymap.local_command/1` (D) — `/queue …`, bare `/rewind`, `/undo`, bare `/effort`/`/swarm_effort` become local there (D10, D18, D20), never through a `client?/1` flag (`client?/1` takes only a name, `commands.ex:115`) |
| `ui/keymap.ex`, `ui/keymap/bindings.ex` | D | E sends D the rows it needs (E24's scroll keys); `Keymap.local_command/1` is D's |
| `ui/slash_palette.ex` (`@local` entries) | E | D's new local commands (§8.3) get their palette rows from E |
| `ui/composer.ex`, `ui/draft*.ex` | D | E reads `shell?` and the `pastes` map only |
| `ui/init/preferences.ex` + `core/settings/registry/terminal.ex` | E | D reads the new keys of §8.4 (mouse default off, notify, title, paste collapse, wheel lines, notice seconds); the launch hand-off in `release/persisted_session.ex` `start_preferences/3` is B's (one pass-through change, §8.4) |
| `ui/state.ex` (`panel_mode` default and type) and the Ctrl-B cycle in `ui/reducer.ex` | D | E5 owns the `:auto` meaning in `Preferences` and the projector; D adds `:auto` to the state type, the default and the cycle |
| `ui/data_source/dto/*.ex` | C | D and E read the new fields listed in §8.2 |
| `dmn/daemon/service/persisted_backend.ex` | C | B, D, E never edit it; B13 changes `session_configuration.ex` only |
| `cli/plain/command.ex`, `cli/plain/**` | B | nobody else |
| `ui/reducer.ex` | D | E's new layers (`{:rewind, …}`, `{:effort_picker, …}`, `{:history_search, …}`, `{:queue_list}`) are opened and closed by D's reducer; E only draws them |
| `dmn/daemon/boot.ex` | A | C's ledger prune runs from `PersistedBackend.init/1` instead (C3) |
| `dmn/daemon/foundation_gate.ex` | A | C calls `FoundationGate.desktop_running?/1` (A3) |
| `dmn/domain/engine/pending_interactions.ex` | A (A'2) | C and D only read `allowed_decisions` |
| `provenance/extracted-files.json` | A | C and E run `repin` for their one frozen file (see the provenance rule) |

## §4 Order, dependencies and worktrees

```
phase 1   A (alone, CLI)                         F (desktop, may start at once: it does not touch the CLI)
            | orchestrator merges cli020/A into CLI main = M1
phase 2   B, C, D, E (CLI, from M1)   G (site)   F continues
            |  finisher merges B, C, D, E          | orchestrator merges cli020/F-desktop into desktop main = Fm
            |  into cli020/integration = M2 (§9.3 step 1)
phase 3   A' (owner A, branch cli020/A2 from M2, and only once Fm exists):
          mix swarm_code.provenance.sync --ref Fm, then A'1..A'3
phase 4   finisher: merge cli020/A2 into cli020/integration, remove the stubs, full gates (§9), done
phase 5   live QA through the capture harness (§9.4), then the orchestrator tags v0.2.0
```

- A runs alone because it rewrites ~110 domain files and the schema contract; every other CLI
  lane branches from its merge (M1). F starts at the same time as A (different repo).
- A' is owned by A (it knows the sync's conflicts and patches). A' starts only when F's done
  commit is merged into desktop `main` (Fm), so the CLI never pins a desktop commit that is not on
  desktop `main`. F adds no migration (hard rule for F), so A' changes no schema contract.
- A2 branches from M2 (B..E merged), not from M1: A'3 calls C2's
  `CommandLedger.staged_attachment_ids/0`, and the finisher's stub removal (§8.1) touches C's
  files, so A' must see C's code. If C slips, A'1/A'2 may start from M1 and A'3 waits for M2.
- B, C, D and E never wait on each other: everything one needs from another is in §8 with a
  stub rule (code against the interface; if the other lane has not landed it yet, the focused
  test uses `Fake` or a local stub and the finisher removes the stub).
- Done marker: each lane's last commit message is exactly `cli020 <X>: done` (`cli020 A: done`,
  `cli020 A2: done`, … `cli020 G: done`). Commit messages of a lane start `cli020 <X><n>:` with the
  task id (`cli020 C5: retry status reaches the turn header`), and end with the attribution lines
  the orchestrator gives.
- Lane notes: `docs/superpowers/plans/2026-10-07-cli-0.2.0/notes/<X>.md` (CLI lanes) or the same
  path in the CLI repo for F and G (the orchestrator copies them). Record deviations, the tests you
  ran and the AGENTS.md text the finisher must add.

### §4.1 CLI worktree recipe (lanes A, A2, B, C, D, E, finisher)

```sh
cd /Users/zaali/dev/swarm-code-cli
git worktree add ~/dev/swarm-code-cli-wt/cli020-X -b cli020/X main     # A from main; B..E from M1
cd ~/dev/swarm-code-cli-wt/cli020-X
cp -cR /Users/zaali/dev/swarm-code-cli/deps ./deps                      # APFS clone, not a symlink
cp -cR /Users/zaali/dev/swarm-code-cli/_build ./_build                  # includes _build/terminal-port
mkdir -p apps/swarm_code_daemon/priv
cp -cR /Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/priv/native apps/swarm_code_daemon/priv/native
rm -rf _build/prod                                                      # locked_branch_test fails while it exists
mise exec -- mix compile                                                # must be warning-free before you start
```

- `cp -c` makes copy-on-write clones (APFS), so a worktree costs no disk until it diverges and
  `deps` is a real directory. AGENTS.md's symlink recipe is replaced by this one; the finisher
  updates AGENTS.md.
- `locked_branch_test.exs` fails with a symlinked `deps` or an existing `_build/prod`. With the
  clones above and no `_build/prod` it is expected to pass in a worktree (GUESSED, §10 X12); if it
  still fails there, note it and rely on the finisher's run in the main checkout. No other test is
  known to need the main checkout.
- Lane D rebuilds the port after Rust changes: `scripts/dev/check_terminal_port.sh` (it writes
  `_build/terminal-port/debug/swarm-terminal-port`, inside the worktree).
- Never `unset` anything in the user's shell; for the test gotcha run suites with
  `env -u MIX_QUIET mise exec -- mix test …`.

### §4.2 Desktop worktree recipe (lane F)

```sh
cd /Users/zaali/dev/swarm-code
git worktree add ~/dev/swarm-code-wt/cli020-F -b cli020/F-desktop 4c7c577a
cd ~/dev/swarm-code-wt/cli020-F
cp -cR /Users/zaali/dev/swarm-code/deps ./deps
cp -cR /Users/zaali/dev/swarm-code/_build.noindex ./_build.noindex
mise exec -- mix compile
```

F never opens `swarm_code_dev.db` of the main checkout and never runs `mix ecto.reset`; the test
database is created inside the worktree. F's gate is `mise exec -- mix precommit` in the worktree.

### §4.3 Site worktree recipe (lane G)

```sh
git -C /Users/zaali/dev/llmotions worktree add ~/dev/llmotions-wt/cli020-G -b cli020/G ncode/site
```

G's gates: `sh -n code/install.sh`, `python3 -I tools/test_build_ncode.py`,
`node tools/test_release_layout.mjs` (both exist in `tools/`), and the install.sh cases of §6 G1.
G never runs `tools/deploy.sh`.

### §4.4 Machine budget

- At most two full test suites at once across all lanes (CLI `mix test` ~15 min, desktop
  `mix precommit`). A lane that wants a full suite writes `RUNNING <lane> <time>` into
  `~/.cache/ncode/cli020/suite-slots` (create the file, one line per running suite) and waits while
  two lines are present; it deletes its line when the suite ends.
- Lanes run focused tests only (`env -u MIX_QUIET mise exec -- mix test <file>`, one app per call,
  from the umbrella root of the worktree). Only the
  finisher and F run full suites (`mise exec -- mix precommit`, ~15 min for the CLI).
- PTY suites use their own terminals; run one PTY suite at a time per lane.

## §5 Finding assignment (all 106 kept ids)

"Task" names the primary task; tasks in parentheses carry a part of the fix. Deferred ids get no code in this pass.

| # | Finding | Sev | Title (short) | Lane | Task |
| --- | --- | --- | --- | --- | --- |
| 1 | tui-code-1 | critical | CLI 0.1.0 refuses to open the shared database after desktop 0.2.0 has migrated it | A | A3, A4 |
| 2 | bugs-2 | major | ncode -p - (and the documented git diff / ncode -p -) fails for any non-ASCII stdin... | B | B1 |
| 3 | bugs-3 | major | Headless output and plain input are locale-dependent: under LANG/LC_ALL=C, -p, --jso... | B | B2 |
| 4 | bugs-4 | major | A staged /attach image older than 24 h is pruned but its staging row stays, so every la... | C | C2 (+F5, A'3) |
| 5 | bugs-5 | major | SIGHUP, SIGTERM and SIGINT kill the VM without running Shutdown or any after clean-up... | B | B9 |
| 6 | bugs-6 | major | A desktop launched after the CLI session started is never detected; its boot recovery m... | C | C4 |
| 7 | bugs-7 | major | Queued prompts are stranded: switching conversation, quitting or restarting drops the d... | C | C1 (+E3) |
| 8 | bugs-13 | major | Env loader skips the whole ~/.secrets file as soon as any *_API_KEY is exported; a miss... | B | B14 |
| 9 | competitors-1 | major | Only one ncode process (or the desktop app) can use the database; no concurrent session... | deferred | deferred: decision 6 (multi-client daemon / concurrent sessions) |
| 10 | competitors-2 | major | No ask-before-edit with diff: writes are binary allowed or blocked, no per-edit review | F | F1 (+E14: the read-only card shows the diff; read-only is the ask-before-edit mode) |
| 11 | competitors-3 | major | No OS-level sandbox for agent shell commands | deferred | deferred: decision 6 (OS sandbox) |
| 12 | competitors-4 | major | Headless -p has no event stream, no approval/turn/budget flags and no output-format switch | B | B3 (--fail-on-denied), B23 (--output-format, --max-turns, --max-budget-usd, --approval; +F8) |
| 13 | competitors-5 | major | The full-screen alt screen leaves nothing in terminal scrollback after quit; native sel... | B | B21 (scrollback on exit, decision 4d) |
| 14 | competitors-8 | major | Rewind restores files only; the conversation cannot be rewound or an earlier prompt edi... | C | C16 (+F2, D10, E15; decision 4h) |
| 15 | competitors-9 | major | No ! shell escape in the composer | C | C15 (+F3, D7, E15; decision 4c) |
| 16 | competitors-11 | major | No permission rules (allow/ask/deny patterns); only modes plus an always-allow prefix list | F | F10 (+C23 config whitelist, E30 Settings rows) |
| 17 | competitors-14 | major | No live plan/todo checklist for a turn | F | F11 (+C23 `RunSummary.plan`, E29 panel section) |
| 18 | competitors-15 | major | MCP over HTTP supports static headers only; no OAuth sign-in flow | deferred | deferred: decision 6 (MCP OAuth) |
| 19 | competitors-17 | major | macOS arm64 only; no Linux, Intel Mac or Windows build | deferred | deferred: decision 6 (Linux builds) |
| 20 | onboarding-2 | major | Bare ncode on a fresh install exits 3 with an error instead of opening Providers setup | B | B12 |
| 21 | onboarding-4 | major | Standard provider env vars are ignored, and a model+key without a base URL fails with a... | B | B13 |
| 22 | onboarding-5 | major | ncode -p in a new (untrusted, read-only) project silently does nothing, exits 0, and ... | B | B3 (+F1) |
| 23 | onboarding-7 | major | Piped stdin is silently dropped when a -p PROMPT is given | B | B1 |
| 24 | parity-3 | major | Lockstep design: every desktop migration locks out the previously shipped CLI, and noth... | A | A7 (+F6) |
| 25 | parity-4 | major | Provenance pin is 431 desktop commits behind; re-sync touches 108 lib files and 10 patc... | A | A1, A2 |
| 26 | parity-5 | major | Live-runtime copies are frozen at fb1b4ff, older than the pin, and need a manual repin | A | A5 |
| 27 | parity-6 | major | Spec-74 BUGS-1 (project config.json hook install via auto-approved write) is not fixed ... | A | fixed by the sync (desktop a64d6ff6) for domain/tools/path.ex; A5 ports it to the live copy dmn/tools/path.ex; A9 verifies |
| 28 | parity-7 | major | Ultra means different things: the CLI still ships 'big tasks become workflows', desktop... | E | E2 (+A6) |
| 29 | tui-code-2 | major | Shift-Enter newline can never work: the port decodes CSI-u but never turns the keyboard... | D | D2 |
| 30 | tui-code-3 | major | Word movement is dead on macOS: Option-arrows arrive as ESC b / ESC f and the keymap ig... | D | D1 |
| 31 | tui-code-5 | major | No attention signal when an approval, question or run needs you: bell effect is defined... | D | D3 (decision 4a) |
| 32 | tui-code-6 | major | Copy is OSC 52 only, always reports 'Copied N lines', and refuses anything over 64 KiB | D | D4 |
| 33 | tui-code-7 | major | CLI still says 'Sub-agent model'; no Worker/Validator models, mission cards or speed mo... | E | E1 (+C17) |
| 34 | ux-live-1 | major | Ctrl-P palette opens with its selected row scrolled out of view, and arrowing above the... | E | E6 (+D15) |
| 35 | ux-live-2 | major | Workers that changed nothing report the user's uncommitted changes as their own ('75 fi... | A | fixed by the sync (desktop 93b58ea6, BUGS-59: a clone starts at HEAD); A9 verifies with a dirty-tree test (+F4 desktop test, E13 user-facing row) |
| 36 | ux-live-3 | major | A provider 500 shows only 'thinking ▮' for 89 s with no retry status, then the error is... | C | C5 (+E12) |
| 37 | ux-live-4 | major | 'retry from the palette' points at an action the palette doesn't have | C | C6 (+D16, E9) |
| 38 | ux-live-5 | major | In read-only mode commands are refused outright, with no approval offered and no path f... | F | F1 (+A'2) |
| 39 | ux-live-9 | major | /consensus <task> leaves the conversation in Consensus mode, but its description says '... | C | C7 (+E3) |
| 40 | ux-live-12 | major | In select mode, a background command's output and exit status can't be opened; the row ... | C | C10 (+D17, E19) |
| 41 | bugs-8 | minor | --plain: refused sends and queued prompts do not affect the exit code; the queue is l... | B | B6 |
| 42 | bugs-9 | minor | --plain at EOF with a pending approval says 'open ncode to give it', but the run is s... | B | B6 |
| 43 | bugs-10 | minor | --json prints nothing to stdout when startup is refused or usage is wrong, although t... | B | B4 |
| 44 | bugs-11 | minor | A failed start still creates an empty conversation (and a project row): the session is ... | B | B11 |
| 45 | bugs-14 | minor | Editor command is word-split but not quote-aware: an $EDITOR with a quoted path or argu... | D | D14 |
| 46 | bugs-15 | minor | Private socket folders under /tmp are never swept after a hard exit | B | B10 |
| 47 | bugs-16 | minor | -p --json text is run through the terminal sanitizer, so the JSON text is not the m... | B | B5 |
| 48 | bugs-17 | minor | Esc/Ctrl-C stopping a turn immediately starts the next queued prompt | C | C1 |
| 49 | bugs-19 | minor | cli_command_ledger is append-only for ever; its updated_at index is never used to prune | C | C3 |
| 50 | bugs-20 | minor | Plain presenter aborts the whole session when stdout blocks for more than 1 s (slow or ... | B | B7 |
| 51 | competitors-6 | minor | No image paste from the clipboard; images need a typed path with /attach | D | D9 (+C14, E15; decision 4i) |
| 52 | competitors-10 | minor | Hooks support only three events and have no management UI | F | F9 (+C23 config whitelist, E30 Settings list, A'4 `session_end` in the CLI shutdown) |
| 53 | competitors-12 | minor | --resume needs a full conversation UUID; no picker or --last form | B | B19 |
| 54 | competitors-18 | minor | No Shift-Tab (or other single key) to cycle Build/Plan and approval modes | D | D6 (decision 4b) |
| 55 | competitors-19 | minor | No reverse history search or prompt stash in the composer | D | D19 (+C20 query, E15 drawing) |
| 56 | competitors-20 | minor | Status line is fixed: no git branch or diff stats, no configurable items, no terminal t... | D | D3 (OSC 2 title), C22 (branch and dirty facts), E28 (status items setting) |
| 57 | competitors-21 | minor | Single built-in Carbon theme (dark/light); desktop's eight themes and syntax themes are... | E | E27 |
| 58 | competitors-23 | minor | No IDE or editor integration (no ACP server, no open-in-editor from a tool row) | deferred | deferred: decision 6 (ACP/IDE integration) |
| 59 | competitors-24 | minor | No plugin or extension packaging for commands, agents, skills, hooks and MCP together | deferred | deferred: decision 6 (plugins) |
| 60 | onboarding-3 | minor | Details: cli.log in error messages points at an empty file; headless and startup fail... | B | B15 |
| 61 | onboarding-8 | minor | install.sh treats any extra argument as safe: --uninstall --help ran a real uninstall... | G | G1 |
| 62 | onboarding-9 | minor | Installer's last message has no provider next step and no PATH one-liner; docs screensh... | G | G1 |
| 63 | onboarding-10 | minor | No conventional subcommands: ncode help, version, doctor, update, login all a... | B | B16 |
| 64 | onboarding-12 | minor | config doctor exits 1 on a pristine install, flags optional things as failures, and g... | B | B17 |
| 65 | onboarding-13 | minor | config get / list / doctor while a session is open: exit 0 with an unavailable pl... | B | B17 |
| 66 | onboarding-14 | minor | Docs say ncode config keys lists key bindings, but it lists settings keys | G | G2 (+B17 help text) |
| 67 | onboarding-15 | minor | config record add provider --preset other fails; only exact lowercase preset ids work... | B | B18 |
| 68 | onboarding-16 | minor | A failed network call is reported as the key being refused | B | B18 |
| 69 | onboarding-18 | minor | Full-screen start shows a blank terminal for about 4 seconds | B | B20 |
| 70 | onboarding-19 | minor | A fresh install already shows '9 changed from default' in Settings and config list --m... | C | C13 |
| 71 | onboarding-20 | minor | config set project.trusted on for a not-yet-opened folder gives a dead-end error | B | B17 |
| 72 | onboarding-21 | minor | Env-onboarded provider is named after the host, but the docs' next step assumes a prese... | B | B13 |
| 73 | onboarding-22 | minor | Installer replaces the release non-atomically | G | G1 |
| 74 | onboarding-23 | minor | ncode --plain prints the opening transcript duplicated | B | B8 |
| 75 | onboarding-24 | minor | --help is thin: no examples, exit code 4 missing, aliases and several env vars undocu... | B | B16 |
| 76 | onboarding-25 | minor | Gatekeeper and quarantine behaviour is documented but was not tested | G | G1 |
| 77 | parity-9 | minor | Feature parity matrix, CLI 0.1.0 vs desktop 0.2.0 | A | A8 (the parity checklist; the missions card, Mission Control and speed strip are deferred: decision 6) |
| 78 | parity-13 | minor | CLI release line is not on main: ncode/A (shipped 0.1.0) is 16 commits ahead and unmerg... | A | A8 (done by decision 2; A8 only verifies the tag and the reinstall note) |
| 79 | tui-code-4 | minor | Four Settings rows are live-looking but do nothing: Lines per notch, Notices stay for, ... | D | D13 |
| 80 | tui-code-8 | minor | A scene that fails validation closes the whole session instead of keeping the last good... | D | D12 |
| 81 | tui-code-9 | minor | Mouse reporting is on by default but only the wheel does anything; clicks are inert whi... | D | D5 (Q5) |
| 82 | tui-code-10 | minor | Syntax highlighting covers 7 languages and is line-local | E | E21 |
| 83 | tui-code-11 | minor | /search is a dead-end report and says 'Nothing in this project' when matches exist else... | C | C8 (+E9) |
| 84 | tui-code-12 | minor | Scheduled Tasks library page does not say schedules never fire from the CLI | E | E22 |
| 85 | tui-code-13 | minor | text_faint and text_ghost fall well under WCAG contrast and carry real information; no ... | E | E23 |
| 86 | tui-code-14 | minor | No way to rename, delete or fork a conversation from the TUI | C | C11 (/rename, /delete, /fork) (+E3, D confirm layer) |
| 87 | tui-code-15 | minor | No force-redraw key; a corrupted screen only heals on resize | D | D11 |
| 88 | tui-code-17 | minor | Markdown for a visible message is re-parsed and re-laid-out on every dirty frame | E | E31 (+D21 cache field; with the locked before/after fixture and golden equivalence) |
| 89 | tui-code-18 | minor | Plain presenter and -p approvals cannot say 'approve for the run', 'always for this com... | B | B22 |
| 90 | tui-code-20 | minor | Settings detail page (i) still cannot scroll (known deferral S-6) | E | E24 |
| 91 | tui-code-21 | minor | New-research form shows raw depth names (low/medium/high/ultra) while Settings calls lo... | E | E25 |
| 92 | ux-live-6 | minor | The Lead's final report is drawn twice in a swarm turn | E | E10 |
| 93 | ux-live-7 | minor | /workflows shows raw JSON metadata and /agents shows raw Markdown, both broken mid-word | E | E11 (+C9) |
| 94 | ux-live-8 | minor | Help sheet: text runs into the border and the remainder wraps as one letter plus '…'; t... | E | E7 |
| 95 | ux-live-11 | minor | Settings attributes the model to 'flag --model · this launch only' when no --model was ... | C | C13 (+B13) |
| 96 | ux-live-14 | minor | /effort with no argument errors instead of showing a picker, and the current effort is ... | E | E4 (+D18; decision 4f) |
| 97 | ux-live-15 | minor | The side panel takes about 40% of a 120-column screen for a plain chat turn | E | E5 (Q8) |
| 98 | ux-live-16 | minor | A large paste fills the composer with raw lines and gives no count or summary | D | D8 (+E15; decision 4e) |
| 99 | ux-live-17 | minor | @-mention ranking puts sub-path matches ahead of the obvious file ('@mi' doesn't show m... | C | C12 |
| 100 | ux-live-18 | minor | Slash list at 80 columns cuts descriptions mid-word with no ellipsis, and descriptions ... | E | E8 |
| 101 | ux-live-19 | minor | /cost, the Quit confirmation and empty dashboards draw a full-height box around one lin... | E | E16 (+C18) |
| 102 | ux-live-20 | minor | Exit summary shows no tokens, cost or duration | B | B21 (decision 4g) |
| 103 | ux-live-21 | minor | Finished, stopped and failed runs all draw the same full grey progress bar in the run p... | E | E17 |
| 104 | ux-live-22 | minor | Task-list Markdown renders as literal '[ ]' and '[x]' | E | E18 |
| 105 | ux-live-23 | minor | The turn header says 'thinking ▮' while answer text is already streaming | E | E12 |
| 106 | ux-live-24 | minor | Resume picker shows only titles and run counts, with no age or preview | E | E20 (+C19) |

Count per lane (primary owner): A 8, B 31, C 16, D 14, E 21, F 5, G 5, deferred 6; total 106. The six
deferrals are all decision 6 (concurrent sessions, OS sandbox, MCP OAuth, Linux builds, ACP/IDE,
plugins); parity-9 keeps a decision-6 part (the missions UI).

## §6 Lane task lists

Every task lists its findings, files, the change and the acceptance test. "Test:" names the test
file you add or extend and what it asserts. Line numbers are at CLI `c0808ea` or desktop
`4c7c577a`; re-read the code before you edit (lines move after A's sync).

### Lane A: sync, schema 58, drift gate, version (alone, first)

Desktop shas: `4c7c577aa909274b009dc1bf0f216e5179acddc9` (target), `a64d6ff6747393d5f9c64e7ba003539bde255642`
(config.json protection), `93b58ea678cbbe98ae8732f9d6d2bcbbfdd54054` (clone starts at HEAD).

- **A1 Sync the domain to the desktop** (parity-4). `mise exec -- mix swarm_code.provenance.sync --ref
  4c7c577aa909274b009dc1bf0f216e5179acddc9 --upstream /Users/zaali/dev/swarm-code` (read-only git;
  the main checkout's `main` is `4c7c577a`, so no clone is needed; if its working tree is dirty, the
  task reads objects by sha and is unaffected). Resolve every `<destination>.sync-conflict`, then
  rerun with `--resolved <destination>`. The 14 patches in `provenance/patches/`: drop a patch hunk
  when the desktop now says the same (the "SwarmCode" → "ncode" model-facing strings in
  `prompts.ex`, the desktop's own `ncode` names); keep the CLI-only hunks (`repo.ex`, `storage.ex`,
  `hooks.ex`, `run_command.ex` env scrub, `spawn_agent.ex`, `openai.ex`, `engine.ex`,
  `project_context.ex`, `providers.ex`). New upstream files arrive by the `**/*.ex` mapping
  (`missions*.ex`, `llm/speed.ex`, `engine/research_context.ex`, `mcp/login_path.ex`,
  `mcp/sse_framer.ex`, `conversations/launch_pairing.ex`, `scheduled/run_dates.ex`,
  `tools/mission_start.ex`, `tools/web_fetch/raw_strip.ex`, `workflows/run_rows.ex`). Add
  `4c7c577aa909274b009dc1bf0f216e5179acddc9` to `@adaptation_pins` in `core/governance/provenance.ex:5-10`
  and to `governance/source-policy.json` the way `6dd8d82` is recorded. Add the desktop test
  `tools/polish74_o2_protected_paths_test.exs` to the test mapping's `files` list (mapping 7 of
  `sync-rules.json`, upstream `test/swarm_code/`, 24 files today; the file exists at the target). If
  it needs a desktop test-support module the CLI lacks (`DataCase` and the like), do not map it:
  port its cases into A5's CLI-local `path_test.exs` and say so in `notes/A.md`.
  Test: `mise exec -- mix swarm_code.provenance.verify` and `… provenance.sync --check` pass;
  `mise exec -- mix compile --warnings-as-errors` passes; the mapped domain tests pass
  (`mise exec -- mix test apps/swarm_code_daemon/test/swarm_code/domain`).
- **A2 Port the desktop's boot, quit and supervision changes** (parity-4). The excluded files
  `lib/swarm_code/{application,bootstrap,quit}.ex` changed since `6dd8d82` (+198/−22). Mirror them in
  the CLI-local `dmn/domain/runtime.ex` (new children in the desktop's order:
  `{Task.Supervisor, name: SwarmCode.Domain.Tools.BackgroundProcs.Supervisor}`,
  `SwarmCode.Domain.LLM.HTTP.finch_child_spec()`, `SwarmCode.Domain.LLM.Speed`,
  `SwarmCode.Domain.Engine.ResearchContext`, `{Task.Supervisor, name:
  SwarmCode.Domain.Engine.CleanupSupervisor}` before the run supervisor, and the desktop's
  ordering comment for the run tree), in `dmn/daemon/boot.ex` (the bootstrap additions except the
  Scheduler, which the CLI never starts) and in `dmn/daemon/shutdown.ex` (the quit additions,
  including waiting, bounded, for `CleanupSupervisor`). Update the "at 6dd8d82" moduledoc lines
  to the new sha. Finch is already a transitive dependency (`mix.lock` finch 0.23.0, the same as
  the desktop); add no dependency. Test: extend `apps/swarm_code_daemon/test/swarm_code/daemon/boot_test.exs`
  (or the existing shutdown test) so `Supervisor.which_children` of the domain runtime lists the
  new children and a quit waits for `CleanupSupervisor` (synchronise with monitors, no sleep).
- **A3 Schema contract for 58 migrations** (tui-code-1). Follow the AGENTS.md re-pin list:
  generate `apps/swarm_code_daemon/priv/schema/desktop-4c7c577.json` with
  `generate_manifest.exs --upstream /Users/zaali/dev/swarm-code --commit 4c7c577aa909274b009dc1bf0f216e5179acddc9
  --output <abs path> --fixtures-dir <abs path>`; add `@desktop_4c7c577` to `dmn/daemon/schema/contract.ex`
  (name `desktop-4c7c577`, `migration_count: 58`, `last_version: 20_261_018_000_001`,
  `last_filename: "20261018000001_mission_validator_models.exs"`, the generated hashes) and make it
  `@current` (rename today's `@current` to `@desktop_6dd8d82` and keep it, `@ccb1973`, `@previous`
  and `@legacy` reachable through `fetch/1`); `snapshot_versions` = today's list plus
  `20_261_018_000_001`, or whatever `generate_manifest.exs` reports; set `forward_compatible` to
  `[20_261_015_000_004, 20_261_016_000_001, 20_261_016_000_002, 20_261_017_000_004,
  20_261_018_000_001]` (the new migration only adds nullable columns: VERIFIED, desktop file lines
  7-18); point `foundation_gate.ex:24` `@manifest_source` at `desktop-4c7c577.json`; update the
  pinned counts in the daemon schema tests. Add `@spec desktop_running?(keyword()) :: boolean()`
  to `FoundationGate`, a public wrapper over the private `detect_desktop/2` path that returns true
  when the signed detector reports the desktop app running (C4 calls it).
  Test: `apps/swarm_code_daemon/test/swarm_code/daemon/schema/gate_test.exs` gains a 58-row case
  (ready, no migration needed), a 57-row case (the CLI may run `20261018000001` itself after the
  verified backup) and a 59-row case (refused with `Refusal.database_ahead/0`);
  `migration_manifest_test.exs` asserts the new `upstream_commit`; `scripts/dev/check_schema_snapshot.sh`
  passes.
- **A4 The refusal names the version to install** (tui-code-1). `dmn/daemon/schema/refusal.ex:13-21`:
  the second sentence becomes `"Install the ncode CLI that matches your ncode app (ncode
  --version shows this one: <vsn>); the database was not changed."` where `<vsn>` is
  `Application.spec(:swarm_code_daemon, :vsn)`. Test: `refusal_test.exs` (new) asserts the
  sentence contains `"0.2.0"` and still has code `:schema_incompatible`.
- **A5 The frozen live-runtime copies** (parity-5, parity-6). Port `a64d6ff6`'s
  `lib/swarm_code/tools/path.ex` change (`config.json` in the protected set with its own message;
  protected names compared case-folded on the lexical and the real relative path) by hand into
  `dmn/tools/path.ex`, plus its cases into `apps/swarm_code_daemon/test/swarm_code/tools/path_test.exs`.
  Then diff each of the 34 frozen entries against its upstream file at `4c7c577a` (the upstream
  path is in the ledger) and port only security and correctness fixes that the live runtime
  (`Daemon.Runtime.Run`, unsaved sessions) reaches; list each file and the decision (ported /
  not reached / CLI-only) in `notes/A.md`; `repin` every file you changed. Do not fold them into
  mappings in this pass. Test: `path_test.exs` asserts `.swarm_code/config.json`,
  `.SWARM_CODE/CONFIG.JSON` and a symlink to it are refused for write.
- **A6 Ultra stays "workflows" in the CLI** (parity-7, Q6). After A1 the synced
  `Tools.for_agent` adds `@mission_modules` (`mission_start`) to Ultra and the synced
  `prompts.ex` `@ultra` text is the desktop's missions procedure (desktop `prompts.ex:74-87`). The
  CLI cannot show the mission approval card yet, so record two CLI patches (re-run the sync at the
  pin to record them): in `dmn/domain/tools.ex` the `opts[:ultra]` branch is
  `@workflow_modules ++ @swarm_modules` (no `@mission_modules`); in `dmn/domain/engine/prompts.ex`
  `@ultra` is the CLI's current text (`prompts.ex:74-76` at `c0808ea`, "ULTRA MODE: for any
  substantive task … Trivial questions and one-line edits stay inline."), and the rules bullet
  (desktop `prompts.ex:191`) keeps the CLI's ending: "- A workflow is the user's call, not yours:
  author or launch one only when the user used /create-workflow or /workflow, or turned Ultra mode
  on." (CLI `prompts.ex:179` today) instead of the desktop's "…or /workflow. In Ultra mode,
  multi-feature work is a mission (mission_start), never an ad-hoc workflow." Do NOT exclude
  `priv/workflows/mission.exs`: the desktop's `Workflows.list/1` already hides the builtin mission
  (`workflows.ex:31-48`, `mission_builtin?/1`), `get/2` and the mission tests need it, and with
  `mission_start` out of the Ultra tool set nothing in the CLI starts one. Test:
  `apps/swarm_code_daemon/test/swarm_code/domain/engine/cli_ultra_test.exs` (new, CLI-only) asserts
  the Ultra tool set has `workflow_run` and no `mission_start`, the Ultra system prompt contains
  `"author and launch a workflow"` and `"or turned Ultra mode on"` and not `"mission_start"`, and
  `Workflows.list(nil)` has no builtin `mission`.
- **A7 Provenance drift gate** (parity-3, Q2). New `apps/swarm_code_core/lib/mix/tasks/swarm_code.provenance.drift.ex`:
  `mix swarm_code.provenance.drift [--ref REF] [--upstream PATH] [--strict]`. Upstream path as
  the sync task resolves it (`--upstream`, else `$SWARM_CODE_UPSTREAM`, else
  `~/dev/swarm-code`); `REF` defaults to `main`. It reads the pin from `sync-rules.json`, lists
  `git -C <up> ls-tree --name-only <ref> priv/repo/migrations/` and the pin's list the same way
  (read-only `git`, through `System.cmd` with a 30 s bound), and counts
  `git -C <up> rev-list --count <pin>..<ref> -- lib/swarm_code priv`. Output and exit:
  - new migrations at REF that the pin lacks: print `ncode CLI drift: desktop <ref> (<short sha>)
    has N migration(s) this CLI does not know:` then one filename per line, then `A desktop
    release with these would make this CLI refuse the database. Re-pin: mix
    swarm_code.provenance.sync --ref <sha>.`; exit 1;
  - only code drift: print `ncode CLI drift: <n> desktop commits since the pin touch the domain
    (no new migrations).`; exit 0, or exit 1 with `--strict`;
  - no upstream checkout: print `ncode CLI drift: no desktop checkout at <path>; skipped.`; exit 0
    (exit 1 with `--strict`).
  Wire it: `scripts/dev/build_release.sh` runs `mise exec -- mix swarm_code.provenance.drift
  --strict` before it builds (a release can never be cut on drift; the escape hatch is
  `NCODE_ALLOW_DRIFT=1`, which the script echoes); `mix.exs` precommit alias gains
  `"swarm_code.provenance.drift"` after `"swarm_code.provenance.sync --check"` (fails only on new
  migrations). Test: `apps/swarm_code_core/test/mix/tasks/swarm_code.provenance.drift_test.exs`
  builds two throwaway git repos under `tmp_dir` (pin commit, then one with an extra migration,
  one with only a lib change) and asserts the three exit/output cases and that the task never
  writes into the upstream repo (`git status --porcelain` empty afterwards).
- **A8 Version 0.2.0, parity checklist, tag** (decision 1, parity-9, parity-13). `version: "0.2.0"` in the four
  `mix.exs`. MCP and LSP `clientInfo` arrive from the sync (desktop
  `lib/swarm_code/mcp/client.ex:40` `%{"name" => "ncode", "version" => "0.2.0"}`,
  `lsp/client.ex:184`); verify the synced copies say so and record nothing as a patch. Replace the
  `"0.1.0"` literals that mean "this app's version" (`foundation_gate_test.exs:11`,
  `cross_app_lease_test.exs`, `guarded_repo_test.exs`, `repo_launcher_test.exs`, `backup/gate_test.exs`
  `application` assertion, `test/support/os_process.ex:733`,
  `ui/data_source/fake/settings.ex:657` "service") with `Application.spec(..., :vsn)` or
  `"0.2.0"`; leave `"0.1.0"` where a test means an old reader. README.md: version line, the pin,
  58 migrations. Write the parity checklist into `notes/A.md`: desktop 0.2.0 features and their CLI
  state (synced / ported this pass / deferred to the missions pass: mission card, Mission Control,
  speed strip, workflows cockpit). Verify `git tag -l v0.1.0` points at `c0808ea` (do not create
  tags). Test: `apps/swarm_code_cli/test/swarm_code_cli/release/version_test.exs` (new) asserts
  `Application.spec(:swarm_code_cli, :vsn) == ~c"0.2.0"` for all three apps.
- **A9 Verify what the sync fixed** (parity-6, ux-live-2). (1) The synced
  `polish74_o2_protected_paths_test.exs` passes against `dmn/domain/tools/path.ex`. (2) New
  `apps/swarm_code_daemon/test/swarm_code/domain/engine/cli_dirty_tree_test.exs`: a git project
  fixture with 3 uncommitted files, a swarm on `LLM.Fake` whose worker makes no edit, under both
  isolation backends (`:worktree`, `:clone`); assert the worker report ends with
  `"[No file changes.]"`, has no `"Delta patch captured"` line, and the project's 3 dirty files are
  untouched (content and `git status`). If it fails, stop and report to F (the fix belongs in the
  desktop) instead of patching.
- **A done**: commit `cli020 A: done` after `mise exec -- mix precommit` is green in the A worktree
  (this is the one full suite A runs; take a suite slot).

#### A' (after F is merged into desktop `main` = Fm)

- **A'1 Re-sync to Fm**. Branch `cli020/A2` from the newest CLI integration point (M1 if B..E are not
  merged yet). `mise exec -- mix swarm_code.provenance.sync --ref <Fm> --upstream
  /Users/zaali/dev/swarm-code`; add `<Fm>` to `@adaptation_pins` and the source policy. The schema
  contract stays `desktop-4c7c577` (F adds no migration; `drift` must report zero new
  migrations). Expected changed files: `domain/engine/policy.ex`, `engine/operation.ex`,
  `engine/run_server.ex` (3-way merged with its patch), `engine.ex` (patched: 3-way),
  `engine/rules.ex` (new), `conversations.ex`, `conversations/message.ex`, `conversations/node.ex`,
  `engine/prompts.ex` (3-way, keep A6), `attachments.ex`, `hooks.ex` (patched: 3-way, keep the CLI
  hunks), `project_config.ex`, `tools.ex` (keep A6), `tools/update_plan.ex` (new), and the mapped
  `policy_test.exs`. `quit.ex` is excluded from the sync: A'4 mirrors its `session_end` call.
- **A'2 Read-only cards offer y and d only** (ux-live-5). `dmn/domain/engine/pending_interactions.ex:92-95`:
  when the approval map carries `mode: "read_only"` (F1 stores it), `allowed_decisions` is
  `[:approve, :deny, :deny_stop]`; otherwise unchanged. Add `approval_mode: Map.get(approval, :mode)`
  to the row (C maps it into `DTO.Approval.approval_mode`, §8.2). Test: extend the daemon
  `pending_interactions` test: a read-only approval row has exactly those three decisions; an
  `auto` row still has `:approve_run` and, for a family, `:always_prefix`. Plus
  `apps/swarm_code_daemon/test/swarm_code/daemon/service/read_only_ask_test.exs` (new): a project in
  `read_only`, a chat turn on `LLM.Fake` that calls `write_file`; the backend's pending
  interactions show one approval; resolving `approve` writes the file; a second call resolved
  `deny` leaves it unwritten and the tool result says `"denied by user"`.
- **A'3 Boot prune keeps staged attachments** (bugs-4). `dmn/daemon/boot.ex:56`
  `prune_attachments:` calls `Attachments.prune_abandoned(DateTime.utc_now(), 24, keep:
  CommandLedger.staged_attachment_ids())` (F5 adds `keep:`; C2 adds
  `CommandLedger.staged_attachment_ids/0`, §8.1). Test: `boot_test.exs` case: a staged attachment
  file older than 24 h survives the boot prune.
- **A'4 `session_end` hook in the CLI quit** (competitors-10, F9). `dmn/daemon/shutdown.ex` runs
  `SwarmCode.Domain.Hooks.run(:session_end, %{reason: "quit"}, project_root)` for the session's
  project once, bounded by the hook timeout, before it stops the run tree (the desktop runs it from
  `quit.ex`, F9). Test: a shutdown test with a trusted fixture project whose `config.json` hook
  writes a marker file.
- **A' done**: `cli020 A2: done` after the focused daemon tests and `provenance.verify`,
  `provenance.sync --check`, `provenance.drift` pass.

### Lane B: headless, launcher, onboarding, config, exit summary

- **B1 stdin prompts** (bugs-2, onboarding-7). `cli/release.ex:346-357` `read_prompt/1`: read with
  `IO.read(:stdio, @max_prompt_bytes + 1)` after B2 has set the device to unicode; `:eof` →
  `"the prompt on stdin is empty."`; `{:error, _}` → `"the prompt on stdin is not UTF-8."`; a
  result over 256 KiB (byte_size) → `"the prompt on stdin is over 256 KiB."`. Piped stdin with a
  prompt: `rel/overlays/bin/ncode` exports `SWARM_STDIN_PIPED=1` when `-p` has a value other than
  `-` and stdin is a pipe or a regular file (`[ -p /dev/stdin ] || [ -f /dev/stdin ]`; never for a
  tty, `/dev/null` or a socket, so a script whose stdin is an idle inherited terminal never hangs); `read_prompt/1` then reads stdin the same bounded way and, when it is not
  empty, sends `prompt <> "\n\n<stdin>\n" <> stdin <> "\n</stdin>"`; the total is bounded by the
  same 256 KiB (`"the prompt and its piped stdin are over 256 KiB."`, exit 2). Test:
  `apps/swarm_code_cli/test/swarm_code_cli/release/read_prompt_test.exs` (new): `"héllo ✓"` on a
  StringIO-backed group leader is accepted; invalid UTF-8 gives the not-UTF-8 sentence; the
  piped case appends the `<stdin>` block.
- **B2 Locale-proof stdio** (bugs-3). First thing in `Release.main/1` for `-p` and `--plain`:
  `:ok = :io.setopts(:standard_io, encoding: :unicode)` and the same for `:standard_error`.
  Test: `release/io_encoding_test.exs` sets a latin1 group leader, runs the new
  `Release.configure_io/0`, asserts `:io.getopts(:standard_io)[:encoding] == :unicode` and that
  `Jason.decode!/1` of a `--json` summary containing `"✓"` round-trips. The finisher also runs the
  built release under `LC_ALL=C` (§9.3).
- **B3 Headless denials** (onboarding-5, competitors-4 part, decision 3). In `cli/plain/one_shot.ex`:
  (1) keep the auto-deny of every approval (`answer/2`, lines 433-470) and the
  `@max_denials 8` stop; remove the per-denial stderr line; (2) also add to `denied` every tool
  item of an owned run that fails with a result starting `"blocked by "` or `"hook blocked: "`
  (read the transcript item's tool result through the DTO, §8.2; label as in `describe/1`);
  (3) at finish, when `denied != []`, print exactly one stderr line:
  `ncode: N tool call(s) were denied (approval mode <mode>): <label>, <label>….` + the hint, where
  the hint for `read_only` is `" Allow them with: ncode config set project.approval_mode auto
  --project <DIR>, or answer them in ncode."` (check the real `config set` syntax in
  `release/config_command.ex` and use it verbatim; keep `denial_hint/1` for `auto`); at most 5
  labels, then `"and K more"`; (4) a new flag `--fail-on-denied` (launcher grammar in
  `rel/overlays/bin/ncode`, `release.ex` options, usage text) makes a run that finished `done`
  with `denied != []` exit 1 (`"exit_code": 1` in `--json`); without the flag the exit code is
  unchanged. `--plain --fail-on-denied` exits 1 when any approval was denied in the session. The
  other competitors-4 flags are deferred. Test: `apps/swarm_code_cli/test/swarm_code_cli/plain/one_shot_denied_test.exs`
  (new, Fake data source): two approvals → one stderr line naming both, JSON `denied` has two
  entries, exit 0; with `fail_on_denied: true` exit 1; a `"blocked by …"` tool failure counts.
- **B4 `--json` on failure** (bugs-10). `release/headless.ex:41-61`: for every non-zero exit after
  parsing, print to stdout `{"state":"not_started","conversation_id":null,"run_id":null,
  "text":"","error":<sentence>,"question":null,"denied":[],"exit_code":N}` beside the stderr line.
  The launcher does the same for its own usage errors (exit 2) when `--json` is on the command line
  (fixed sentences only, escaped with a `sed` that escapes `\` and `"`). Test: headless test,
  refused startup with `format: :json` prints a decodable object with `exit_code: 3`.
- **B5 Exact `--json` text** (bugs-16). `one_shot.ex:705` (`"text" => clean(text)` in the JSON
  summary) uses the raw text; the streamed text path keeps `clean/1`. Test: a reply containing `"\e[31m"`
  is escaped by Jason in `--json` and stripped in text mode.
- **B6 `--plain` outcomes and EOF** (bugs-8, bugs-9). `plain/session.ex:244-266,340-345,397-402`:
  the first refused outcome makes the exit code 1; at stdin EOF wait (deadline 10 min, the same as
  a turn) until the conversation's queue is empty and no chat run of the conversation is live
  (watch deltas; no polling loop with sleep). `release/headless.ex:184-187` sentence becomes
  `"ncode: the run was waiting for an approval and was stopped when input ended. Answer it before
  closing stdin (approve or deny), or allow it with /approval auto, then rerun."` Test:
  `plain/session_eof_test.exs` (new, Fake): a queued prompt at EOF still runs; a refused send exits 1.
- **B7 Slow stdout consumers** (bugs-20). `plain/session.ex:26-32,632-675`: a write that takes
  longer than `output_timeout` no longer kills the writer; wait up to 30 s total for that batch,
  then fail with `:output_failed`; an `{:error, :epipe}` or closed device fails at once. Test: a
  group leader that blocks 2 s then accepts: the session finishes `done`.
- **B8 `--plain` opening transcript once** (onboarding-23). Dedupe the initial snapshot against
  the replayed buffered deltas by `{item_id, revision}` in the plain presenter. Test: a plain
  golden on a saved conversation with 2 turns: each item printed once.
- **B9 SIGTERM and SIGHUP close cleanly** (bugs-5). In `Release.main/1` (TUI, `-p`, `--plain`):
  `System.trap_signal(:sigterm, :ncode_term, fn -> … end)` and the same for `:sighup`; the
  handler sends `{:shutdown_signal, sig}` to the session owner, which runs the normal close path
  (`stop_live_runs`, `Application.stop`, private dir removal) with a 10 s deadline, then
  `System.halt(143)` (SIGTERM) or `System.halt(129)` (SIGHUP). SIGINT cannot be trapped
  (VERIFIED: `os:set_signal(sigint, handle)` raises `badarg` on OTP 28.4.2) and stays under
  `+Bd`; `rel/env.sh.eex` is not changed (its hash is pinned by `locked_branch_test`). Test:
  `release/signals_test.exs` (new) calls the handler function directly and asserts the owner
  receives `{:shutdown_signal, :sigterm}` and that the close path stops a fake live run.
- **B10 Sweep stale private socket folders** (bugs-15). At start of `persisted_session.ex` and
  `headless.ex` (the `scl-p-*`, `scl-h-*` creators, lines 1273-1294 and 202-230): remove same-uid
  folders of those patterns older than 60 s whose socket refuses `connect`, using the existing
  inode and device check before `rmdir`. Test: a tmp_dir with one stale and one live folder:
  only the stale one is removed.
- **B11 A failed start leaves no empty conversation** (bugs-11). `persisted_session.ex:294-307`:
  when `prepare/1` fails after `SessionSelection.open` created the conversation in this call,
  delete that conversation (and the project row if this call created it and it has no other
  conversation); never delete one that existed before. Test: `provider_required` on a fresh
  fixture database leaves `conversations` and `projects` empty.
- **B12 Bare `ncode` with no provider opens Providers** (onboarding-2). `persisted_session.ex:309-313`:
  when `prepare/1` returns `:provider_required` and the run is the interactive TUI
  (`SWARM_RELEASE_TUI=1` and stdin/stdout are a tty), return `{:ok, session}` with the settings
  open-query `"providers"` (the mechanism `ncode settings providers` uses) and the toast
  `"Add a model provider to start: pick a preset, paste its key."`; `-p`, `--plain` and a non-tty
  keep exit 3. Test: `test_saved_session_pty.py` gains a case on a fixture database without
  providers: the first screen shows the Providers page and the process does not exit.
- **B13 Environment onboarding** (onboarding-4, onboarding-21, ux-live-11 part).
  `dmn/daemon/service/session_configuration.ex:196-229`: (1) with no usable provider in the
  database, a bare `ANTHROPIC_API_KEY` defaults the base URL to `https://api.anthropic.com` and the
  kind to Anthropic, a bare `OPENAI_API_KEY` to `https://api.openai.com/v1`; the model comes from
  `NCODE_MODEL`/`SWARM_MODEL`, else `{:error, :model_required}` (VERIFIED: the presets,
  `core/settings/registry/actions.ex:8-60` `provider_presets/0`, carry `id, name, kind, base_url,
  effort_preset, key` and no model); (2) when the base
  URL matches a preset, the new row is named after the preset's display name, otherwise after the
  host; (3) `put_override` records where the override came from, read by
  `SessionConfiguration.override_source/1 :: :flag | :first_run_env | nil` (C13 labels it).
  `persisted_session.ex:1067-1075` gains `session_failure(:endpoint_required, _)` (exit 3,
  `"NCODE_BASE_URL is missing (OpenAI-compatible URLs end in /v1)."`, `"Set NCODE_BASE_URL, or run
  'ncode settings providers'."`) and `session_failure(:model_required, _)` (exit 3, `"NCODE_MODEL is
  missing."`, `"Set NCODE_MODEL to a model of your provider, or run 'ncode settings providers'."`).
  Test: `apps/swarm_code_daemon/test/swarm_code/daemon/service/session_configuration_test.exs` cases for each.
- **B14 The env loader reads per variable** (bugs-13). `scripts/dev/load_provider_env.sh:32-34`
  (the release copy is made by `scripts/dev/build_release.sh:20`, so no second file changes): remove the early `return 0`; read the file and export
  each allowed `NAME=value` only when `[[ -z ${!NAME+x} ]]` (the shell's own value wins, per
  variable); a missing `NCODE_ENV_FILE`/`SWARM_ENV_FILE` file returns 2 and the launcher exits 2
  with the existing sentence. Test: `scripts/dev/test_launcher_environment.py` cases: exported
  `OPENAI_API_KEY` plus a file with `NCODE_MODEL` loads the model; a missing named file exits 2.
- **B15 Logs that exist** (onboarding-3). Flush the logger handlers before every `System.halt` in
  `Release.main/1` (`:logger_std_h.filesync/1` on the cli.log handler, bounded 2 s);
  `persisted_session.ex:179-186` `report/1` prints `Details: cli.log` only when the file is non-empty
  and never for `:provider_required`, `:endpoint_required`, `:model_required`, usage errors.
  Test: `report/1` unit test for both cases.
- **B16 Launcher words and help** (onboarding-10, onboarding-24). `rel/overlays/bin/ncode`: `help` →
  `--help`, `version` and `-v` → `--version`, `doctor` → `config doctor`; an unknown single word
  that is not a directory exits 2 with `"ncode: '<word>' is not a folder or a command. Did you mean
  --help? (To open a folder named <word>, use ./<word>.)"`. `--help` gains `EXAMPLES` (4 lines:
  `ncode`, `ncode -p "explain this repo" --json`, `ncode settings providers`, `ncode config
  doctor`), the short flags, `--fail-on-denied`, and exit code 4 (config). Test:
  `test_launcher_environment.py` cases for each word.
- **B17 `ncode config` while a session is open, doctor, trusted** (onboarding-12, onboarding-13,
  onboarding-20, onboarding-14 part). `release/config_command.ex`: `get`/`list` of a database
  setting while a session holds the lease exit 3 with `"A session is using the database; this value
  cannot be read now. Close it and run this again."`; `doctor` runs its non-database checks, says
  `"database checks skipped: a session is open"`, gains a hint column (`run: ncode settings
  providers`, …), treats search as a note, adds a "database newer than this CLI" check
  (`Refusal.database_ahead/0` text) and an "app is open" check, and exits 1 only for blocking
  problems; `config set project.trusted on --project DIR` for an unknown folder says `"ncode has
  not opened <DIR> yet. Open it once (ncode <DIR>), then run this again."`; `config help` says
  `keys  every setting key`. Test: `config_command_test.exs` cases for each sentence and exit code.
- **B18 Provider records and key tests** (onboarding-15, onboarding-16). `config record add
  provider --preset NAME [--base-url URL] [--kind anthropic|openai]`; presets match case- and
  space-insensitively on id or display name (`settings/providers.ex:1059-1072` `preset_attributes/1`
  matches `&1.id == id` exactly today); an unknown preset lists `presets: <ids>` generated from
  `SwarmCode.Settings.Registry.Actions.provider_presets/0` (read-only use of E's core file);
  `--kind openai` means the stored kind `"openai_compatible"`. The key test classifies 401/403 as `"the key was refused"` and a
  transport error as `"could not reach <host> (<reason>); the key was not saved. Use --no-test to
  save it anyway."` (add `--no-test` if it does not exist). Test: `providers` handler tests with a
  loopback server returning 401 and a closed port.
- **B19 `--resume` without an id** (competitors-12). `release.ex:216-217,268-269`: `--resume`/`-r` with
  no value opens the TUI with the `/resume` picker open; a value that is a unique id prefix of at
  least 6 hex characters, or an exact title, resolves; an ambiguous one exits 2 listing up to 5
  `id  title` lines. Launcher grammar updated. Test: release option tests.
- **B20 Startup line** (onboarding-18). When the TUI starts and stdout is a tty, the launcher prints
  `Starting ncode…` without a newline; `print_summary/1` starts with `"\r\e[2K"` so the line never
  stays in the scrollback. Test: launcher test asserts the bytes.
- **B21 Exit summary: last turns and spend** (competitors-5, ux-live-20; decisions 4d, 4g).
  `persisted_session.ex:700-790`: `summary/2` also reads (a) the last `N` exchanges, `N` = cli.json
  `exit_transcript` (E26, default 3, 0 = off): `SELECT role, content FROM messages WHERE
  conversation_id = ?1 AND superseded_at IS NULL AND role IN ('user','assistant','shell') AND content
  != '' ORDER BY position DESC LIMIT ?2` with `?2 = 2*N`, each content clipped to 4,000 bytes on a
  UTF-8 boundary, 24 KiB in total; (b) `SELECT COALESCE(SUM(tokens_in),0), COALESCE(SUM(tokens_out),0),
  SUM(cost_usd), COUNT(cost_usd), COUNT(*) FROM runs WHERE conversation_id = ?1 AND inserted_at >= ?2`.
  `print_summary/1` prints the exchanges first (oldest first; a user line starts `› `, an assistant
  reply is printed as is, a shell row starts `$ `; every line through the same control-character
  filter as `one_shot.ex` `clean/1`; one blank line between exchanges), then the existing block
  with a new line after `Last prompt`: `Spent         12.4k tokens · $0.03 · 6m 12s` (tokens =
  in + out, `k`/`M` with one decimal; `$` part only when `COUNT(cost_usd) == COUNT(*)`, formatted
  `$%.2f`, `<$0.01` below one cent; duration from `started_at`, `Xs`, `Xm Ys` or `Xh YYm`; the line
  is omitted when no run started). Only the TUI prints this, never `-p` or `--plain`. Test:
  `release/exit_summary_test.exs` (new) on a fixture database: two exchanges printed oldest
  first, a superseded message absent, the spend line with and without a cost.
- **B22 Plain approval verbs** (tui-code-18). `plain/command.ex:68-85`: add `approve-run`,
  `always-prefix` and `deny-stop` mapped to `{:resolve_approval, …, :approve_run | :always_prefix |
  :deny_stop}`, refused with the existing words when the row does not offer the decision (a
  read-only row offers only `approve`, `deny`, `deny-stop`). Test: `plain/command_test.exs`.
- **B23 The other headless flags** (competitors-4). `release.ex` options, launcher grammar and usage
  text: (1) `--output-format text|json|stream-json` (`json` = today's `--json`, kept as an alias;
  `stream-json` = the `--plain --ndjson` record stream of `plain/presenter.ex` for the one-shot run,
  one JSON object per line, ending with the `--json` summary object as `{"type":"summary",…}`);
  (2) `--max-turns N` (1..200): the one-shot watches the owned run's lead agent `turn`
  (`DTO.AgentSummary`) and, when it passes N, sends `{:run_control, :stop, run_id}` and finishes
  `stopped` with `"ncode: stopped after N turns."`, exit 1; (3) `--max-budget-usd X` (> 0): the same
  on the run's `cost_usd` (`DTO.RunSummary`); a run whose cost is unknown (nil) is never stopped by
  it and stderr says once `"ncode: the provider reports no cost; --max-budget-usd is not enforced."`;
  (4) `--approval read-only|auto|full`: exported as `SWARM_HEADLESS_APPROVAL` by the launcher, passed
  by `one_shot.ex` into the dispatch so the run starts with F8's `approval_mode:` option (in memory,
  this run only; the project row never changes). An untrusted project refuses `auto`/`full` with
  the sentence `/approval` uses there (exit 3). Until A'1 lands F8, `--approval` exits 2 with
  `"ncode: --approval needs the 0.2.0 engine."` behind one private function the finisher removes.
  Test: `one_shot_flags_test.exs` (new, Fake): stream-json lines decode and end with the summary;
  `--max-turns 1` stops a 3-turn fake run; `--max-budget-usd 0.01` stops a run at cost 0.02.
- **B done**: `cli020 B: done`; focused tests of every touched file green; plain golden
  regenerated if output changed (§9.2).

### Lane C: daemon service and the wire

All new requests, intents, DTO fields and `Fake` answers are in §8; C implements both halves and
the `Fake` (`ui/data_source/fake/**`) so D and E can test against it.

- **C1 The queue survives and can be managed** (bugs-7, bugs-17). `dmn/daemon/service/persisted_backend.ex`:
  `switch_conversation/2` (1415-1425) calls `watch_queue/1` for the new conversation and drains at
  once when no chat run is registered; `init/1` (`persisted_backend.ex:70`; the queue state is at
  155-158) does the same for the opening conversation. `/queue` is already a client-local command
  (`Keymap.local_command/1` → `Reducer.slash_local(:queue)`, `reducer.ex:2917-2941`: `/queue text`
  queues the text). D20 keeps that and adds `/queue` (bare: the list), `/queue clear` and
  `/queue drop N`; the last two send the new intent `{:queue_edit, conversation_id,
  queue_revision, :clear | {:drop, n}}` (§8.2). The backend applies it in one IMMEDIATE transaction
  (the `Conversations.pop_queued/1` pattern, `dmn/domain/conversations.ex:956`): read `queued`,
  compare `queue_revision/1` (first 16 hex of `sha256` over the `\x1f`-joined full texts, never the
  2 KB client copies) with the one sent, write the new list (`Conversations.set_queued/2`,
  `conversations.ex:935`, VERIFIED to replace the list and broadcast `{:conversation_updated, …}`),
  else refuse `:stale` ("The queue changed · look again."). The workspace DTO carries
  `queue_revision` beside the existing `queued_texts` (`dto/workspace_snapshot.ex:56`). A stop the
  user asked for (the backend's `control(:run_control, %{"action" => "stop"}, …)`, ≈1918) sets `queue_paused: true` instead of draining; the workspace DTO
  carries `queued_count` and `queue_paused` (§8.2); the intent `{:queue_resume, conversation_id}`
  clears the pause and drains; a turn that ends by itself (done, failed) still drains. Test:
  `apps/swarm_code_daemon/test/swarm_code/daemon/service/queue_test.exs` (new, `LLM.Fake`): a
  queued prompt drains after a switch away and back, and after a backend restart; a user stop
  pauses; `queue_resume` drains; `drop 1` and `clear` work and a stale `queue_revision` is refused.
- **C2 A pruned staged image no longer poisons sends** (bugs-4). `service/command_ledger.ex:51-60`
  `staged_attachments/2` drops and DELETEs rows whose `Attachments.path/1` is `:error`;
  `persisted_backend.ex:2004-2015` `attachment_payloads` skips a missing *staged* id (the send goes
  out, with the notice `"A staged image was removed before sending."`) instead of `:not_allowed`;
  add `CommandLedger.staged_attachment_ids/0` (A'3 passes it to the boot prune). Test:
  `command_ledger_test.exs`: a staged row whose file is gone is removed; a send with it succeeds.
- **C3 Ledger prune** (bugs-19). `CommandLedger.prune(now)` deletes `cli_command_ledger` rows with
  `updated_at` older than 7 days and `processing` rows of earlier epochs, at most 5,000 rows per
  call, called once from `PersistedBackend.init/1` in owned work (the backend's job pool, not the
  init callback). Test: 3 old rows and 1 new row → the new row remains.
- **C4 Desktop started during a session** (bugs-6). New `dmn/daemon/service/desktop_watch.ex`: a
  GenServer C adds to the persisted service's supervision tree (`dmn/daemon/service.ex`; the live backend never starts it), polling
  `FoundationGate.desktop_running?/1` (A3) every 10 s from an owned `Task.Supervisor.async_nolink`
  task (one at a time; a slow probe is skipped, never queued); on a change it broadcasts the shell
  delta `{:desktop_running, true | false}` (§8.2). The client shows the persistent warning
  (E16): `"The ncode app is open on the same database. Quit it, or stop your runs here and quit
  (Ctrl-C twice)."` Stopped with the session. Test: `desktop_watch_test.exs` with an injected
  detector function: true after false emits one delta; a probe that hangs past 10 s does not
  block the next tick.
- **C5 Retry status reaches the run** (ux-live-3). The synced operation already writes
  `status: "retrying", detail: "retrying 2/5 · <reason>"` on the llm op node
  (`domain/engine/operation.ex:170-174`). `persisted_projection.ex`/`panel_facts.ex`: a run whose
  live llm op is `retrying` has `RunSummary.state == :retrying` and `retry_detail ==` the node
  detail; it clears when the op leaves `retrying`. Test: projection test with a retrying node.
- **C6 Retry a failed turn** (ux-live-4). Implement the existing `{:retry_run, run_id, revision}`
  intent (client `ui/intent.ex:70`, `request.ex:430`) in the backend, as the desktop does
  (`workspace_live.ex:8153-8178`): for a `failed` or `stopped` run of this conversation whose
  revision matches, re-send the text of the user message that launched it (`messages.run_id ==
  run.id`, role `user`) through `dispatch_send` (same mode markers, so `/swarm …` stays a swarm);
  a swarm run without a message restarts with `Engine.start_swarm(conv, run.prompt)`; any other run
  without a message starts a chat turn with `run.prompt` (the desktop's last `true ->` branch,
  `start_turn(socket, conv, run.prompt)`); a stale revision is refused `:stale`. The wire op is
  `run.retry`: add it to `core/protocol/service_request.ex` decode/encode, the handshake
  capability map (`service_handshake.ex:29` style), the client's `daemon.ex`
  `request_capability/1` and `codec.ex` `request_body/1` (the switcher already offers
  `{:retry_run, …}` as "Retry failed run", `switcher.ex:385,573`). Test: `retry_run_test.exs`: a failed chat run on `LLM.Fake`
  retries into a new run with the same prompt.
- **C7 `/consensus <task>` is one-shot** (ux-live-9, Q7). `service/command_dispatcher.ex:264-274`:
  replace `persist_mode(conv, :consensus)` with an in-memory overlay that sets exactly what
  `mode_fields(:consensus)` (`command_dispatcher.ex:834-840`) would persist:
  `Engine.start_chat_turn(%{SessionConfiguration.overlay(conv) | mode: "build", consensus: true,
  ultra: false, authoring_workflow: false}, cmd.task, …)` (the `/plan <task>` clause at 251-262
  already overlays `mode: "plan"` this way) (the engine reads `conversation.consensus` from the
  struct it is given: desktop `engine.ex:97`, VERIFIED); bare `/consensus` stays sticky
  (`:set_mode`). `repin` the file. Test: dispatcher test: after `/consensus fix x` the persisted
  conversation's `consensus` is unchanged and the started run is judged (consensus config
  present on the run).
- **C8 `/search` results in this project, as rows** (tui-code-11). `command_dispatcher.ex:555-585`: pass
  the project id into the query so the limit applies after the project filter (SQL), and return
  `{:select, %{subject: :search, options: [%{conversation_id, title, snippet, at}]}}` (≤ 50) so
  E9 draws a picker whose Enter is `{:resume, id}`. Test: dispatcher test with 30 hits in another
  project and 2 here: both of ours are returned.
- **C9 Structured `/agents` and `/workflows`** (ux-live-7 data). `/agents`
  (`command_dispatcher.ex:598-615`, the `"- **name** (source)"` Markdown string at 608) returns rows
  `%{name, source, model, description}` instead of a report string. `/workflows` is `:open_workflows`
  (a navigation, 348-349); the raw JSON comes from the library rows of
  `dmn/domain/feature_catalog.ex` `query_rows(:workflows, …)` (588-600), whose detail is
  `definition(w)`: make that detail `%{description, args: [%{name, required?, default}]}` from
  `w.meta`, never the program source or the raw `meta` JSON. Test: dispatcher and feature-catalog
  tests assert no `"defmodule"`, `"meta"` or `"**"` in what they return.
- **C10 Background commands end visibly** (ux-live-12 data). The transcript item of a backgrounded
  `run_command` gets a terminal state from the synced `Tools.BackgroundProcs` book: `exit N`,
  `killed at quit`, or `still running`; at backend init an item whose process is gone and whose
  exit was never recorded becomes `"ended (exit not recorded)"`. DTO field `background_state`
  (§8.2). Test: projection test for each state.
- **C11 `/rename`, `/delete`, `/fork`** (tui-code-14). Dispatcher actions (E3 parses them):
  `:rename_conversation` → the synced `Conversations.rename/2` (`dmn/domain/conversations.ex:389`;
  title trimmed, 1..200 chars, else `:invalid_argument`); `:delete_conversation` (`/delete`, this
  conversation only) → refused `:busy` while any run of it is live, else
  `Conversations.delete/1` (488) and the answer `%{type: :conversation, conversation_id: <newest
  other conversation of the project, or a new one>}` so the backend switches (the existing
  `:conversation` result, `persisted_backend.ex` ≈1263); the TUI asks first: D makes bare `/delete`
  a local command (D20) that opens the existing `{:confirm_intent, intent}` layer
  (`keymap.ex:217-221`) for the `{:dispatch, :send, "/delete", :main, []}` intent; the copy is `"Delete this conversation and its runs? Files are not
  touched. Enter delete · Esc keep"`; `:fork_conversation` (`/fork`) → `Conversations.fork(conv,
  newest_position + 1)` (808) and switch to the copy. Test: dispatcher tests for each, including the
  live-run refusal.
- **C12 `@` ranking** (ux-live-17). `dmn/domain/feature_catalog.ex:512-546` `file_matches/3`:
  score basename prefix > basename substring > path-segment prefix > `FuzzyMatch.score/2`
  subsequence, ties by shorter path, then take the limit. Test: `@mi` in a tree with
  `mix.exs` and `priv/repo/migrations/…` ranks `mix.exs` first.
- **C13 Honest setting sources and "changed" counts** (ux-live-11, onboarding-19).
  `service/settings/values.ex:232-240`: the model override's source is
  `SessionConfiguration.override_source/1` (B13): `:flag` → `"flag --model · this launch only"`,
  `:first_run_env` → `"env NCODE_MODEL · first run"`, nil → no override row. "Modified" compares
  with the effective default (equal-to-default and unset are unmodified) and excludes
  conversation-scoped keys from the global count and from `config list --modified`. Test: a fresh
  fixture database reports 0 changed; an env first run does not show the flag label.
- **C14 Clipboard image inbox** (competitors-6 backend, decision 4i). New
  `dmn/daemon/service/clipboard_inbox.ex`. Directory `Path.join(SwarmCode.Domain.Paths.config_dir(),
  "cli-inbox")` (`dmn/domain/paths.ex:18`; tests set `config :swarm_code_daemon,
  :domain_config_dir` to a `tmp_dir`, never the real data folder), created 0700, files 0600. Request
  `attachment.slot` → `%{"token" => 32 lowercase hex from :crypto.strong_rand_bytes(16),
  "path" => <inbox>/<token>.png}`; at most 4 open slots per session (`capacity_exceeded`), a slot
  expires after 60 s. Command `attachment.attach_slot` `%{"token" => t}`: the token must match
  `~r/\A[0-9a-f]{32}\z/` and be an open slot of this session (the path is never taken from the
  client); `File.lstat` must be a regular file (no symlink), size 1..`Attachments.max_bytes/0`
  (6,000,000), first 8 bytes the PNG signature `<<137, 80, 78, 71, 13, 10, 26, 10>>`; then
  `Attachments.store("clipboard-" <> HHMMSS <> ".png", "image/png", Base.encode64(bin))`, stage it
  exactly like `/attach` (the `:attachment_staged` branch, `persisted_backend.ex:1236-1245`, which
  calls `CommandLedger.stage_attachment/3`), delete the slot file on every path (success, refusal,
  crash: an `after`), answer `%{type: :attachment_staged, attachment: %{"id", "name", "mime",
  "bytes"}}` (`bytes` is new; E15's chip shows it). Refusals: `:invalid_argument` (bad token, not a
  PNG), `:too_large` (`"The image is over 6 MB."`), `:limit` (`"At most 4 images per message."`).
  At backend init remove inbox files older than 1 h. `LiveBackend` answers `:not_supported`.
  Test: `clipboard_inbox_test.exs`: a valid PNG is staged and the file removed; a symlink, a
  JPEG, a foreign token and a 6 MB+1 file are refused and removed.
- **C15 `!` shell escape backend** (competitors-9 backend, decision 4c). New
  `dmn/daemon/service/shell_escape.ex`. Command `shell.run` `%{"command" => text}` (1..4,096
  bytes, valid UTF-8, no NUL): runs in an owned task of the backend's job supervisor, through the
  synced `SwarmCode.Domain.Tools.RunCommand.run(args, ctx, progress)` (`domain/tools/run_command.ex:180`)
  with args `%{"command" => text, "yield_ms" => 120_000}` (there is no `"timeout"` argument: the
  timeout is `max(timeout_ms, settings.command_timeout_ms)`, default 120 s, `run_command.ex:166-174`;
  without a `yield_ms` at least as long, a command still running after the default 10 s yields to
  the background book keyed by `run_id`, which is nil here), ctx `%{project_root: root,
  project_id: id, settings: Settings.get(), run_id: nil}` and `progress = fn _pct, _detail -> :ok
  end`; it already scrubs secrets, applies `SWARM_USER_UMASK` and kill-tree timeouts, and it traps
  exits so that an exit signal kills the OS process (`run_command.ex:262-263`). No approval card and no Policy: the user typed it. One per conversation
  (a second → refusal `:busy`, `"A shell command is still running · Esc stops it."`);
  `shell.stop` kills it: `Task.Supervisor.terminate_child/2` on the task (the trapped exit kills the
  process tree; the C15 test proves it with `sleep 30` and an `OSProcess.alive?/1` check). While it runs the transcript has a transient item `kind:
  :shell, state: :running`; at the end the backend persists
  `Conversations.create_message(%{conversation_id, role: "shell", content: "$ " <> text <> "\n" <>
  output <> "\n[exit " <> code <> "]"})` (role from F3; output as RunCommand bounded it) and the
  item becomes the message. The model sees it on the next turn (F3's history mapping).
  Test: `shell_escape_test.exs` (`echo hi` → message `"$ echo hi\nhi\n[exit 0]"`; a `sleep 30`
  stopped by `shell.stop` ends `[exit stopped]`; concurrency refusal; terminate kills the child).
- **C16 Conversation rewind backend** (competitors-8, decision 4h). New `dmn/daemon/service/rewind.ex`
  and the dispatcher's `:select_rewind` (`command_dispatcher.ex:331-345`):
  - Query `rewind.turns` (and `/rewind` with no argument) → newest first, ≤ 200, every
    non-superseded `user` message of the conversation that is not a steer (a steer has `run_id ==
    reply_to_run_id`, desktop `conversations.ex:942-948`): `%{message_id, position, turn, prompt
    (first line, 120 chars), at, run_id, files}`. `turn` uses `Checkpoints.for_conversation/2`'s
    numbering (every run of the conversation, superseded ones included, sorted by `started_at`,
    1-based, `checkpoints.ex:452-456`), nil for a message that launched no run; `files` is
    `length(files)` of that run's entry in `for_conversation/1` (0 when none). One
    `for_conversation/1` call per query, not per row.
  - Command `rewind.apply` `%{"message_id", "scope" => "both" | "conversation" | "files"}`, in
    this order: (1) stop every live run of the conversation launched at or after the message
    (`Engine.running_runs/1`, `Engine.stop_run/1`), waiting for the stops (bounded 10 s);
    (2) scope `both`/`conversation`: `Conversations.supersede_from(conv, message)` (F2; supersedes
    the message and every later message and their runs, clears their goals); (3) scope
    `both`/`files`: `Checkpoints.restore_run_report(conv.id, run_id)` for the message's run, which
    takes every file touched in that turn or a later one back to its earliest snapshot (earliest per
    path wins, `checkpoints.ex:593-640`) and writes the "Rewound N file(s) to before turn T."
    `swarm` message (VERIFIED order: `Conversations.list_runs/1` keeps superseded runs, so the turn
    is still found after step 2, and the message is created after the supersede, so it stays
    visible); when the message's run has no checkpoints, restore
    the first later run that has one, or none; (4) answer `%{type: :rewound, text:
    message.content, attachments: message.attachments, restored: n, skipped: [...]}`; for scope
    `both`/`conversation` the attachments still on disk are re-staged (C2's staging) so they ride
    with the resend; for `files` `text` is nil (the conversation is unchanged, nothing goes back
    into the composer). Errors: `:busy` while a
    compaction runs, `:database_busy` → `"The database is busy — rewind again."`, a restore error
    → its sentence (the conversation part, if done, stays done; the answer says so).
  - `/undo` = `rewind.apply` on the newest non-superseded user message with scope `both`.
  - Test: `rewind_test.exs` (`LLM.Fake`, fixture project): three turns, the second wrote a file;
    rewind to turn 2 with `both` → turns 2 and 3 superseded, the file restored, the answer text is
    turn 2's prompt; `conversation` leaves the file; `files` leaves the messages; a live run is
    stopped first.
- **C17 Worker and Validator models** (tui-code-7 data). `service/settings/models.ex` and
  `values.ex`: read and write `settings.default_validator_provider_id/model/effort` and
  `conversations.validator_*` (columns from migration 58) for the registry keys E1 adds; the
  workspace DTO carries `effort`, `swarm_effort`, `validator_model`, and the levels the dispatcher
  accepts for this conversation, `effort_levels` and `swarm_effort_levels` (make
  `CommandDispatcher.efforts/2`, used by `parser_opts/2` at `command_dispatcher.ex:103-111`, public
  and call it from the projection) (§8.2). Bare `/effort` and `/swarm_effort` sent by `--plain` or
  a palette reach the dispatcher as `:show_effort` (E3): a report `"Effort: medium (chat model).
  Levels: low, medium, high, max. /effort <level> sets it."`. Test: values test round-trips each
  key; projection test for the levels.
- **C18 `/cost` by model** (ux-live-19 data). `:show_cost` returns per-model rows `%{model,
  tokens_in, tokens_out, cost_usd | nil}` plus the total, from the grouped query the dispatcher
  already runs (`command_dispatcher.ex:519-553`, `group_by: r.model`), returned as
  `%{type: :report, title, text, rows}` so `--plain` keeps the text and E16 draws the rows. Test:
  dispatcher test with two models.
- **C19 Resume rows** (ux-live-24 data). The conversations list DTO gains `updated_at` and
  `last_prompt` (first line, 80 chars, from the newest non-superseded user message, one SQL query
  for the page). Test: projection test.
- **C20 Prompt history query** (competitors-19 data). Query `history.search %{"query" => q}` (q
  0..200 bytes): ≤ 50 distinct texts of non-superseded `user` messages of this project's
  conversations, newest first, one SQL query (join `conversations` on `project_id`); q ≥ 3 chars
  uses the synced `messages_fts` index (`MATCH` with a quoted prefix term), shorter q a `LIKE`
  prefix on the first 200 bytes; each text bounded to 2 KB with a `detail_ref` for the rest. Fake
  answer for D19. Test: 3 conversations in 2 projects, only this project's prompts return.
- **C21 (merged into C11).**
- **C22 Git facts for the status line** (competitors-20 data). In owned work (the backend's job
  pool, at most one at a time, after each run finishes and at most every 10 s on file-change
  deltas): `SwarmCode.Domain.Git.current_branch/1` (`domain/git.ex:210`) and the count of changed
  paths from `Git.status/1` (236), 2 s bound. Workspace DTO
  `git_branch :: String.t() | nil` (≤ 80 bytes), `git_dirty :: non_neg_integer() | nil`; nil
  outside a git repo or on timeout. Test: a git fixture with 2 changed files → `git_dirty == 2`.
- **C23 Plan, hooks and permission facts** (competitors-14, competitors-10, competitors-11 data).
  (1) `RunSummary.plan :: [%{text, status}] | nil` (≤ 30 items, 200 bytes each) from the newest
  `update_plan` op node of the run's lead agent (its `input` JSON, F11); (2)
  `service/settings/project_config.ex:20-22`: `@events` (line 20) gains F9's events (`stop`,
  `notification`, `user_prompt_submit`, `pre_compact`, `session_end`) and `@top_level` (21) gains
  `"permissions"` (F10's
  shape validated: three lists of ≤ 100 strings ≤ 300 bytes); (3) a settings query
  `project_config.summary` → `%{hooks: [%{event, command (first 120 bytes)}], permissions: %{allow,
  ask, deny}}` for E30. Test: projection test for the plan; project_config tests for the new keys.
- **C done**: `cli020 C: done`; `test_live_session_pty.py` green.

### Lane D: input, keymap, reducer, terminal port, runtime, effects

Every new binding goes into `ui/keymap/bindings.ex` with `id`, `keys`, `action`, `contexts`,
`group`, `label`, `help`; then `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap
--write)` regenerates `docs/keybindings.md` and `--check` must pass. Never Ctrl-K; nothing
essential Alt-only. New port wire tags are documented in `docs/implementation/terminal-port-wire-v1.md`.

- **D1 macOS word movement** (tui-code-3). `ui/keymap.ex:444-456` `movement/2`: add `{:left,
  [:control]} -> :word_left`, `{:right, [:control]} -> :word_right`. `movement/2` is only reached
  for arrow/home/end codes (`editor_fallthrough/3`, 413-425, `code in [:left, …]`), so the letters
  go into `editor_fallthrough/3` itself, before the `is_binary(code) and mods == []` insert
  clause: `code == "b" and mods == [:alt] -> :word_left`, `code == "f" and mods == [:alt] ->
  :word_right`, `code == "d" and mods == [:alt] -> :delete_word_forward` (check first how the
  port reports `ESC b`: as `{:key, "b", [:alt]}` or as a text fragment; route whichever it is).
  Bindings rows (group `:edit`, the group that exists, help `"Word left/right (Option-←/→,
  Ctrl-←/→, Alt-b/f)"`). Test: keymap tests with `focus: "main"` unset (composer) for each key.
- **D2 Kitty keyboard protocol when offered** (tui-code-2). `native/terminal_port/src/tty.rs:116-141`:
  after entering the alternate screen send `CSI ? u` followed by the primary device attributes
  query `CSI c` (the kitty protocol's documented detection, VERIFIED at
  sw.kovidgoyal.net/kitty/keyboard-protocol: a DA1 answer without a `CSI ? <flags> u` answer means
  no support); the input decoder consumes both replies (never as keys); if `CSI ? <flags> u` came
  first, send `CSI > 1 u` (disambiguate) and report it; with no reply after 500 ms, treat it as
  unavailable (never block the writer). Ready's flags byte is checked against `FLAGS`
  (`protocol.rs:15,375`): add `READY_ENHANCED_KEYS: u8 = 128`, accepted by `ready/4` only (Init
  still rejects it), documented in the wire doc. With disambiguate on, the decoder must map
  `CSI 27 u` to Esc at once (no 40 ms wait), `CSI <codepoint>;<mods> u` for letters to the same
  events the legacy bytes give (Ctrl-C, Ctrl-letters, Alt-letters), and `CSI 13;2 u` to
  Shift-Enter. Restoration (`restore()`, `guard.rs`) and Suspend send `CSI < u` first when it was
  pushed; Resume pushes it again. `ui/capabilities.ex:34` takes
  the flag; with it, `Shift-Enter` (`CSI 13;2 u`) inserts a newline in the composer; Ctrl-J and
  Ctrl-O stay. Test: `cargo test` decode of `CSI ? 1 u`, `CSI 13;2 u`, `CSI 27 u`, `CSI 99;5 u`
  (Ctrl-C) and a DA1 reply; PTY suite cases: a terminal that never answers still starts (no hang),
  and Ctrl-C twice still quits with enhanced keys on. The finisher replaces AGENTS.md's "Enhanced
  keys (kitty protocol) are always unavailable".
- **D3 Needs-you signal, notifications, window title** (tui-code-5, competitors-20 part; decision 4a).
  - Reducer: emit `{:bell, :needs_you}` when a pending interaction (approval or question) of this
    conversation first appears, and `{:bell, :turn_done}` when a run this session started reaches
    done, failed or stopped, only while `state.terminal_focus == :lost`
    (`reducer.ex:795-797`; the default is `:gained`, `state.ex:141`, so a terminal without focus
    reports never bells). At most one bell per 2 s (`state.last_bell_at`, the clock from the owner);
    a burst of approvals bells once. Extend `ui/effect.ex:17` and its `validate/1` clause (83) to
    `{:bell, :needs_you | :turn_done}`.
    Emit `{:terminal_title, SafeText.t()}` whenever the title text changes: `ncode · <project>`
    idle, `ncode · <project> · working` while a run of this conversation is live, `ncode ·
    <project> · needs you` while an interaction is pending, `ncode · <project> · done` after an
    unfocused finish until focus returns; `<project>` is the root's basename through `SafeText`,
    at most 40 cells.
  - Runtime and port: new BEAM→native tag 9 `Notify`: `generation, token, kind:u8 (0 bell,
    1 notification, 2 title), length:u16, UTF-8 bytes (0..512)`; the port rejects any C0 or C1
    control byte in the text (Error reason 1). The port writes, between frames: kind 0 `\x07`;
    kind 1 `\x1b]9;<text>\x07`; kind 2 `\x1b]2;<text>\x07`. A kind-1 text must not start with a
    digit (ConEmu's `OSC 9;<n>` progress sequences share the prefix; ghostty documents both) — the
    texts below start with `ncode`. At init the port saves the title with
    `\x1b[22;2t` and restoration restores it with `\x1b[23;2t` (only when a title was set).
  - Settings (E26 adds the keys): `terminal.notify` = `auto` (default) | `bell` | `osc9` | `os` |
    `off`; `auto` sends kind 1 when `TERM_PROGRAM` is `iTerm.app`, `ghostty` or `WezTerm`, else
    kind 0; `os` runs `/usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of
    argv) with title "ncode"' -e 'end run' <text>` in an owned task (5 s bound), macOS only.
    `terminal.title` = `on` (default) | `off`. Texts: needs you → `"ncode: <project> needs you
    (approval)"` or `"(question)"`; turn done → `"ncode: <project> finished"` / `"failed"` /
    `"stopped"`.
  - Test: reducer tests (focus lost + new approval → one `{:bell, :needs_you}`; focused → none;
    title sequence over a run); `cargo test` for the tag-9 decode, the rejection of `\x1b` in the
    text and the exact bytes; `test_terminal_port_pty.py` asserts `\x1b]2;` appears and the title
    is restored at exit.
- **D4 Copy that really copies** (tui-code-6). `ui/session_runtime.ex:977-996` and
  `renderer/ratatui_port/owner.ex:30-42`: on macOS with `SSH_CONNECTION` unset, copy through an
  owned Port on `/usr/bin/pbcopy` (write the text, close, wait `exit_status` ≤ 5 s; text ≤ 1 MiB);
  exit 0 → `"Copied N lines."`; otherwise, and over SSH, OSC 52 (wrapped in the tmux DCS
  passthrough when `TMUX` is set) with `"Sent N lines to the terminal clipboard; if nothing
  arrived, your terminal does not allow OSC 52."`; over 64 KiB on the OSC path → `"Not copied:
  the terminal clipboard takes at most 64 KiB."`. Replace `"This terminal cannot take a copy from
  SwarmCode."` with `"This terminal cannot take a copy from ncode."`. Test: runtime test with an
  injected copier: pbcopy success and failure wording.
- **D5 Mouse off by default, alternate scroll** (tui-code-9, Q5). Defaults come from E26
  (`terminal.mouse` default false). `tty.rs`: when `FLAG_MOUSE` is not set and the alternate
  screen is on, write `\x1b[?1007h` at activation and in `mouse(false)`; `mouse(true)` writes
  `\x1b[?1007l` before `\x1b[?1000h\x1b[?1006h`; `restore()` writes `\x1b[?1007l`. `input.rs`:
  when mouse reports are off, one input read that consists only of ≥ 2 identical `CSI A` / `CSI
  B` (or `SS3 A` / `SS3 B`) sequences is the wheel, decoded as a new input kind 7 `Scroll:
  up:u8, count:u8` (count capped at 32); a single arrow stays a key. Elixir decodes kind 7 to a
  new input `{:scroll, :up | :down, 1..32}` (`ui/input.ex` type and `validate/1`; the existing
  `{:mouse, kind, button, column, row, modifiers}` shape, `input.ex:102,180`, needs a position, so
  it is not reused); `keymap.ex` routes it beside the wheel clause (`route/3` at 228-229, `wheel/4`
  at 614-630): the transcript pane (or the open pager/overlay that takes the wheel today) scrolls
  `count × wheel_lines` (D13). An arrow burst while the composer has a multi-line draft still
  scrolls the transcript (the burst rule is the port's; a held arrow key repeats far slower than
 one read; GUESSED, X4). `/mouse on|off` and
  `SWARM_MOUSE` keep working; help text: `"Wheel scrolls; select text with the mouse. /mouse on
  sends wheel reports instead (Shift-drag selects)."`. Test: `cargo test` burst decoding (3 ×
  `CSI A` in one read → one Scroll up 3; one `CSI A` → a key); PTY suite: activation bytes contain
  `?1007h` and not `?1000h` by default.
- **D6 Shift-Tab cycles the modes** (competitors-18, decision 4b). New binding
  `:cycle_permission_mode`, keys `[{:tab, [:shift]}, {:back_tab, []}]` (the port sends `CSI Z` as
  `BackTab`, `input.rs:598`), contexts `[:composer]` (the existing Shift-Tab rows,
  `bindings.ex:277-286` and `490-499`, cover `:overlay` and `main/inspector/picker/field/dialog`, never
  `:composer`), group `:session`, action `{:cycle_permission_mode}`, label `"Mode"`, help `"Cycle Ask (read-only) → Auto → Plan"`.
  Reducer: from the workspace snapshot (`approval_mode`, `mode`): `read_only` + not plan → send
  the command `/approval auto`; `auto` + not plan → `/plan` (toggle on); plan on → `/plan`
  (toggle off) then `/approval read-only`; `full_access` + not plan → `/plan` (never back to full;
  full is only `/approval full`). Each step shows a notice: `"Ask · writes and commands ask first ·
  Shift-Tab: Auto"`, `"Auto · edits and safe commands run · Shift-Tab: Plan"`, `"Plan · read-only
  tools, a plan first · Shift-Tab: Ask"` (each followed by `" (this project)"` for the two approval
  steps, §7.2). The commands go out through the same path the composer's `/approval` and `/plan`
  take (`Reducer.slash_local(:approval)`, `reducer.ex:2967`, and the dispatch of `/plan`); while a
  previous step's answer is outstanding a second Shift-Tab is ignored. A refusal (an untrusted project refuses `auto`) shows its
  own text (`/trust` first). Test: reducer test for the four transitions and the emitted commands.
- **D7 `!` in the composer** (competitors-9 client, decision 4c). `ui/composer.ex`
  `enter_action/1` returns `:shell` when the draft's first character is `!` (no leading space)
  and the rest is not blank; Enter then sends the intent `{:shell_run, conversation_id, text}`
  (C15) with the `!` removed and clears the draft into history; `!` alone shows `"Type a command
  after !"`. Ctrl-S still sends the draft as a plain message (so `!` can be sent to the model).
  Esc while a shell command runs sends `{:shell_stop, conversation_id}` before it stops a turn.
  The composer reports `shell?: true` so E draws the `$` chip. Test: composer and reducer tests
  (Enter on `!ls` emits the intent; on `! ` shows the notice; Ctrl-S sends plain).
- **D8 Large pastes collapse to a chip** (ux-live-16, decision 4e). `ui/draft.ex`: a bracketed
  paste of more than `paste_collapse_lines` lines (E26, default 8; 0 = never) or more than
  4,096 bytes inserts the placeholder `[Pasted text #N · L lines]` and stores the text in the
  draft's `pastes: %{N => text}` (N from 1 per draft). On send (and on Ctrl-X edit, which
  expands for the editor and collapses nothing back) every placeholder still present verbatim is
  replaced by its text; a placeholder the user edited is sent as typed. Backspace or Delete next to
  a whole placeholder removes it and its entry. The draft bound stays 256 KiB after expansion
  (refused `"The message is over 256 KiB."`). Ctrl-Z restore keeps `pastes`. Test:
  `draft_paste_test.exs` (new): a 60-line paste becomes one placeholder; send expands it; a
  deleted placeholder sends nothing.
- **D9 Paste an image from the clipboard** (competitors-6 client, decision 4i). New binding
  `:paste_image`, keys `[{"v", [:control]}]` (unbound today), contexts `[:composer]`, group
  `:edit`, label `"Paste image"`, help `"Paste an image from the clipboard"`; text paste stays the
  terminal's own (Cmd-V, bracketed paste). Effect `{:paste_image, conversation_id}` (`ui/effect.ex`). The runtime, in an
  owned task (`Task.Supervisor` started by the runtime in `init/1`; results correlated by a
  reference; a stale result deletes its file): not macOS → notice `"Image paste needs macOS; use
  /attach PATH."`; `SSH_CONNECTION` set → `"Over SSH the clipboard is the other Mac's; use
  /attach PATH."`; else (1) request `attachment.slot` (C14) → token and path; (2) run
  `/usr/bin/osascript -e 'clipboard info'` (5 s); if the output has `«class PNGf»`, run
  `/usr/bin/osascript -e 'on run argv' -e 'set f to open for access (POSIX file (item 1 of argv))
  with write permission' -e 'set eof f to 0' -e 'write (the clipboard as «class PNGf») to f' -e
  'close access f' -e 'end run' <path>` (5 s); else if it has `«class TIFF»`, write `«class TIFF»`
  the same way to `<path>.tiff`, convert with `/usr/bin/sips -s format png <path>.tiff --out <path>`
  (10 s) and delete the `.tiff`; else notice `"The clipboard has no image."` and release the slot;
  (3) send `attachment.attach_slot` with the token; the staged image shows as a chip (E15).
  Every failure deletes the files it wrote. No new dependency: `osascript` and `sips` ship with
  macOS. Test: runtime test with injected command runners (PNG path, TIFF path, no image, SSH);
  manual check in §9.4.
- **D10 Conversation rewind client** (competitors-8 client, decision 4h). Bare `/rewind` (made
  client-local in `Keymap.local_command/1`, D20; `--plain` keeps the server's `:select_rewind`) and Esc Esc
  (two bare Esc within 600 ms, draft empty, no turn streaming, no layer open) open the layer
  `{:rewind, %{turns: [...], selected: 0}}` from the `rewind.turns` query (C16); ↑/↓ move, Enter
  opens the confirm `{:rewind_confirm, turn}` with three choices — Enter/`b` "Conversation and
  files", `c` "Conversation only", `f` "Files only", Esc cancels — that sends `rewind.apply`; the
  answer (scopes `both`/`conversation`) puts `text` into the composer draft through the undoable
  `replace_draft` (cursor at the end; a draft that was there comes back with Ctrl-Z) and shows
  `"Rewound to turn T · N file(s) restored · edit and press Enter to resend"`; scope `files` shows
  `"Files back to before turn T · N restored"` and leaves the draft. Skipped files add
  `" · K skipped (see the transcript)"`. An empty list shows `"Nothing to rewind yet."`. `/undo`
  (local, D20) asks the same confirm for the newest turn. Test: reducer tests for open, confirm and the draft fill; keymap test for Esc Esc.
- **D11 Ctrl-L redraws** (tui-code-15). Binding `{"l", [:control]}` in `[:composer, :main]` →
  effect `{:terminal_control, :redraw}`: the owner sets `last_plan: nil` and the port invalidates
  its painter (a new BEAM→native tag 10 `Redraw: generation, token`). Test: owner test and cargo test.
- **D12 Keep the last good frame** (tui-code-8). `session_runtime.ex:1011-1022` `project/1`: on
  `:invalid_scene` (or a raise inside `Projector.project/1`, rescued) keep the previous scene, log
  the offending block through the existing explain path, show the notice `"A screen update failed;
  showing the last good one."`, request one full re-project; close only after 5 consecutive
  failures. Test: runtime test with a projector stub that fails twice then succeeds.
- **D13 Settings rows that do something** (tui-code-4). There is no `state.prefs`: the four keys
  live in cli.json and the registry (`terminal.wheel_lines`, `notice_seconds`, `hint_letters`,
  `reduced_motion`, `registry/terminal.ex`) but `UI.Init.Preferences` reads only five legacy keys
  (`preferences.ex:55-71`) and nothing reaches `State`. D adds State fields `wheel_lines` (3),
  `notice_ms` (6_000), `hint_letters` (the `@letters` default, `hint.ex:22`), fed at launch from the
  §8.4 flow and at once by the existing `{:terminal_preferences, …}` path when Settings writes
  them. Then `keymap.ex:623,626` uses `state.wheel_lines` (clamp 1..10); `state.ex:176` `@notice_ms`
  becomes `state.notice_ms`; `UI.Hint` takes the letters from `state.hint_letters`;
  `reduced_motion` already exists as `capabilities.reduced_motion?` (`capabilities.ex:28`): make the
  Settings value set it and the clock-driven pulses and spinners draw a static glyph. Test: one
  test per pref.
- **D14 Quote-aware editor command** (bugs-14). `session_runtime.ex:506-517`: args
  `["-c", ~s(eval "exec $SWARM_EDIT_COMMAND \\"\\$1\\"" 2>&1), "ncode-editor", file]` (today's
  `exec $SWARM_EDIT_COMMAND "$1" 2>&1` at 511 keeps its `2>&1`; the command is
  evaluated by the shell like git's `core.editor`). Test: an editor command `"/tmp/my editor/e"
  --wait` with a fake script runs.
- **D15 Palette typing never gets lost** (ux-live-1 keymap half). While `:switcher` or a picker
  with a query is the top layer, printable text fragments and Backspace always edit the query,
  whatever row has focus; Up on row 0 stays on row 0 (never moves focus to Cancel). Test: keymap tests.
- **D16 `r` retries a failed turn** (ux-live-4 key). In select mode (Ctrl-T) on a failed or stopped
  run's item, `r` sends `{:retry_run, run_id, revision}`. Test: keymap test.
- **D17 Enter on a tool row** (ux-live-12 key). `keymap.ex:860-890`: Enter (and `o`) on a tool row
  opens its full output (`detail_ref`) even when it is not truncated; with nothing to open the footer
  hint (E) says `"nothing more to open"` and Enter does nothing. Test: keymap test.
- **D18 Effort picker layer** (ux-live-14 client, decision 4f). Bare `/effort` and `/swarm_effort`
  are client-local (D20; with an argument they still go to the daemon) and open
  `{:effort_picker, :chat | :swarm}` whose rows are exactly the levels the daemon accepts for that
  model (workspace DTO `effort_levels` / `swarm_effort_levels`, C17; the parser refuses any other,
  `commands.ex:200-224`), the current value (`effort` / `swarm_effort`) ticked, nil shown as
  `default`; Enter sends `/effort <level>` or `/swarm_effort <level>`; Esc closes. Test: reducer test.
- **D19 History search and stash** (competitors-19). Binding `:history_search`, keys
  `[{"r", [:control]}]`, contexts `[:composer]` only, group `:edit`, label `"History"`, help
  `"Search your earlier prompts in this project"`; remove `:composer` from the `:run_palette`
  binding's contexts (`bindings.ex:150-157`; "Switch run" stays on Ctrl-R everywhere else and in the
  Ctrl-P palette, and Ctrl-G opens Runs from the composer). Layer `{:history_search, %{query,
  rows, selected}}`: typing edits the query and sends the `history.search` query (C20), debounced
  150 ms by the owner's timer, stale answers dropped by request id; ↑/↓ move, Enter puts the
  prompt into the draft (undoable replace), Esc closes. Stash: palette actions (E9 adds the rows)
  `{:stash_draft}` and `{:restore_stash}`: one stash per conversation draft key in `State`,
  `"Draft stashed · Ctrl-P Restore stash"`; restore swaps the stash and the draft. Test: keymap
  test (Ctrl-R in the composer opens history, in `main` still opens Switch run); reducer tests
  for stash/restore and a stale answer.
- **D20 Local slash commands** (D10, D18, C1, C11). `Keymap.local_command/1` (`keymap.ex:182-197`)
  gains: bare `/rewind` → `:rewind`, `/undo` → `:undo`, bare `/effort` → `{:effort, :chat}`, bare
  `/swarm_effort` → `{:effort, :swarm}`, bare `/delete` → `:delete`; `/queue` keeps `:queue` and
  `slash_local(:queue)` (`reducer.ex:2917-2941`) splits: bare → opens `{:queue_list}` (E draws
  `queued_texts`, numbered; `d` on a row sends `{:drop, n}`), `clear` and `drop N` (N in
  1..length) → `{:queue_edit, …}` with the snapshot's `queue_revision`, anything else queues the
  text as today (to queue the literal word `clear`, type it and press Alt-Enter). E adds the
  palette rows (`slash_palette.ex` `@local`). Test: keymap tests for each word, including
  `/effort high` staying a daemon command.
- **D21 Markdown row cache field** (tui-code-17, for E31). `State.markdown_cache` (a map plus a byte
  count) owned by the runtime: after each `Projector.project/1`, `session_runtime.ex` merges the
  rows the projector reports as computed (`table.markdown_rows`, E31) into it, byte-accounted, at
  most 4 MiB, evicting least-recently-used keys; a conversation switch clears it. Test: runtime
  test that the cache never passes its bound and a switch empties it.
- **D done**: `cli020 D: done`; `cargo test`, `test_terminal_port_pty.py`,
  `test_terminal_demo_pty.py` and `mix swarm_code.keymap --check` green.

### Lane E: projector, screens, copy, commands, settings registry

- **E1 Worker and Validator words** (tui-code-7, decision 7). Labels only, keys unchanged
  (`models.sub_agent`, `efforts.sub_agent`, `session.sub_agent_*` stay): "Sub-agent model" →
  "Worker model", "Sub-agent effort" → "Worker effort", "the sub-agent model" → "the worker model"
  in `core/settings/registry/{models,session,research}.ex`, `ui/model_picker.ex:60,65` ("Worker
  model", "Switch worker model…"), `ui/settings/sections/{agents_limits,deep_research,library,
  project_file,providers}.ex`, `ui/projector/status.ex:181` comment, `core/commands.ex:21,23`
  ("Reasoning effort of this conversation's worker model", "Switch the model the workers use").
  New registry entries: `models.validator` ("Validator model", global, storage the `settings`
  `default_validator_*` columns, null label "the main model", description "Checks mission work in
  the ncode app; the CLI's Ultra runs workflows."), `efforts.validator` ("Validator effort"),
  `session.validator_model` ("Validator model · this conversation"); place each on its page once
  (`c74_acceptance_test` A3). Regenerate `docs/settings.md` (`mix swarm_code.settings --write`).
  Test: `c74_acceptance_test`, `c74_settings_docs_test`, a grep test that no `lib` string says
  "sub-agent model" or "sub agent model".
- **E2 Honest Ultra** (parity-7, Q6). `core/commands.ex:8` mode hint `"big tasks run as
  workflows (missions are in the ncode app)"`; `:30` `/ultra` description `"Toggle Ultra — big
  tasks run as workflows here; missions are in the ncode app for now"`; the status chip and the
  help sheet say `Ultra · workflows`. Test: commands test asserts the strings.
- **E3 Command registry additions** (bugs-7, ux-live-9, tui-code-14, decision 4f/4h).
  `core/commands.ex` (repin after editing; the daemon parses with it, `command_dispatcher.ex:84-99`):
  `{"rename", "<title>", "Rename this conversation"}` → `:rename_conversation` (empty title →
  `missing_argument`); `{"delete", "", "Delete this conversation (asks first)"}` →
  `:delete_conversation`; `{"fork", "", "Copy this conversation into a new one and open it"}` →
  `:fork_conversation`; `{"undo", "", "Rewind the last turn: its messages and its files"}` →
  `:undo_turn`; the `/rewind` description (line 24) `"Rewind the conversation and files to before an
  earlier turn"`; bare `/effort` and `/swarm_effort` (200-224, `args == ""` →
  `error(:missing_argument)` today) parse to `ok(item, :show_effort, %{target: :chat | :swarm})`;
  `/consensus` (31) `"Consensus mode; with a task, judge this one turn only"`; `quit` (49) `"Leave
  ncode; running work of this session stops"`; lines 21 and 23 per E1. `/queue` is NOT added here:
  it is client-local (D20). In `ui/slash_palette.ex` `@local` (15-49): rows for `/queue [text |
  clear | drop N]`, `/rewind`, `/undo`, `/delete`, `/effort`, `/swarm_effort` with the same words (the existing
  `queue` row, line 47, becomes `args: "<text> | clear | drop N"`),
  so the `/` list shows the local meaning. Test: `commands_test.exs` (core) cases;
  `slash_palette` test for the rows.
- **E4 Effort is visible** (ux-live-14). Draw the `{:effort_picker, scope}` layer (D18) as a
  5-row picker with the current value ticked; the status bar model chip appends the effort
  (`claude-sonnet-5 · medium`, from the DTO `effort`). Test: projector test.
- **E5 Side panel auto** (ux-live-15, Q8). `ui/init/preferences.ex`: panel modes `:auto | :full |
  :compact | :hidden`, default `:auto` (`"auto"` in cli.json; registry `terminal.panel` choices
  `auto, full, compact, hidden`, default `auto`; `preferences.ex:22,39,57,71,89` gain `"auto" =>
  :auto`); Ctrl-B cycles auto → full → compact → hidden → auto (D changes the cycle at
  `reducer.ex:140` and the `State.panel_mode` default and type, `state.ex:66`; E gives D the order). `ui/projector/panel.ex:41-43` and `ui/layout.ex`: `:auto` draws no panel and no strip while
  the conversation has fewer than 2 agents in visible runs and no needs-you item; then it draws
  what `:full` draws at ≥ 120 columns and the one-line strip below 120. The chat subtitle is
  `chat · <tokens>` (`chat · 2k`). Test: projector tests: plain chat at 120 cols → no panel; a swarm
  with 2 workers → panel; an approval → panel.
- **E6 Palette selection always visible** (ux-live-1). `ui/projector/dialog.ex` (switcher,
  ~1043-1106): the scroll offset is clamped so the selected index is inside the window (offset 0
  when the selection is 0). Test: projector test: 24 rows, selection 0 and 23 visible.
- **E7 Help sheet** (ux-live-8). `dialog.ex:1322` `help_entry/5`: the help column is the dialog's
  inner text width minus its left padding (assert equality in a test); long help word-wraps onto a
  continuation row under the help column (no one-letter `…`); no blank row between entries; quit and
  stop come first; Alt-only chords are not listed; `/help` lists the commands too and opens at the top.
- **E8 Slash list** (ux-live-18). Descriptions elided with `…` via `Width.elide`, aligned in one
  column; the list's top rule shows `8 of 40 · ↑↓`.
- **E9 Rows for retry, search and stash** (ux-live-4, tui-code-11, competitors-19). The palette
  (`ui/switcher.ex`) already lists `{:retry_run, …}` as "Retry failed run" (`switcher.ex:385,573`);
  it now shows it first when the newest run is failed or stopped, and lists D19's `Stash draft` /
  `Restore stash`; `/search` results (C8) draw as
  a picker whose Enter resumes the hit's conversation; the failure hint says `r retries · Ctrl-P
  Retry failed run`.
- **E10 The Lead's report once** (ux-live-6). Find where the run's report item and the Lead's last
  reply both become transcript items (GUESSED cause, §10 X14); draw the report only as the panel's
  "reported" fact when the texts are equal. Test: turns test with equal texts → one block.
- **E11 `/agents` and `/workflows`** (ux-live-7). Draw C9's rows as two-column lists (name ·
  description; workflows `query (required) · sources=6`), word-wrapped, one Start action.
- **E12 Turn header words** (ux-live-23, ux-live-3). `ui/projector/workspace/turns.ex:826-838`:
  `writing` from the first content delta (the `ctx.answer` streaming check no longer needs a
  non-blank residual); `retrying 2/5 · HTTP 500` from `RunSummary.retry_detail` (C5) instead of
  `thinking`; a failed run prints its error once (drop the per-agent `✕ Assistant …` row when the
  run-level failure block carries the same text); a network failure whose text contains
  `econnrefused` reads `"Cannot connect to the provider (connection refused)."`.
- **E13 Worker changes, user-facing** (ux-live-2 UI). A worker result whose text ends with the
  model-facing note `"[Changes on branch … Integrate them with the integrate_agent tool when they
  are good.]"` or `"[No file changes.]"` is drawn without that note, with a dim row `+N −M in K
  files` from the node's `changes_stat` (`"3 files changed, +40 −2"`) or `no file changes`. The Lead
  still reads the note (the stored text is unchanged). Test: turns test.
- **E14 Read-only approval card** (ux-live-5, competitors-2). `ui/projector/approval_card.ex`: when
  `DTO.Approval.approval_mode == "read_only"` (§8.2) the card title is `"Ask · <tool>"` and the keys
  row shows only the offered decisions (`y once · d deny · D deny and stop`); for `edit_file` the
  card shows a unified diff of `old_string` → `new_string` from the bounded args (`UI.UnifiedDiff`,
  12 lines, then `… N more`), for `write_file` the first 12 lines of `content`. Test: projector tests.
- **E15 Drawing the new features** (decisions 4c, 4e, 4h, 4i). Composer: a draft with
  `shell?: true` (D7) shows a `$ shell` chip on the composer's top rule; paste placeholders (D8)
  draw as one dim chip `[Pasted text #1 · 60 lines]` that cursor movement skips as a unit; staged
  images (C14, `/attach`) draw as `[Image #1 · 412 KB]` chips. Transcript: a `:shell` item draws
  `$ <command>` with the exit (`exit 0` muted, non-zero in the error colour, `running…` with the
  tick bar) and 2 KB of output with the usual `detail_ref` "N more" line. Layers: `{:rewind, …}` is
  a list `Turn 7 · <prompt> · 3 files · 2h ago`; `{:rewind_confirm, turn}` a small dialog with the
  three choices of D10 and the line `"Later turns are folded (kept, not deleted); files come back
  from checkpoints."`. Test: projector tests and new `demo.cells` scenes for each.
- **E16 Dialogs sized to content** (ux-live-19, bugs-6 UI). Message dialogs are title + body +
  one action row; Quit says `Enter/X quit · Esc cancel`; `/cost` draws C18's per-model rows and the
  total; empty states say what to do (`"No checkpoints yet: they are taken before each edit."`,
  `"Nothing has run yet: send a message, or /swarm <task>."`); the desktop-open warning (C4) is a
  persistent one-line banner in the status area. Test: projector tests at 80×24.
- **E17 Run palette states** (ux-live-21). Terminal runs draw a status glyph instead of a bar
  (`✓` done, `✕` failed in the error colour, `■` stopped; ASCII `+ x #`) and give the width to the
  reason. Test: projector test.
- **E18 Task lists** (ux-live-22). `ui/projector/markdown.ex` list items starting `[ ] ` / `[x] `
  draw `☐` / `☑` (ASCII tier `[ ]` / `[x]` kept). Measure both glyphs with `Width.cells/2` under both
  ambiguous-width policies. Test: markdown test.
- **E19 Background command row** (ux-live-12). Draw C10's `background_state` (`exit 0`, `killed at
  quit`, `still running`, `ended (exit not recorded)`) instead of `exit code pending`.
- **E20 Resume rows** (ux-live-24). Right-aligned relative time (`2h ago`) and a dim second line
  with the last prompt (C19).
- **E21 Syntax** (tui-code-10). `ui/projector/syntax.ex`: per-fence carry state (in string, in block
  comment) across lines, and keyword tables for go, c/cpp, java, ruby, sql, yaml/toml, html/css;
  byte bounds unchanged. Test: syntax tests per language and a multi-line comment.
- **E22 Schedules note** (tui-code-12). The `:schedules` library body's first line: `"Scheduled
  tasks fire only while the ncode app is running. Run now works here."`, shown again after Save.
- **E23 Contrast** (tui-code-13). `ui/theme.ex:62-68` dark `text_faint` `0x868583` (was
  `0x5E5D5A`), `text_ghost` `0x6A6967` (was `0x4B4A48`). Computed WCAG ratios (critic, sRGB
  formula): faint 4.77:1 on `surface` `0x191919` and 4.52:1 on `card` `0x1E1E1E`; ghost 3.21:1 and
  3.04:1 (the report's `0x7A7977` is only 4.04:1/3.83:1, below the floor). `text_muted`
  `0x8C8B88` (5.16:1) stays above faint. The theme test computes and asserts faint ≥ 4.5 and ghost
  ≥ 3.0 on both surfaces;
  `terminal.colors` gains `high_contrast` (faint and ghost become muted, cues bold); ANSI-16 maps
  faint to `:white`. Light mode values checked the same way.
- **E24 Settings detail scrolls** (tui-code-20). `ui/reducer/settings.ex:408`: a detail scroll offset;
  PgUp/PgDn/Ctrl-U/Ctrl-D move it while the detail is open (as the question note does). Bindings
  rows go through D (send D the row text; D adds it to `bindings.ex`).
- **E25 Research levels** (tui-code-21). `dialog.ex:883-885`: `Fastest · about a minute`,
  `Standard`, `Deep`, `Ultra`; the stored value stays the atom.
- **E26 New terminal settings** (for D3, D5, D8, B21). In `core/settings/registry/terminal.ex` and
  `ui/init/preferences.ex`: `terminal.mouse` default `false` (description `"Off: the wheel
  scrolls and the terminal's own selection works. On: wheel reports, Shift-drag selects. SWARM_MOUSE
  wins at the next launch."`); `terminal.notify` (enum `auto|bell|osc9|os|off`, default `auto`,
  cli.json `notify`); `terminal.title` (toggle, default on, cli.json `title`);
  `terminal.paste_collapse_lines` (int 0..200, default 8, cli.json `paste_collapse_lines`);
  `terminal.exit_transcript` (int 0..20, default 3, cli.json `exit_transcript`); `terminal.panel`
  per E5. `terminal.wheel_lines` (`registry/terminal.ex:235-247`) loses "Only when Wheel scrolling
  is on." (with alternate scroll it applies in both modes: `"Lines per wheel notch."`) and
  `ui/settings/sections/keys_input.ex:43` stops hiding its row when the mouse is off. `Preferences`
  gains the fields of §8.4 (`notify`, `title?`, `paste_collapse_lines`, `wheel_lines`,
  `notice_seconds`, `hint_letters`), read from cli.json beside the five legacy ones. Each on its Settings page once; regenerate `docs/settings.md`. Test: `c74_acceptance_test`,
  preferences round-trip tests.
- **E27 The desktop's themes** (competitors-21). `ui/theme.ex`: named palettes `carbon` (today's),
  `aurora`, `dusk`, `ember`, `fjord`, `graphite`, `obsidian`, `paper`, each with its dark and light
  values taken token by token from `~/dev/swarm-code/assets/css/themes.css` (read-only; the same
  token names `Theme` already maps; no invented colour). New cli.json key `palette`
  (`terminal.palette`, enum of the eight, default `carbon`); `/theme <name>` sets it (`/theme
  dark|light` keeps the mode); the 256 and 16 colour tiers map by nearest as today; E23's contrast
  floors are asserted for every palette's faint and ghost (raise a palette's faint to the floor if
  its desktop value is lower, and list each change in `notes/E.md`). Test: theme tests per palette.
- **E28 Status line items** (competitors-20). `terminal.status_items` (cli.json `status_items`, a
  list of `mode, approval, model, effort, branch, ctx, cost, waiting`, default all but `branch`);
  `ui/projector/status.ex:150-224` draws only the listed items in that order; `branch` draws
  `⎇ <git_branch> +<git_dirty>` from C22 (ASCII `br:`). Test: projector tests for the default, an
  empty list and `branch`.
- **E29 Plan section** (competitors-14). `Projector.Panel`/`Strip`: when the selected run has
  `RunSummary.plan` (C23), a `Plan 3/7` section above the agents (done `✓`, in progress `▸`,
  pending `·`; ASCII `+ > .`), at most 7 rows then `… N more`; the strip shows `Plan 3/7`. Under
  `:auto` (E5) a plan counts as a reason to show the panel. Test: projector tests.
- **E30 Hooks and rules in Settings** (competitors-10, competitors-11). Settings → Project file
  (`ui/settings/sections/project_file.ex`) lists C23's `project_config.summary`: one row per hook
  (`event · command`) and the three rule lists (`allow`, `ask`, `deny`), read-only, with the hint
  `"Edit .swarm_code/config.json; ncode reads it for trusted projects only."`. Test: section test.
- **E31 Markdown rows cached** (tui-code-17). `ui/projector/workspace/turns.ex:1740-1751`
  (`prose_rows(text, state, width, indent)` → `Markdown.rows`; it gets no item id): look up the
  collision-safe key `{:crypto.hash(:sha256, text), inner, ambiguous policy, glyph tier}` in
  `state.markdown_cache` (D21) before computing, and report every computed
  entry in `table.markdown_rows` (the projector stays pure). Before the change, lock a fixture
  (a 200-message conversation in `UI.Fixtures`) and measure the projection time and post-GC memory
  with a new `scripts/dev/bench_markdown.exs`; record before/after numbers in `notes/E.md`. Golden
  equivalence test: the scene of the fixture is identical with an empty cache, a warm cache and a
  cache evicted mid-way. Test: that equivalence test plus the bench in the notes.
- **E done**: `cli020 E: done`; projector, settings and `demo.cells` tests green; the cell
  gallery (`mix swarm_code.demo.cells`) builds.

### Lane F: desktop first (`~/dev/swarm-code-wt/cli020-F`, branch `cli020/F-desktop`)

Follow the desktop AGENTS.md (CHANGELOG pass entry, `mix precommit`, no migration, LLM.Fake only).
This is desktop pass 72. F must not add a migration or change a schema.

- **F1 Read-only asks** (ux-live-5, competitors-2, onboarding-5; decision 3).
  `lib/swarm_code/engine/policy.ex`: delete the clause at lines 16-17 (`decide("read_only",
  :execute, _safety)`) and change lines 31-32 to `def decide("read_only", permission, _safety)
  when permission in [:write, :execute], do: :ask`; rewrite the top comment ("read-only asks
  before every write and command; a `:safe` command asks too"). Resulting table: read_only `:read`
  allow, `:private_network` ask, `:write` ask, `:execute` (any class) ask.
  `engine/operation.ex:285-321`: bind `mode = current_mode(ctx)` once and call
  `RunServer.request_approval(run_id, id, permission, safety, mode)`.
  `engine/run_server.ex`: add `request_approval/5` (`/4` delegates with `nil`); the handler
  (960-1006) stores `mode: mode` in `state.approvals[node_id]`, and the auto-approve shortcut
  (`state.always`, `auto_approved?/2`, `mission_commands_allowed?/3`) applies only when `mode !=
  "read_only"`; in the resolve path (~1832-1850) a read-only approval resolved with `:always` or
  `{:always_prefix, _}` is treated as `:approve` (nothing is remembered). The card: add a virtual
  field `field :approval_mode, :string, virtual: true` to `conversations/node.ex` (beside the
  virtual `approval_prefix`, line 69; no migration) and set it in the same `put_node` call that
  sets `approval_prefix` (run_server.ex ≈984-988), cleared with it on resolve (≈1852). In
  `chat.ex` `approval_actions/1` (764-815) add `attr :approval_mode, :string, default: nil`; when it
  is `"read_only"` render only `Approve`, `Deny` and `Deny & stop` (hide the run-wide pill, whose
  label is `class_pill_label/1` "Allow all <tool> this run", and the family pill `Always allow
  "<prefix>"`). Pass `approval_mode={node.approval_mode}` at every call site: `chat.ex:3087,3151`,
  `side_chat.ex:937,1066`, `swarm_pane.ex:4198`. Update the comments that say read-only denies (`tools/command_safety.ex:11`,
  `research/server.ex:119-121`). Tests: `test/swarm_code/engine/policy_test.exs` (read_only write
  and every execute class → `:ask`), `test/swarm_code/engine/approval_test.exs` (a read-only
  `write_file` waits for approval; `:always` resolves once and the next write asks again; a
  remembered prefix does not skip the ask in read-only), `test/swarm_code/workflows/commands_test.exs`
  (its read-only expectation), and `test/swarm_code_web/live/polish72_read_only_ask_test.exs`
  (LiveView, `Fixtures` + `LLM.Fake`, stable element ids): the card shows `Approve`, `Deny` and
  `Deny & stop` and no `always`/`always_prefix` button; an `auto` project's card still shows them.
- **F2 `Conversations.supersede_from/2`** (competitors-8, decision 4h). Beside `supersede/2`
  (`conversations.ex:886`): `@spec supersede_from(Conversation.t(), Message.t()) :: {:ok, [Run.t()]} |
  {:error, :database_busy | term()}` — in one IMMEDIATE transaction inside `with_busy_retry/1`, set
  `superseded_at` on every non-superseded message of the conversation with `position >=
  message.position` (positions are per conversation), and on every run launched by one of them
  (`launched_run_id/2`, 942-948: a steer launches nothing; legacy rows without `run_id` go through
  `legacy_run_id/2` once for the whole set, not per message) plus the runs whose
  `launched_by_run_id` is one of those; messages whose `run_id` or `reply_to_run_id` is one of
  those runs are superseded too (the `supersede_scope/3` rule, 954-966); outside the transaction clear their goals
  (`clear_goal/1`, as `supersede/2` does) and broadcast `{:message_updated, m}` and
  `{:run_updated, run}` for each. Stopping live runs stays the caller's job (the CLI's C16 does it).
  Test: `test/swarm_code/conversations_supersede_from_test.exs`: 3 turns, from turn 2 → turns 2-3
  and their runs superseded, turn 1 untouched, history (`list_history_window/2`) excludes them; a
  steer message superseded with its target run's turn.
- **F3 A `shell` message role** (competitors-9, decision 4c). `conversations/message.ex`: allow
  role `"shell"` (the inclusion list); `engine/prompts.ex:552-568` history: `%Message{role:
  "shell", content: c} when c != "" -> [%{role: "user", content: "[Shell command the user ran]\n" <>
  c}]`; `conversations.ex` `fork_row?/2` includes `"shell"`; `chat.ex` draws a shell message as
  author "Shell" with its content in a code block. Test: prompts test (history mapping), a
  Chat render test.
- **F4 Workers in a dirty project report no false changes** (ux-live-2). Desktop test
  `test/swarm_code/engine/isolation_dirty_tree_test.exs`: a git fixture with 3 uncommitted files, a
  swarm on `LLM.Fake` whose worker makes no edit, both backends (`:worktree`, `:clone`): the report
  ends `"[No file changes.]"`, has no `"Delta patch captured"`, and the 3 files are untouched. If it
  fails, fix the base in `run_server.ex` `commit_and_stat/2` / `Isolation.Delta.capture/2` (diff
  against the isolation's start commit, never the user's dirty tree) and say so in the CHANGELOG.
- **F5 `Attachments.prune_abandoned/3` keeps given ids** (bugs-4). `attachments.ex:374`:
  `prune_abandoned(now \\ DateTime.utc_now(), older_than_hours \\ 24, opts \\ [])`, `opts[:keep]`
  an enumerable of ids treated like referenced ones; callers unchanged. Test: a kept id older
  than 24 h survives.
- **F6 Desktop installer lockstep guard** (parity-3, Q2). New `lib/mix/tasks/ncode.cli_lockstep.ex`:
  reads `$NCODE_CLI_REPO` (default `~/dev/swarm-code-cli`); if absent, prints `ncode CLI lockstep:
  no CLI checkout at <path>; skipped.` and exits 0. Else it reads every
  `apps/swarm_code_daemon/priv/schema/desktop-*.json`, takes the manifest with the most
  migrations, and compares its migration versions with `priv/repo/migrations/*.exs`; a desktop
  migration the CLI manifest lacks prints `ncode CLI lockstep: this desktop has N migration(s) the
  ncode CLI does not know (<files>). Users of the CLI would be locked out: re-pin and ship the CLI
  first, or set NCODE_SKIP_CLI_LOCKSTEP=1.` and raises `Mix.Error`. `mix.exs` alias
  `"desktop.installer": ["ncode.cli_lockstep", "desktop.installer"]`. Read the JSON keys from the
  CLI's `MigrationManifest` loader before you write the parser. Test:
  `test/mix/tasks/ncode_cli_lockstep_test.exs` with a tmp CLI tree (equal → ok; one more desktop
  migration → raises; missing repo → skipped).
- **F8 A per-run approval override** (competitors-4, for B23). `Engine.start_chat_turn/4`,
  `start_swarm/3` (`engine.ex:66,743`) accept `opts[:approval_mode]` in `~w(read_only auto
  full_access)` (anything else → `{:error, :invalid_approval_mode}`); it is stored in the run's
  agent ctx as `approval_override`, and `operation.ex` `current_mode/1` (387-395) returns it before
  the project's cached mode (research keeps its own clause first). An untrusted project
  (`Projects.trusted?/1`) refuses `auto`/`full_access` with the error the desktop's
  `set_approval_mode` path gives. The desktop UI does not use it. Test: an approval test where a
  `read_only` project's run started with `approval_mode: "auto"` writes without asking, and the
  project row is unchanged.
- **F9 More hook events** (competitors-10). `hooks.ex` `@type event` and the dispatcher gain
  `:stop` (in `run_server.ex` `finish_run/4`, 4309: `%{status, run_id}`), `:notification`
  (`notify_waiting/2`, 4285: `%{kind: "approval" | "question", run_id}`), `:user_prompt_submit`
  (`Engine.start_chat_turn/4` before the run starts: exit 2 refuses the send with the hook's stderr
  as the reason, `{:error, {:hook_blocked, reason}}`), `:pre_compact` (`Engine.start_compact/3`,
  288; informational) and `:session_end` (`quit.ex`, the desktop's quit; informational, bounded);
  same trust gate, scrubbed env, output bound and kill-tree timeout as today; `project_config.ex`
  accepts the new event names. The non-blocking events run in the existing
  `Hooks.TaskSupervisor`, never in the RunServer callback. Test: one test per event with a
  trusted fixture project.
- **F10 Permission rules** (competitors-11). `.swarm_code/config.json` key `"permissions": {"allow":
  [...], "ask": [...], "deny": [...]}`; each rule is `tool` or `tool(pattern)` where `pattern` is a
  glob on the command (`run_command`), on the project-relative path (file tools) or on the URL host
  (`web_fetch`); MCP tools by their full name. New pure `SwarmCode.Engine.Rules.decide(rules, tool,
  args) :: :allow | :ask | {:deny, reason} | :none` (deny beats ask beats allow); `operation.ex`
  `do_work/6` (285-325) calls it before `Policy.decide/3`: `{:deny, r}` → `{:error, "blocked by
  rule " <> r}`; `:ask` → the approval path even in `full_access`; `:allow` → skips the ask, except
  for a `:dangerous` command (still asks) and `:private_network` (still the mode's answer); `:none`
  → `Policy.decide/3` as today. Rules are read only for trusted projects (the `Hooks` trust gate),
  through `ProjectConfig` with the file's existing size bound. Test: `rules_test.exs` (pure) and an
  approval test per outcome.
- **F11 A live plan tool** (competitors-14). New `tools/update_plan.ex` (`Tools.Tool`): args
  `{"items": [{"text", "status": "pending" | "in_progress" | "done"}]}` (1..30 items, text ≤ 200
  bytes, at most one `in_progress`), permission `:read`, result `"plan updated (3/7 done)"`; added to
  every lead's tool set in `tools.ex`, not to workers. The plan is the `input` of the newest
  `update_plan` op node of the agent (already persisted; no new column). `prompts.ex`: one line in
  the lead's rules, "For work with three or more steps, keep a plan with update_plan and update it
  as steps finish." The desktop shows it as an ordinary tool row this pass. Test: tool test for
  bounds; a run on `LLM.Fake` that calls it leaves the op node with the items.
- **F7 CHANGELOG and AGENTS**. `CHANGELOG.md`: a "pass 72 (CLI 0.2.0 shared engine)" entry listing
  F1-F6 and F8-F11. Desktop `AGENTS.md`: one line under "Required workflow": "A desktop migration ships only
  with a re-pinned ncode CLI (`mix ncode.cli_lockstep` runs before `desktop.installer`)."
- **F done**: `mise exec -- mix precommit` green in the worktree (take a suite slot); commit
  `cli020 F: done`; tell the orchestrator the sha so it merges into desktop `main` (Fm) for A'.

### Lane G: installer and public CLI docs (site repo)

- **G1 `code/install.sh`** (onboarding-8, onboarding-9, onboarding-22, onboarding-25; decision 1).
  POSIX `sh`, `set -eu`, no bash-isms. `VERSION="${NCODE_VERSION:-0.2.0}"`; `SHA256` stays the
  pinned value of the 0.2.0 tarball, which the orchestrator fills in after the release build (G
  leaves `SHA256="REPLACE_WITH_0.2.0_SHA256"` and a check that refuses to run while it is the
  placeholder: `"ncode: this installer has no checksum yet."`, exit 1). Arguments by `case`:
  `-h|--help` prints usage and exits 0; `--uninstall` lists exactly the paths it removes
  (`$bin/ncode`, `$bin/swarmcode`, `$share`, and `$prefix/share/swarmcode` when it exists), asks
  `Remove these? [y/N]` reading `/dev/tty`, and needs `--yes` when there is no tty (otherwise exit 2,
  `"ncode: --uninstall needs --yes when not run from a terminal."`); `--yes` is accepted only with
  `--uninstall`; anything else exits 2 with `"ncode: unknown option '<x>'. Run with --help."`.
  Atomic replace: extract under `$tmp`, move to `$share.new` (same filesystem as `$share`), rename an
  existing `$share` to `$share.old`, rename `$share.new` to `$share`, roll back on failure, then delete
  `$share.old`; the trap also removes `$share.new`. After the move: `xattr -dr
  com.apple.quarantine "$share" 2>/dev/null || true`. At the end print the result of `"$bin/ncode"
  --version`, the exact `echo 'export PATH="<bin>:$PATH"' >> ~/.zshrc` line when `<bin>` is not on
  PATH, and `Next: ncode settings providers  (add your model key; ncode has no built-in key)`.
  Test: a `tools/test_install_sh.py` (new, `python3 -I`, tmp prefix, a fake tarball served by
  `NCODE_TARBALL_URL=file://…` with a matching `SHA256` override env used only by the test):
  install, reinstall (old tree replaced, no `.new`/`.old` left), `--help` (exit 0, nothing
  installed), `--bogus` (exit 2), `--uninstall --yes` (lists then removes), `--uninstall` without a
  tty (exit 2, nothing removed), `--uninstall --help` (exit 0, nothing removed).
- **G2 Public docs** (onboarding-14 and every user-visible change). `content/ncode/docs/shared/approvals.md`
  (read-only asks; the y/d card); `cli/modes.md` (Ultra runs workflows; Shift-Tab cycle); `cli/composer.md`
  (`!cmd`, paste chips, Ctrl-V images, Esc Esc); `cli/rewind.md` (conversation and files,
  `/undo`); `cli/headless.md` (stdin, piped stdin block, `LC_ALL=C`, `--json` on failure,
  `--fail-on-denied`, the one denial line); `cli/terminal.md` (mouse off, wheel by alternate
  scroll, notifications, title, Ctrl-L); `cli/session.md` (exit transcript and spend line);
  `cli/config.md` and `cli/keys.md` (`config keys` lists every setting key); `cli/commands.md`
  (`/queue`, `/rename`, `/undo`, bare `/effort`); `cli/install.md`, `troubleshooting.md`,
  `desktop.md` (0.2.0, the version sentence of the refusal, the desktop-open banner).
  `settings-reference.md` is refreshed by the finisher from the merged `docs/settings.md`. Use the
  words "Worker model" and "Validator model". Test: `python3 -I tools/test_build_ncode.py`,
  `node tools/test_release_layout.mjs`.
- **G done**: `cli020 G: done`.

## §7 Feature designs (behaviour, ownership, edge cases)

The tasks of §6 carry the code-level detail; this section fixes the behaviour end to end.

**7.1 Read-only asks (decision 3).** Flow: model calls a `:write`/`:execute` tool → desktop
`Policy.decide("read_only", …)` returns `:ask` (F1) → `RunServer.request_approval/5` stores
`mode: "read_only"` → the CLI's `PendingInteractions.approval_row/4` offers `[:approve, :deny,
:deny_stop]` (A'2) → the card shows `y once · d deny · D deny and stop` with a diff (E14).
Edge cases: a remembered command family or an earlier `Y` never skips the ask in read-only (F1);
`/approval auto` mid-run applies to the next op (`current_mode/1` reads per op), and an approval
already waiting keeps the card it was raised with (its `mode` was stored at request time); a `:dangerous`
command asks in every mode as before; research runs keep their in-memory `auto` mode; workflows in
a read-only project now wait on cards (10-minute approval timeout, unchanged); `-p` auto-denies each
(up to 8, then stops the run) and prints one line (B3). Tests: F1, A'2, B3, E14.

**7.2 Shift-Tab (4b).** One key cycles Ask (read-only) → Auto → Plan → Ask, through the existing
`/approval` and `/plan` commands, so the server stays the decider (D6). Full access is never
entered by the cycle. The approval mode is the project's (shared with the desktop and other
conversations of the project); the notice says `Auto (this project)`. Shift-Tab keeps its
focus-back meaning in every non-composer context (`bindings.ex:279,492`).

**7.3 `!cmd` (4c).** Composer `!` → `shell.run` → `ShellEscape` task → `RunCommand` (scrubbed env,
user umask, kill-tree timeout 120 s) → a `shell` message the model reads next turn as
`[Shell command the user ran]` (F3) and the desktop shows as "Shell". Owners: D7 (keys), C15 (run,
persist), F3 (role), E15 (draw). Edge cases: not in `--plain`/`-p` (the plain lexer treats `!` as
text); a live session (`LiveBackend`) refuses `"The shell escape needs a saved session."`; output
is bounded by `RunCommand` and the transcript shows 2 KB with a `detail_ref`; Ctrl-C/Esc stop it;
quitting kills it (backend terminate); an interactive program (`vim`) gets no tty and ends on EOF
(document: "interactive programs need their own terminal"). Tests: D7, C15, F3, E15.

**7.4 Scrollback on exit (4d) and the spend line (4g).** After the port restores the main screen,
`print_summary/1` prints the last `exit_transcript` exchanges (default 3), then the summary block
with `Spent` (B21, E26). Never in `-p`/`--plain`. Edge cases: a conversation with no messages
prints only the summary; costs unknown for some run → no `$` part; superseded turns are skipped; a
reply with control characters is filtered.

**7.5 Paste chips (4e).** D8 owns the draft model, E15 the drawing. The placeholder is plain text
in the draft, so history, Ctrl-Z, Ctrl-X and the 256 KiB bound keep working; expansion happens only
on send. Edge cases: pasting the same text twice makes two chips; a placeholder typed by hand that
matches no entry is sent as typed; vim mode treats a chip as one word.

**7.6 `/effort` picker (4f).** Bare `/effort` (chat) and `/swarm_effort` (Worker) open the picker
(D20 local command, D18 layer, E4 draw); the status chip shows the chat effort. The rows are the
levels the daemon would accept for that model (`effort_levels`/`swarm_effort_levels`, C17, the same
`efforts/2` the parser uses), so a level the model does not take is never offered. `--plain` and
other non-TUI senders get E3's `:show_effort` report instead.

**7.7 Notifications and title (4a).** D3. The bell and OSC 9 fire only while the terminal reported
focus lost (`CSI ? 1004 h` is on); terminals without focus reports never bell (no false alarms).
The title updates always (setting `terminal.title`) and is restored at exit (`CSI 22;2 t` /
`CSI 23;2 t`). Only one bell per new interaction; a burst of 5 approvals bells once per 2 s.

**7.8 Conversation rewind (4h).** Desktop domain functions reused, unchanged:
`Conversations.supersede/2` semantics (spec 52: superseded rows are kept, folded, and left out of
the model's history by `list_history_window/2` and `fork_row?/2`), `Checkpoints.restore_run_report/2`
(files of a run and every later run, newest first, with the "Rewound N file(s) to before turn T."
`swarm` message), `Checkpoints.for_conversation/1` (turn numbers and files), `Engine.running_runs/1`
and `Engine.stop_run/1` (as the desktop's `supersede_and_route/6` does,
`workspace_live.ex:8261-8288`), edit and resend in place (the rewound prompt comes back into the
composer; Enter is a fresh send through `dispatch_send`). Added: `Conversations.supersede_from/2`
in the desktop (F2: the multi-turn form of `supersede/2`), `Daemon.Service.Rewind` (C16: order
stop → supersede → restore → answer; VERIFIED safe: `list_runs/1` keeps superseded runs, so
`restore_run_report/2` still numbers the turn, and its "Rewound…" `swarm` message is written after
the supersede, so it stays visible), the layer and Esc Esc (D10), the drawing (E15), `/undo`
(E3 for the daemon, D20 for the TUI's confirm). Edge cases: rewinding while a compaction runs is refused; a turn before a `compact`
message can be rewound (the compact row is later, so it is superseded too and the full history
returns: VERIFIED, `compact_floor/1` ignores superseded compact rows, desktop
`conversations.ex:754-760`); the desktop's edit-and-resend restores no files, the CLI's rewind does
(decision 4h); a steer message is not offered as a rewind point; a steer message's run is the run it steered (not superseded unless launched later); a
failed restore after a successful supersede is reported and the conversation part stays; the
desktop shows the same folded turns when it opens the database later.

**7.9 Image paste (4i).** The macOS pasteboard is read with `/usr/bin/osascript` (`clipboard
info`, then `the clipboard as «class PNGf»` or `«class TIFF»` written straight to a file with
`open for access … write`), TIFF converted by `/usr/bin/sips`; both ship with macOS, so no new
dependency and no Rust pasteboard code. The file is staged in the daemon-owned inbox
`<SwarmCode.Domain.Paths.config_dir()>/cli-inbox/<token>.png` (0700/0600, token-addressed so the daemon
never takes a path from the client, C14), then copied into the existing attachment store and
staged like `/attach`. Size cap: `Attachments.max_bytes/0` = 6,000,000 bytes; at most 4 images per
message. Owners: D9 (key, osascript, files), C14 (slot, validation, staging), E15 (chip).

**7.10 Mouse off and alternate scroll (Q5).** D5 + E26. Default: no mouse reports, `?1007h`, so
the terminal selects text natively and turns wheel notches into arrow keys; the port treats a
burst of ≥ 2 identical arrows in one read as the wheel. Known limit (§11 Q1): a terminal that sends
one arrow per notch walks the prompt history instead of scrolling; `/mouse on` is the answer.

**7.11 Side panel auto (Q8).** E5. Thresholds: ≥ 2 agents in visible runs, or any needs-you item
(approval, question, a worker waiting). Ctrl-B still forces any mode and persists it.

**7.12 `/consensus <task>` one-shot (Q7).** C7 + E3. The persisted conversation keeps its mode;
the one run is judged. The desktop keeps its sticky behaviour this pass (§11 Q4).

**7.13 `/ultra` relabel (Q6).** E2 + A6. CLI Ultra keeps the workflow tool set and prompt; the
words say missions live in the ncode app.

**7.14 Drift gate (Q2).** A7 in the CLI (release build fails, precommit fails on new desktop
migrations, warns on code drift) and F6 in the desktop (`desktop.installer` fails when the desktop
has migrations the CLI manifest lacks). Together a release of either app can no longer silently
lock the other out.

**7.15 Findings planned beyond decision 4 (critic).** The critic's rule is that only decision 6
defers. So these are in scope with the smallest shape that closes the finding: headless flags
(B23 + F8), permission rules (F10 → A'1, shown read-only by E30), hook events (F9 → A'1, A'4,
E30), a plan tool (F11 → C23 → E29), history search and stash (C20, D19, E9), git facts and
status items (C22, E28), the desktop's eight palettes (E27), `/delete` and `/fork` (C11, D20), and
the Markdown row cache with a locked fixture (D21, E31). Shared engine parts are desktop first
(Q3). If the owner wants any of them out, §11 Q7 lists the cut: drop the task ids and mark the row
deferred with "owner cut 2026-10-07".

## §8 Interfaces between lanes

Code against these names. If the providing lane has not landed yet, stub them in your focused test
(the `Fake` data source for the wire, a local function for Elixir APIs) and list the stub in your
notes; the finisher removes it.

### 8.1 Elixir functions

| Function | Provider | Consumers |
| --- | --- | --- |
| `SwarmCode.Daemon.FoundationGate.desktop_running?(opts :: keyword()) :: boolean()` | A3 | C4 |
| `SwarmCode.Daemon.Service.CommandLedger.staged_attachment_ids() :: [String.t()]` | C2 | A'3 |
| `SwarmCode.Domain.Attachments.prune_abandoned(now, hours, keep: Enumerable.t())` | F5 → A'1 | A'3 |
| `SwarmCode.Domain.Conversations.supersede_from(Conversation.t(), Message.t()) :: {:ok, [Run.t()]} \| {:error, term()}` | F2 → A'1 | C16 |
| `SwarmCode.Domain.Engine.RunServer.request_approval/5`, `state.approvals[node_id].mode` | F1 → A'1 | A'2 |
| message role `"shell"` (`Message` changeset, prompts history, fork) | F3 → A'1 | C15, B21 |
| `SwarmCode.Daemon.Service.SessionConfiguration.override_source(override :: map() \| nil) :: :flag \| :first_run_env \| nil` | B13 | C13 |
| `SwarmCode.Domain.Paths.config_dir/0` (exists, `paths.ex:18`) | — | C14 |
| `SwarmCode.Domain.Engine.start_chat_turn/4` and `start_swarm/3` `opts[:approval_mode]` | F8 → A'1 | B23 |
| `SwarmCode.Domain.Hooks` events `:stop`, `:notification`, `:user_prompt_submit`, `:pre_compact`, `:session_end` | F9 → A'1 | A'4, C23 |
| `SwarmCode.Domain.Engine.Rules.decide/3` and the `"permissions"` config key | F10 → A'1 | C23, E30 |
| tool `update_plan` (the op node's `input`) | F11 → A'1 | C23 |
| `SwarmCode.Daemon.Service.CommandDispatcher.efforts/2` (made public) | C17 | C's projection |

Until A'1 lands, C16 and C15 run against the synced domain at `4c7c577a`: C16's tests stub
`supersede_from/2` with a loop over `Conversations.supersede/2` newest first (same result for the
test fixtures) and C15 persists `role: "swarm"` behind a single private function
`shell_message_role/0` that the finisher flips to `"shell"` (B21's exit transcript then shows
those rows as swarm rows until the flip; its test uses `"shell"` rows inserted directly). B23's
`--approval` refusal and C23's plan/hook/permission facts are inert until A'1 (their tests use
fixture rows and `Fake`).

### 8.2 Wire (C owns both halves and the `Fake`)

Client intents (`ui/intent.ex`, each with its `validate/1` clause and bounds):
`{:shell_run, conversation_id, text}` (text 1..4,096 bytes), `{:shell_stop, conversation_id}`,
`{:queue_resume, conversation_id}`, `{:queue_edit, conversation_id, queue_revision, :clear |
{:drop, pos_integer()}}`, `{:rewind_apply, conversation_id, message_id, :both | :conversation |
:files}`, `{:attachment_slot, conversation_id}`, `{:attach_slot, conversation_id, token}` (token
`~r/\A[0-9a-f]{32}\z/`); `{:retry_run, run_id, revision}` exists (`intent.ex:70`) but no daemon
op carries it yet (C6 adds `run.retry`). Queries: `{:rewind_turns, conversation_id}` →
`[%{message_id, position, turn, prompt, at, run_id, files}]`; `{:history_search, query}` (C20).
Daemon command names follow the existing dotted style: `shell.run`, `shell.stop`, `queue.resume`,
`queue.edit`, `rewind.turns`, `rewind.apply`, `attachment.slot`, `attachment.attach_slot`,
`run.retry`, `history.search`. Every new op needs, in one commit: `core/protocol/service_request.ex`
`decode_operation/1`/`encode_operation/1` (114-140), the handshake capability map
(`service_handshake.ex:29` style), the client's `daemon.ex` `request_capability/1` (979 style) and
`codec.ex` `request_body/1` (550 style), the backend handler, and the `Fake` answer. Slash actions
handled by the dispatcher (E3's parser): `:rename_conversation`, `:delete_conversation`,
`:fork_conversation`, `:undo_turn`, `:show_effort`. Local commands (D20, never sent as typed):
bare `/queue`, `/queue clear`, `/queue drop N`, bare `/rewind`, `/undo`, bare `/effort`, bare
`/swarm_effort`, bare `/delete` (confirm first).

DTO fields (all bounded by `JsonLimits`; nil when unknown):

| DTO | New fields | Producer → consumers |
| --- | --- | --- |
| workspace snapshot | `queued_count :: non_neg_integer()`, `queue_paused :: boolean()`, `queue_revision :: String.t()` (16 hex), `effort`, `swarm_effort`, `effort_levels :: [String.t()]`, `swarm_effort_levels :: [String.t()]`, `validator_model :: String.t() \| nil`, `desktop_running :: boolean()`, `git_branch :: String.t() \| nil`, `git_dirty :: non_neg_integer() \| nil` (`queued_texts` exists, `dto/workspace_snapshot.ex:56`) | C1, C4, C17, C22 → D (Enter, Shift-Tab, effort picker, queue), E (status, banner) |
| `DTO.RunSummary` | `retry_detail :: String.t() \| nil` (state `:retrying` exists), `plan :: [%{text, status}] \| nil` | C5, C23 → E12, E29 |
| `DTO.Approval` | `approval_mode :: String.t() \| nil` | A'2 + C → E14, B22 |
| transcript item | kind `:shell` with `exit :: integer() \| :stopped \| nil`; tool items `background_state :: String.t() \| nil` | C15, C10 → E15, E19, B21 |
| conversation row | `updated_at :: DateTime.t()`, `last_prompt :: String.t() \| nil` | C19 → E20 |
| answer of `rewind.apply` | `%{type: :rewound, text, attachments, restored, skipped}` | C16 → D10 |
| answer of `attachment.slot` | `%{token, path}` | C14 → D9 |
| answer of an attachment staging (`/attach`, `attachment.attach_slot`) | `%{"id", "name", "mime", "bytes"}` (`bytes` new) | C14 → E15 |
| answer of `history.search` | `[%{text, conversation_id, at, detail_ref \| nil}]` (≤ 50) | C20 → D19 |
| shell-watch delta | `{:desktop_running, boolean()}` | C4 → D (state), E16 |

### 8.3 Client-internal names (D owns, E draws)

- Actions (`ui/action.ex`): `{:cycle_permission_mode}`, `{:paste_image}`, `{:rewind_open}`,
  `{:rewind_choose, :both | :conversation | :files}`, `{:effort_pick, level}`.
- Effects (`ui/effect.ex`): `{:bell, :needs_you | :turn_done}`, `{:terminal_title, SafeText.t()}`,
  `{:notify_os, SafeText.t()}`, `{:paste_image, conversation_id}`, `{:terminal_control, :redraw}`
  (added to the existing `:suspend | :resume | :shutdown`).
- Layers: `{:rewind, %{turns: list(), selected: non_neg_integer()}}`, `{:rewind_confirm, turn}`,
  `{:effort_picker, :chat | :swarm}`, `{:history_search, %{query, rows, selected}}`,
  `{:queue_list}`.
- Inputs (`ui/input.ex`): `{:scroll, :up | :down, 1..32}` (D5).
- State fields (D): `wheel_lines`, `notice_ms`, `hint_letters`, `last_bell_at`, `markdown_cache`,
  per-draft-key stash; `panel_mode` gains `:auto`.
- `SwarmCodeCLI.UI.Composer.enter_action/1` gains `:shell` and `:run_queue` (draft empty and
  `queue_paused`); the composer state exposes `shell?` and the draft `pastes` map.

### 8.4 Preferences and cli.json keys (E owns the registry and `ui/init/preferences.ex`)

| cli.json key | Preferences field | Type, default | Read by |
| --- | --- | --- | --- |
| `mouse` | `mouse?` | boolean, `false` | D5 |
| `panel` | `panel_mode` | `"auto" \| "full" \| "compact" \| "hidden"`, `"auto"` | E5 |
| `notify` | `notify` | `:auto \| :bell \| :osc9 \| :os \| :off`, `:auto` | D3 |
| `title` | `title?` | boolean, `true` | D3 |
| `paste_collapse_lines` | `paste_collapse_lines` | 0..200, `8` | D8 |
| `exit_transcript` | `exit_transcript` | 0..20, `3` | B21 (reads cli.json through `SwarmCode.Settings.CliFile`) |
| `wheel_lines`, `notice_seconds`, `hint_letters`, `reduced_motion` | new fields (the registry keys exist; `Preferences` reads only `panel`, `show_diffs`, `theme`, `mouse`, `agent_summaries` today, `preferences.ex:55-71`) | registry defaults (3, 6, the `UI.Hint` letters, false) | D13 |
| `palette` | `palette` | one of the eight E27 names, `"carbon"` | E27 |
| `status_items` | `status_items` | list, E28 default | E28 |

Flow (one hand-off per owner): cli.json → `UI.Init.Preferences.read/1` (E) → `Release.PersistedSession.start_preferences/3`
(`persisted_session.ex:1325`, B: pass every new field through into the launch map unchanged, like
`mouse?`) → `UI.Init`/`State` (D). Live changes from Settings keep using the existing
`{:terminal_preferences, …}` message (D extends its handler).

### 8.5 Terminal port wire (D owns `native/` and the Elixir owner)

BEAM→native tag 9 `Notify` (`generation, token, kind:u8, length:u16, bytes`), tag 10 `Redraw`
(`generation, token`); native→BEAM input kind 7 `Scroll` (`up:u8, count:u8`); Ready's flags byte
gains bit 128 `READY_ENHANCED_KEYS` (Init keeps rejecting it). Tags 1-8 are taken
(`protocol.rs:134-176`), so 9 and 10 are free. Unknown tags still reject.

## §9 Test strategy and gates

### 9.1 Lanes (focused only)

- One app per `mix test` call (`mise exec -- mix test apps/<app>/test/<file>.exs`), from the umbrella
  root of the worktree, with `MIX_QUIET` unset. Write each test first, see it fail, then fix.
- Use `start_supervised!/1`, monitors, `:sys.get_state/1`; no `Process.sleep/1` in tests, no
  remote API, no real database: fixture databases under `apps/swarm_code_daemon/priv/schema/fixtures`
  or `tmp_dir`, `LLM.Fake` and loopback servers only.
- Before the done commit: `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`,
  and, when you touched them, `mix swarm_code.keymap --check` (D), `mix swarm_code.settings --write`
  then `git diff --exit-code docs/settings.md` (E), `cargo fmt --check` + `cargo test --locked` via
  `scripts/dev/check_terminal_port.sh` (D), `mix swarm_code.provenance.verify` and
  `swarm_code.provenance.sync --check` (A, and C/E after a `repin`).

### 9.2 Goldens and generated files to regenerate

| Artifact | When | How | Owner |
| --- | --- | --- | --- |
| `apps/swarm_code_cli/test/fixtures/plain/three_run_output.txt` | plain output or the fake script changed | from `SwarmCodeCLI.Demo.Plain.run(:complete, …)` as its test documents | B (finisher re-checks after merge) |
| `docs/keybindings.md` | any binding | `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --write)` | D |
| `docs/settings.md` | any registry entry | `mise exec -- mix swarm_code.settings --write` | E |
| `apps/swarm_code_daemon/priv/schema/desktop-4c7c577.json` + fixtures | A3 | `generate_manifest.exs` with absolute paths | A |
| `_build/cell-previews/` | new scenes | `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.demo.cells)` (review, not committed) | E |
| `locked_branch_test` hashes (`rel/env.sh.eex`, test helper) | only if those files change (they must not) | — | — |

### 9.3 Finisher (after every done marker)

1. Branch `cli020/integration` from M1; merge `cli020/B`, `cli020/C`, `cli020/D`, `cli020/E` (in
   that order) = M2 and tell A it may branch `cli020/A2` from M2 (§4); when A2 is done, merge it. Resolve conflicts by ownership (§3); for
   `provenance/extracted-files.json` re-run `mise exec -- mix swarm_code.provenance.repin
   apps/swarm_code_core/lib/swarm_code/commands.ex
   apps/swarm_code_daemon/lib/swarm_code/daemon/service/command_dispatcher.ex` and any other frozen
   path A5 changed. Remove the stubs listed in the lane notes (§8.1, the `shell_message_role/0`
   flip). Append the lanes' AGENTS.md text; replace the worktree symlink recipe with §4.1.
2. Gates, in the integration worktree prepared per §4.1 (no `_build/prod`), one suite slot. If
   `locked_branch_test.exs` fails only there, the orchestrator re-runs that one file in the main
   checkout after it merges `cli020/integration` into `main`:
   `env -u MIX_QUIET mise exec -- mix precommit` (~15 min; format, warnings, unused deps, all
   tests, provenance verify, `sync --check`, `drift`, schema snapshot, Unicode);
   `scripts/dev/check_terminal_port.sh`; the four PTY suites one by one
   (`PYTHONDONTWRITEBYTECODE=1 python3 scripts/dev/test_terminal_port_pty.py`, `test_terminal_demo_pty.py`,
   `test_live_session_pty.py`, `test_saved_session_pty.py`); the plain demo golden;
   `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --check)`;
   `mise exec -- mix swarm_code.provenance.drift --strict` (expect 0 new migrations and 0 commits of
   drift against desktop `main` = Fm).
3. Release: `scripts/dev/build_release.sh` (its drift step must pass), then `rm -rf _build/prod`
   before any further `mix test`. Every run of the built release happens only inside the QA sandbox
   of 9.4 (sandbox `HOME` and `NCODE_CONFIG_DIR`); never against the real data folder. Under that
   sandbox: `LC_ALL=C <rel>/bin/ncode -p - --json < utf8_prompt.txt` prints valid JSON with the
   exact text; `printf 'héllo' | <rel>/bin/ncode -p -` is accepted; a 58-migration fixture database
   opens; a 59-migration one is refused with the version sentence (A4).
4. Desktop: F's `mise exec -- mix precommit` was green at Fm; the finisher re-runs only
   `mise exec -- mix test test/swarm_code/engine/policy_test.exs test/swarm_code/engine/approval_test.exs`
   in the F worktree if Fm differs from F's done commit.
5. Write `docs/research/2026-10-07-cli020-outcome.md`: what shipped per lane, deviations, test
   counts, open items. Commit `cli020: integration green`.

### 9.4 Live QA through the capture harness

Copy, never write into `~/.cache/ncode/p6`: `cp -cR ~/.cache/ncode/p6/tools ~/.cache/ncode/p6/c3
~/.cache/ncode/cli020/qa/` and `cp -cR ~/.cache/ncode/cli-review-1007/ux-live/driver.py
~/.cache/ncode/cli020/qa/`. In the copies set `RELEASE` to the 0.2.0 release extracted under
`~/.cache/ncode/cli020/rel/ncode-0.2.0/bin/ncode`, `BASE`/`HOME`/`SHOTS` to paths under
`~/.cache/ncode/cli020/qa/`, keep the CLEAN environment (sandbox `HOME`, `NCODE_CONFIG_DIR`,
`NCODE_MOUSE` unset so the new default shows, `TERM=xterm-ghostty COLORTERM=truecolor`), and the
fake server on `127.0.0.1` (`fake_server.py`; the port in the copy). Drive the TUI with GNU screen
or the copied `record_tui.py`, quit through the TUI's own quit path, kill only the fake-server pid
and the screen session you started. Scenarios (screenshot text into
`~/.cache/ncode/cli020/qa/shots/`): first run with no provider → Providers page (B12); read-only
project, a write → the `Ask` card with `y once · d deny` (F1, E14); Shift-Tab three times (D6);
`!git status` (C15, E15); a 60-line paste → chip (D8); `/rewind` → turn 2, "Conversation and
files" → the prompt back in the composer and the file restored (C16, D10); `/effort` picker (D18);
a provider 500 → `retrying 2/5 · HTTP 500` then one failure block and `r` retries (C5, C6, E12); a
focus-out (`stuff "\033[O"`) then an approval → BEL / `\e]9;` and `\e]2;` bytes in the `-L` log
(D3); activation bytes contain `?1007h` (D5); quit → the last turns and the `Spent` line in the
scrollback (B21); a queued prompt survives `/new` and `/resume` (C1); `/queue drop 1` (D20);
Ctrl-R in the composer finds an earlier prompt (D19); a fake run that calls `update_plan` shows
`Plan 1/3` (E29); `-p --output-format stream-json` lines decode (B23). Image paste (D9) is checked
by hand by the orchestrator in a real terminal (the harness must not write the user's pasteboard).

## §10 Assumptions

Each line: the claim; VERIFIED (what I read) or GUESSED (why); the surgical fix or check.

Verified:

- V1. CLI `main` is `c0808ea` and the annotated tag `v0.1.0` (`02ef4cd`) points at it. VERIFIED: `git log -1`, `git tag -l v0.1.0 --format`. Fix: none; A8 re-checks.
- V2. The CLI pin is `6dd8d82`. VERIFIED `provenance/sync-rules.json:3`, `core/governance/provenance.ex:5-10`. Fix: A1 adds the new pin.
- V3. Desktop `main` `4c7c577a` differs from 0.2.0 `68512b59` in 3 test files only. VERIFIED `git diff --stat 68512b59 4c7c577a`. Fix: sync to `4c7c577a`.
- V4. The desktop has 58 migrations; `20261018000001` only adds nullable columns. VERIFIED `ls priv/repo/migrations | wc -l`, the file's lines 7-18. Fix: A3 puts it in `forward_compatible`.
- V5. 34 ledger entries sit outside every mapping, all at `fb1b4ff8` (the report says 39; my filter excludes `domain/`, migrations and `priv/`). VERIFIED by listing `provenance/extracted-files.json`. Fix: A5 reviews all 34 and records the count it finds.
- V6. The schema contract and gate: `contract.ex:55-90` (`@current` 57, `forward_compatible` four versions), `foundation_gate.ex:24` (manifest source), `refusal.ex:13-21` (the database-ahead sentences). VERIFIED. Fix: A3, A4.
- V7. Desktop policy: `policy.ex:16-17` and `:31-32` deny read-only writes and commands; `operation.ex:291` calls `Policy.decide/3` with `current_mode/1` read per op (`:387-395`); `run_server.ex:960-1006` auto-approves remembered families before asking. VERIFIED. Fix: F1.
- V8. CLI cards offer only `allowed_decisions` from `pending_interactions.ex:92-95` (CLI-local file). VERIFIED. Fix: A'2.
- V9. `Conversations.supersede/2` folds one message and its run (`conversations.ex:886-975`); edit and resend lives in `workspace_live.ex:8242-8288` (web, not synced); `Checkpoints.restore_run_report/2` restores a run and every later run and writes a `swarm` message (`checkpoints.ex:582-600,654-690`). VERIFIED. Fix: F2 adds the multi-turn form; C16 reuses the rest.
- V10. `swarm` messages reach the model as `[Swarm report]` (`prompts.ex:559-560`); message roles are an inclusion list (`message.ex:47`). VERIFIED. Fix: F3 adds `shell`.
- V11. `a64d6ff6` (config.json protection) and `93b58ea6` (clone starts at HEAD) are on desktop `main`. VERIFIED `git merge-base --is-ancestor`, `git log`. Fix: A1 brings both; A5 ports `a64d6ff6` to the live copy.
- V12. Desktop MCP and LSP `clientInfo` say `ncode` `0.2.0` (`mcp/client.ex:40`, `lsp/client.ex:184`); the CLI copies say `SwarmCode`/`swarm-code` `0.1.0` (`domain/mcp/client.ex:29`, `domain/lsp/client.ex:121`). VERIFIED. Fix: A1 sync.
- V13. Finch 0.23.0 and Req 0.7.3 are locked in both repos. VERIFIED `mix.lock`. Fix: none (no new dependency for `LLM.HTTP.finch_child_spec/0`).
- V14. The CLI client app depends only on `stream_data` and `swarm_code_core` (`locked_branch_test.exs:16`). VERIFIED. Consequence: the client cannot call daemon modules, so the clipboard inbox path comes over the wire (C14).
- V15. `/attach` is confined to the project root (`command_dispatcher.ex:378-393`); attachments are capped at 6,000,000 bytes and 4 per message (`domain/attachments.ex:22-23`). VERIFIED. Fix: C14's inbox.
- V16. Shift-Tab is bound only outside the composer (`bindings.ex:279,492`); Ctrl-L and Ctrl-V are unbound (grep of `bindings.ex`). VERIFIED. Fix: D6, D9, D11.
- V17. The port sends `?1000h ?1006h` for the wheel and nothing for alternate scroll (`tty.rs:116-141`); its commands are init, credit, draw, shutdown, suspend, resume, copy, mouse (`protocol.rs:92-99`). VERIFIED. Fix: D3, D5, D11.
- V18. Mouse reports default on (`ui/init/preferences.ex:57`, registry `terminal.ex:222-233`). VERIFIED. Fix: E26, D5.
- V19. SIGINT cannot be trapped on OTP 28.4.2; SIGTERM and SIGHUP can. VERIFIED: `os:set_signal(sigint, handle)` → `badarg`, the other two → `ok`. Fix: B9 traps only those two.
- V20. `-p` auto-denies approvals with one line each and stops after 8 (`one_shot.ex:433-470`); `read_prompt/1` uses `IO.binread` (`release.ex:346-357`); the env loader returns early on any exported key (`load_provider_env.sh:32-34`); the exit summary is built by SQL (`persisted_session.ex:700-790`). VERIFIED. Fix: B3, B1, B14, B21.
- V21. `/consensus <task>` persists the mode (`command_dispatcher.ex:264-274`); the engine reads `conversation.consensus` from the struct it is given (desktop `engine.ex:97`). VERIFIED. Fix: C7.
- V22. Retries already write `status: "retrying"` and `detail: "retrying n/N · reason"` on the llm op node (`domain/engine/operation.ex:170-174`); the client has the `{:retry_run, …}` intent (`ui/intent.ex:70`) and no backend handler. VERIFIED. Fix: C5, C6.
- V23. The desktop's Ultra is missions (`tools.ex:180`, `prompts.ex:74-87`, `tools/mission_start.ex`). VERIFIED. Fix: A6.
- V24. The desktop's `application.ex`, `bootstrap.ex`, `quit.ex` changed by +198/−22 since the pin and are excluded from the sync. VERIFIED `git diff --stat`. Fix: A2.
- V25. `runs` carry `tokens_in`, `tokens_out`, `cost_usd` (desktop `conversations/run.ex:21-23`). VERIFIED. Fix: B21's SQL.
- V26. `/usr/bin/osascript`, `/usr/bin/pbcopy` and `/usr/bin/sips` exist on this Mac. VERIFIED `ls`. Fix: none.

Guessed (each has a check in the named task):

- X1. `osascript -e '… write (the clipboard as «class PNGf») to f …' <path>` writes the raw PNG bytes, and the UTF-8 chevrons pass through `-e` unchanged. GUESSED: the usual recipe; not run, because running it reads the user's pasteboard. Fix: D9's injected-runner tests plus the orchestrator's manual check; if it fails, use `«class TIFF»` + `sips` only.
- X2. `sips -s format png` converts the clipboard's TIFF. GUESSED (standard tool, not run on clipboard data). Fix: the same manual check.
- X3. iTerm2, ghostty and WezTerm show OSC 9 as a notification; `CSI 22;2 t` / `CSI 23;2 t` save and restore the title. Ghostty's OSC 9 is VERIFIED (ghostty.org/docs/vt/osc/9, critic, plus its ConEmu `OSC 9;n` overlap, handled in D3); iTerm2/WezTerm and the title stack stay GUESSED. Fix: `auto` falls back to BEL elsewhere, `terminal.notify off` and `terminal.title off` exist; QA checks ghostty.
- X4. Terminals honour `CSI ? 1007 h` and send several arrows per notch. GUESSED. Fix: D5's burst rule; `/mouse on` for terminals that send one arrow; §11 Q1.
- X5. The kitty protocol query is answered `CSI ? <flags> u`, and support is detected by sending DA1 after it. VERIFIED (critic): sw.kovidgoyal.net/kitty/keyboard-protocol, "Detection of support for this protocol". Fix: D2 as rewritten.
- X6. `Tools.RunCommand.run/3` works for a user command with `run_id: nil`. Partly VERIFIED (critic): the signature is `run(args, ctx, progress)` (`run_command.ex:180`), there is no `timeout` arg (`timeout_for/2`, 166-174), and a command still running after `yield_ms` (default 10 s) is handed to `BackgroundProcs` under `ctx.run_id`; the task traps exits to kill the OS process (262-263). GUESSED: that `terminate_child` kills the whole tree. Fix: C15 passes `yield_ms: 120_000` and its `sleep 30` stop test checks the child is gone.
- X7. `Checkpoints.restore_run_report/2` still finds the turn after `supersede_from/2` marked its run superseded. VERIFIED (critic): `for_conversation/2` numbers turns over `Conversations.list_runs/1`, which has no `superseded_at` filter (desktop `conversations.ex:1407-1411`, `checkpoints.ex:436-470`). Fix: none; C16's order stands.
- X8. Rewinding to before a `compact` message gives the model the full history again. VERIFIED (critic): `compact_floor/1` only counts compact rows with `is_nil(superseded_at)` (desktop `conversations.ex:754-760`). Fix: keep C16's compact-row test.
- X9. The headless hint's `ncode config set project.approval_mode auto --project <DIR>` syntax. GUESSED. Fix: B3 copies the real syntax from `config_command.ex`.
- X10. Presets carry a default model. VERIFIED FALSE (critic): `Settings.Registry.Actions.provider_presets/0` has no model field. Fix: B13 returns `:model_required` without `NCODE_MODEL`.
- X11. The DTO module names. VERIFIED (critic): `DTO.RunSummary`, `DTO.Approval`, `DTO.AgentSummary` (has `turn`, `max_turns`, `cost_usd`), `DTO.WorkspaceSnapshot` and `DTO.WorkspaceMetadata` ("workspace snapshot": both carry `queued_texts`), `DTO.ConversationSummary`/`DTO.ConversationList` ("conversation row"); the transcript item module is not named here. Fix: C adds the fields to both workspace DTOs and names the transcript item module in `notes/C.md`.
- X12. `locked_branch_test.exs` passes in a worktree whose `deps`/`_build` are APFS clones. GUESSED (AGENTS.md names only symlinked `deps` and `_build/prod`). Fix: A runs it first in its worktree and records the result; if it fails, §9.3 step 2's fallback.
- X13. `Conversations.set_queued/2` replaces the queued list. VERIFIED (critic): `dmn/domain/conversations.ex:935-945` updates `queued` and broadcasts; it has no compare-and-set, so C1 does the compare inside its own IMMEDIATE transaction.
- X14. The Lead's report is drawn twice because the run report item and the Lead's last reply both become items (report A8). GUESSED. Fix: E10 finds the duplicate first.
- X15. The sync conflicts stay inside the 14 patched files. GUESSED (report A18). Fix: A stops and writes `notes/A.md` on any conflict elsewhere.
- X16. The signed desktop detector is cheap enough to run every 10 s. GUESSED. Fix: C4 measures one probe; if it takes over 1 s, poll every 30 s.
- X17. The CLI manifest JSON lists migrations with a `version` per entry. VERIFIED (critic): `desktop-6dd8d82.json` top keys `manifest_version, contract, upstream_commit, …, migrations`, each migration `{version, filename, source_sha256, schema_sha256, additive_desktop_readable}`. Fix: F6 parses `migrations[].version`.
- X18. The help column is about 2 cells too wide (report A9). GUESSED. Fix: E7 asserts the width.
- X19. `IO.read(:stdio, n)` on a unicode device counts characters, so the byte bound needs the extra `byte_size/1` check. GUESSED from the IO docs as I remember them. Fix: B1 keeps the `byte_size` check either way.
- X20. The desktop approval card can see the project's approval mode in its assigns. GUESSED. Fix: F1 passes it in if not.
- X21. `System.trap_signal/3` handlers and the Rust port's own signal guard do not race on SIGHUP. GUESSED. Fix: B9 plus a `test_saved_session_pty.py` case that sends SIGTERM and asserts the terminal is restored and the summary printed.
- X22. The client never needs the desktop's mission UI because A6 keeps `mission_start` out of CLI Ultra. VERIFIED (critic): the desktop's `Workflows.list/1` already hides the builtin `mission` (`workflows.ex:31-48`), so no exclusion is needed. Fix: A6's test asserts it.
- X23. Moving "Switch run" off Ctrl-R in the composer (D19) is acceptable. GUESSED (the owner did not decide it; Claude Code and readline use Ctrl-R for history). Fix: §11 Q8.
- X24. `ESC b`/`ESC f` reach the keymap as `{:key, "b", [:alt]}`. GUESSED (not traced through `input.rs`). Fix: D1 checks first and routes whichever form arrives.
- X25. E27's desktop palettes all reach E23's contrast floors. GUESSED. Fix: E27 raises a palette's faint/ghost to the floor and lists it.
- R1. A's sync is large (≈110 files, 14 patches, `run_server.ex` heavily patched). Mitigation: A
  runs alone, stops on conflicts outside the patched files, and nothing else starts before M1.
- R2. A' depends on F reaching desktop `main` (Fm). If F slips, B..E still merge; the finisher waits
  for A2. C16/C15 stubs (§8.1) keep their tests green meanwhile.
- R3. Read-only now waits on cards in workflows and swarms of untrusted projects (10-minute
  approval timeout). That is the decided behaviour; docs (G2) say so.
- R4. `install.sh` cannot ship until the 0.2.0 tarball exists; G1's placeholder refuses to run, so
  a premature deploy cannot install the wrong build.

Owner questions (each has a default the lanes follow unless the owner says otherwise):

- Q1. Alternate scroll in a terminal that sends one arrow per wheel notch walks the prompt history
  instead of scrolling. Default: accept, document it, `/mouse on` restores wheel reports.
- Q2. Keeping CLI Ultra on workflows needs two CLI-only provenance patches (A6: `tools.ex`'s Ultra
  branch and `prompts.ex`'s `@ultra` plus one rules bullet); no sync exclusion (the desktop already
  hides the builtin mission from lists). Default: yes, until the missions pass.
- Q3. (Rewritten by the critic.) The findings that are in neither decision 4 nor decision 6 are now
  planned (§7.15) because only decision 6 defers: competitors-4's other flags (B23, F8),
  competitors-10 (F9, A'4, C23, E30), competitors-11 (F10, C23, E30), competitors-14 (F11, C23,
  E29), competitors-19 (C20, D19), competitors-20's items (C22, E28), competitors-21 (E27),
  tui-code-14's `/delete` and `/fork` (C11), tui-code-17 (D21, E31). Default: build them.
- Q4. The desktop's `/consensus <task>` stays sticky (only the CLI becomes one-shot, Q7). Default:
  no desktop change this pass.
- Q5. Shift-Tab changes the project's approval mode, which the desktop and other conversations of
  the project share (it is what `/approval` does today). Default: yes, and the notice says
  "(this project)".
- Q7. Cut list if the pass is too big: E31+D21 (perf, needs the fixture), E27 (palettes), F10
  (permission rules: new safety surface), F11+E29 (plan tool), in that order. Default: keep all.
- Q8. Ctrl-R in the composer becomes history search (D19); "Switch run" keeps Ctrl-R everywhere
  else and in Ctrl-P. Default: yes.
- Q9. Two frozen ledger files are hand-edited outside lane A: `core/commands.ex` (E) and
  `service/command_dispatcher.ex` (C). They are under no sync mapping, so a sync never overwrites
  them, and AGENTS.md prescribes `repin` for exactly this; the finisher re-runs `repin` on merge.
  Default: keep (the alternative, A owning every edit to them, serialises C and E behind A).
- Q6. bugs-6's desktop side (the desktop warns when a CLI session holds the database) needs a
  cross-app lease the desktop does not have. Default: CLI-side poll and banner now (C4); the
  desktop side goes with the multi-client pass.
- Orchestrator (2026-10-07): the defaults of Q1-Q9 are taken, and `ncode -p --approval <mode>`
  (B23, F8) exists as designed (per run, in memory, refused for `auto`/`full_access` in an
  untrusted project). The owner may override any of them at review; lanes build the defaults.

## Critique log (adversarial critic, 2026-10-07)

Checked against CLI `c0808ea` and desktop `4c7c577a` (read-only). Coverage: a `python3 -I` check
of §5 against `findings.json` `kept` finds 106 rows, 106 distinct ids, none missing or extra.
Every change below was made in place; "evidence" is what was read.

Coverage and deferrals

1. §5 rows 12, 16, 17, 52, 55, 56, 57, 86, 88 and the count line: nine findings were deferred for
   "not in decision 4" or "scope", which is not a decision-6 reason. They are now planned (B23,
   C11, C20, C22, C23, D19, D21, E27-E31, F8-F11, A'4; §7.15) and the six remaining deferrals
   are all decision 6. Owner cut list: §11 Q7.

Ownership

2. §3: `ui/reducer/settings.ex` matched D's `ui/reducer/*.ex` and was edited by E24: now E's.
3. §3 F row: F1's card has three caller files (`chat.ex:3087,3151`, `side_chat.ex:937,1066`,
   `swarm_pane.ex:4198`) and needs `conversations/node.ex`; F8-F11 need `engine.ex`, `hooks.ex`,
   `project_config.ex`, `quit.ex`, `tools.ex`, `tools/update_plan.ex`, `engine/rules.ex`.
4. §3 hot spots rewritten. The old row said D needs `client?/1` true for bare `/effort`, but
   `Commands.client?/1` takes only a name (`commands.ex:115`) and the daemon, not the client,
   parses slash commands (`command_dispatcher.ex:84-99`); client-local commands live in
   `Keymap.local_command/1` (`keymap.ex:182-197`). Added owners/interfaces for `keymap.ex` +
   `bindings.ex`, `slash_palette.ex`, `composer.ex`, `State.panel_mode` + Ctrl-B, the
   `persisted_backend.ex` and `plain/**` hot spots, and the preferences hand-off through B's
   `start_preferences/3`.
5. Frozen ledger files (`core/commands.ex`, `service/command_dispatcher.ex`) stay hand-edited by
   E and C with `repin` (AGENTS.md's sanctioned path; no sync mapping covers them, so no sync
   overwrites them). Recorded as owner question Q9 rather than silently accepted.

Order

6. §4 / §9.3: A2 branched "from M1 if B..E are still open", but A'3 calls C2's
   `CommandLedger.staged_attachment_ids/0`, which does not exist at M1 (compile error). A2 now
   branches from M2 (B..E merged); A'1/A'2 may start from M1 only if C slips.

Code accuracy (each VERIFIED by reading the file; wrong ones fixed)

7. B5: the JSON text is built at `one_shot.ex:705`, not 727.
8. B13 / X10: presets (`core/settings/registry/actions.ex:8-60`) have no model field, so "the
   preset's default model" cannot exist; `:model_required` instead.
9. B14: there is no loader copy in `rel/overlays`; `build_release.sh:20` copies it.
10. B18: preset matching is `preset_attributes/1` (`settings/providers.ex:1059-1072`), exact id.
11. C1: `/queue <text>` is already client-local (`reducer.ex:2917-2941`); making `/queue clear`
    a core command would conflict. Redesigned as D20 local commands plus a `queue.edit` op with a
    full-text revision CAS, because `set_queued/2` has no CAS (`conversations.ex:935-945`) and the
    client only holds 2 KB copies (`workspace_snapshot.ex:56`). `init/1` is at line 70, not 157.
12. C6: the desktop's `retry_run/2` (`workspace_live.ex:8153-8178`) also has a chat fallback on
    `run.prompt`; added. No daemon op carries `{:retry_run, …}` today: wire registration listed.
13. C7: `persist_mode/2` writes `mode: "build"` too (`command_dispatcher.ex:834-840`); the
    overlay now sets it, like the `/plan <task>` overlay at 255-256.
14. C9: `/workflows` is a navigation (348-349); the raw JSON comes from
    `feature_catalog.ex` `query_rows(:workflows, …)` (588-600, `definition(w)`).
15. C11: real functions named: `Conversations.rename/2` (389), `delete/1` (488), `fork/2` (808).
16. C14 / §7.9 / §8.1: the module is `SwarmCode.Domain.Paths`, not `SwarmCode.Paths`; tests must
    set `:domain_config_dir` (`paths.ex:9`) so no test touches the real data folder.
17. C15: `RunCommand.run/3` is `run(args, ctx, progress)`; there is no `"timeout"` argument
    (`timeout_for/2`, 166-174); without `yield_ms` a 10 s+ command yields to `BackgroundProcs`
    under a nil `run_id` (G25, 685-692). Fixed args; stop = `terminate_child` (the task traps
    exits, 262-263).
18. C16: `turn` numbering and `files` now come from `for_conversation/2` (`checkpoints.ex:436-470`);
    steers excluded (`launched_run_id/2`, desktop 942-948); restore semantics corrected (earliest
    snapshot per path, not "newest first"); `files` scope returns no text.
19. C18: `/cost` already runs a per-model grouped query (`command_dispatcher.ex:519-553`); the
    "synced usage queries" detour is removed.
20. D1: `movement/2` is only reached for arrow/home/end codes (`keymap.ex:413-425`), so Alt-b/f/d
    must be matched in `editor_fallthrough/3`; the binding group is `:edit` (there is no `:editing`).
21. D2: Ready's flags are validated against `FLAGS` (`protocol.rs:15,375`) and bits 32/64 are guard
    bytes, so "the next free bit" was undefined: `READY_ENHANCED_KEYS = 128`. Kitty detection via
    DA1 VERIFIED on the protocol page; added `CSI 27 u`/Ctrl-C/Alt mapping and suspend pop.
22. D3: OSC 9 VERIFIED for ghostty (ghostty.org/docs/vt/osc/9) with the ConEmu `OSC 9;n` overlap,
    so texts must not start with a digit; the 2 s bell rate limit of §7.7 moved into D3.
23. D5: mouse inputs are `{:mouse, kind, button, column, row, modifiers}` with required positions
    (`input.ex:102,180`); the proposed `{:mouse, {:wheel, …}}` shape is invalid. New
    `{:scroll, dir, count}` input.
24. D6: Shift-Tab arrives as `BackTab` (`input.rs:598`); existing rows at `bindings.ex:277-286,
    490-499` exclude `:composer` (VERIFIED); group `:session` named.
25. D13: there is no `state.prefs`; `Preferences` reads five legacy keys (`preferences.ex:55-71`),
    so the four settings never reach `State`. Flow added (§8.4).
26. D14: today's command keeps `2>&1` (`session_runtime.ex:511`); the new one dropped it.
27. D18 / §7.6: fixed rows "low … max" can offer levels the parser refuses (`commands.ex:200-224`
    checks `opts[:efforts]` from `command_dispatcher.ex:103-111`); rows now come from the DTO.
28. E3: `/queue` removed from core (see 11); `client: true` removed (see 4); `:show_effort`,
    `/delete`, `/fork` added; palette rows go to `slash_palette.ex` `@local` (line 47 has `queue`).
29. E9: the switcher already offers "Retry failed run" (`switcher.ex:385,573`); copy aligned.
30. E23: the report's `0x7A7977` is 4.04:1 on `0x191919` and 3.83:1 on the card `0x1E1E1E`
    (computed), below the 4.5 floor the task asserts; now `0x868583` (4.77/4.52).
31. E26: `terminal.wheel_lines` says "Only when Wheel scrolling is on" and `keys_input.ex:43`
    hides it with the mouse off; with alternate scroll it applies always.
32. E31: `prose_rows/4` gets no item id (`turns.ex:1741`); the cache key is a content hash.
33. A3: renaming today's `@current` and adding the new version to `snapshot_versions`
    (`contract.ex:60-90`) were missing.
34. A6: the CLI's rules bullet already ends "…or turned Ultra mode on." (`prompts.ex:179`); the
    desktop's replacement (desktop `prompts.ex:191`) forbids exactly what CLI Ultra does, so the
    patch keeps the CLI text. The `mission.exs` exclusion is dropped: `Workflows.list/1` already
    hides the builtin mission (desktop `workflows.ex:31-48`) and the mission tests need the file.
35. A1: the test mapping is the 7th mapping's `files` list (24 entries); a DataCase caveat added.
36. F1: the desktop card's pills are "Approve", "Deny", "Deny & stop", "Allow all <tool> this
    run" and `Always allow "<prefix>"` (`chat.ex:764-815`), not "Allow for this run"; the card
    reads a node virtual field (like `approval_prefix`, `node.ex:69`) instead of a guessed project
    assign; the LiveView test path follows the desktop AGENTS.md (`test/swarm_code_web/live/`).
37. F1 table VERIFIED: after deleting `policy.ex:16-17` and changing 31-32, read_only `:execute`
    `:dangerous` hits line 19 (ask), `:safe` falls to 31 (ask), `:write` to 31 (ask).
38. F2: `supersede_scope/3` also folds messages by `reply_to_run_id`; legacy rows go through
    `legacy_run_id/2`. Added.
39. Spot checks that were already right (no change): `release.ex:346-357` `IO.binread`;
    `one_shot.ex:40,433-470,481-506`; `headless.ex:41-61,184-187`; `persisted_session.ex:179-186,
    294-313,700,759,1034-1075,1277,1325`; `plain/command.ex:68-85`; `command_ledger.ex:49-60`;
    `persisted_backend.ex:1238,1415-1425,2004-2022`; `domain/engine/operation.ex:172-173`;
    `intent.ex:70`; `request.ex:430`; `command_dispatcher.ex:264-274,331-345,555-585`;
    `values.ex:232-240`; `tty.rs:116-141`; `protocol.rs:14-20,134-176`; `effect.ex:15-17,77-83`;
    `reducer.ex:795-797`; `state.ex:141,176`; `hint.ex:22`; `capabilities.ex:34`;
    `preferences.ex:57`; `registry/terminal.ex:119-128,222-247`; `theme.ex:62-68`;
    `model_picker.ex:60,65`; `dialog.ex:883-885,1043,1322`; `turns.ex:826-838`; `commands.ex:8,21,
    23,30,49`; `foundation_gate.ex:24,466`; `refusal.ex:13-21`; `contract.ex:60-98`;
    `domain/attachments.ex:22-25,298`; `paths.ex:18`; desktop `policy.ex`, `operation.ex:285-325,
    387-395`, `run_server.ex:189-195,960-1006,1817-1855,4900-4930`, `conversations.ex:886-966,1068,
    1137,1407`, `checkpoints.ex:433-690`, `prompts.ex:552-568`, `message.ex:47`,
    `attachments.ex:374`, `mcp/client.ex:40`, `lsp/client.ex:184`, `engine.ex:92-103`,
    `workspace_live.ex:3428,8153,8261-8288`, `application.ex:43-63`, migration 58 (additive),
    `sync-rules.json` (7 mappings, `exclude`), 34 frozen ledger entries, desktop CHANGELOG (pass 71
    is the newest numbered engine pass, so 72 is free).

Feature designs (§7)

40. Rewind (7.8, C16) verified against the domain: `list_runs/1` keeps superseded runs (X7),
    `compact_floor/1` skips superseded compacts (X8), the "Rewound…" message is written after the
    supersede so it survives; steers are not rewind points; the draft is replaced undoably.
41. Image paste (7.9, D9, C14): no new dependency confirmed (`osascript`, `sips` exist, V26);
    binding detail, chip size field (`bytes`) and the test config dir added.
42. `!cmd` (C15): yield and stop mechanics fixed (17); `/queue` (C1/D20), `/effort` (D18/D20),
    rewind and undo (D10/D20) now name the local-command path the TUI really uses.
43. §7.15 added for the newly planned findings; §8.1-8.5 list every new function, op (with the
    four places each wire op must be registered), DTO field, layer, input and state field.

Test commands and recipes

44. §4.4 now says `env -u MIX_QUIET mise exec -- mix test <file>`, one app per call, from the
    umbrella root (AGENTS.md test gotchas); §9.1 already did. `cp -cR` clones keep `deps` a real
    directory (the `locked_branch_test` symlink gotcha); X12 stays GUESSED with its fallback.

Owner decisions

45. Checked and honoured: one 0.2.0 release (§1, §2, A8, G1); read-only asks in both apps (F1 →
    A'1/A'2, B3 headless, B22 verbs); all nine features (D3, D6, D7/C15, B21, D8, D18, B21, C16/D10,
    D9/C14); mouse off by default with `?1007h` (D5, E26); `/consensus <task>` one-shot (C7, now
    with `mode: "build"`); `/ultra` relabel (E2, A6); Worker/Validator words (E1, C17).

Assumptions and questions

46. §10: X3, X5, X6, X7, X8, X10, X11, X13, X17, X22 resolved with evidence; X23-X25 added.
47. §11: Q2 and Q3 rewritten; Q7 (cut list), Q8 (Ctrl-R), Q9 (frozen ledger edits) added.
