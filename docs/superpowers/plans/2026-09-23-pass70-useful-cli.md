# Pass 70: a CLI you can use every day (2026-09-23)

Owner's words: "make ~/dev/swarm-code-cli cli version of this app actually beautiful and useful, its
practically useless now".

Three Opus 5.5 audits ran on 2026-09-23 against HEAD cd0b1e8 in sandboxed copies of the prod DB:

- reliability: [docs/research/2026-09-23-audit-reliability.md](../../research/2026-09-23-audit-reliability.md) (findings `rel F1…F17`)
- experience and design: [docs/research/2026-09-23-audit-experience.md](../../research/2026-09-23-audit-experience.md) (findings `ux F1…F18`, redesign moves `M1…M14`)
- engine parity and architecture: [docs/research/2026-09-23-audit-architecture.md](../../research/2026-09-23-audit-architecture.md) (findings `arch F1…F17`)

Read the audit sections your tasks cite before you change code: they carry the evidence, the
root causes with file:line, and the before/after sketches. Their scratch artefacts (captures, repro
scripts, the sync experiment, the VT emulator) are under `/private/tmp/p70cli/{rel,ux,arch}/`.

## 1. What is wrong, in one screen

1. It dies. A killed DB client crashes a guarded connection and pins a native handle, so the
   session closes and cleanup never finishes (rel F1, the owner's first-prompt crash). A long
   transcript in a big terminal overflows the 4096-node paint budget and the draw error kills the
   session and its runs (rel F3, ux F2: Ctrl-R/Ctrl-G on a real conversation). 1-second tripwires
   close the session on any stall (rel F4). The port can outlive the session (rel F17).
2. It cannot finish a coding turn. Every real approval is rejected (op node id vs agent node ids,
   rel F2 / ux F1), so any shell command hangs the run until `/stop`.
3. It is two weeks behind. The domain is a namespace-renamed copy of desktop pass 53 (fb1b4ff);
   the desktop is at 6dd8d82 (pass 69, 334 commits, ~14k lib lines: shell rewrite, edit tools,
   compaction, command families, agent definitions, mailboxes, isolation, LSP, hooks, trust). The
   schema pin fails closed the moment the owner installs the desktop at HEAD (rel F10, arch F2).
4. It corrupts desktop data and leaks secrets. Every launch writes plaintext-keyed "CLI …" provider
   rows and rewrites the resumed conversation's model (arch F4); the whole `~/.secrets` (GitHub,
   npm, Linear tokens) reaches every model-run shell command (rel F5); the global dir differs from
   the desktop's and is baked at build time (arch F8).
5. It does not read like a conversation or look like SwarmCode. Tools hoisted above text,
   `thinking` rows, markdown and code as prose, no diffs, chrome eats 10 of 24 rows, the screen
   leaks ids and cue prefixes, letters become commands after one Esc, Ctrl-C ends the session,
   ~690 KB of output per repaint (ux §2–§3).
6. It is one conversation, one session, no headless mode: no list/new/switch (arch F7), a fixed
   Erlang node name (rel F7), no `-p`/`--plain` in the release (rel F9), stack traces with exit 0
   (rel F8).

## 2. Decisions (taken by the orchestrator; do not relitigate)

- D1 Engine: re-sync the domain to desktop **6dd8d82** now, with a repeatable
  `mix swarm_code.provenance.sync` (arch option a, §2.2–2.3). Path dependency rejected, attach to a
  running desktop deferred. `~/dev/swarm-code` stays read-only: read it with `git -C ~/dev/swarm-code
  show <ref>:<path>` / `git ls-tree`, never check out, stash, build or edit there.
- D2 Schema: re-pin to 57 migrations (6dd8d82) with an explicit `forward_compatible` allowlist of
  the four pending versions (arch §2.4). A 53-DB is backed up by the existing gate and migrated; a
  pending migration outside the allowlist, or a DB ahead of the manifest, is refused with one human
  sentence ("Open the SwarmCode app once to upgrade the database").
- D3 Providers: the DB's providers and the conversation's own choice are the default, exactly like
  the desktop (`Providers.effective_model/2`). Environment variables never create provider rows
  and never rewrite a conversation. `swarmcode --model <model|provider/model>` is a deliberate
  session override (env `SWARM_MODEL_OVERRIDE`, set only by the launcher flag). Only when the DB
  has no usable provider at all may the launcher create one row from `SWARM_*` (first-run
  onboarding), and it says so on screen. The launcher loads only provider variables from the env
  file, never the whole file.
- D4 Approvals: the project's approval mode and trust are the desktop's (read-only / auto / full,
  trust from pass 63). The mode is always visible on the status line; `/approval` changes it; the
  approval appears in the composer slot with `y once · Y this run · A always "<family>" · d deny ·
  D deny & stop · n next`.
- D5 Keyboard: composer-first (ux M2). Letters always type. Esc interrupts a streaming turn or
  closes the top layer and never moves focus. Ctrl-C clears the draft, else interrupts the turn,
  and a second Ctrl-C within 1.5 s quits. Quitting with live runs asks "Stop N live runs and quit?".
  `q` quits only from select mode and pickers. Ctrl-T enters select mode. No Ctrl-K, nothing
  essential on Alt (AGENTS.md).
- D6 Looks: follow the desktop's visual grammar with UI.Theme tokens only; default canvas = the
  terminal's own background; cue text prefixes only in monochrome/NO_COLOR; no ids or UUIDs on
  screen; one title/tab row and one status line of chrome.
- D7 Runs are owned by the session (unchanged); the exit text says what happened and prints a
  resume hint to the main screen after the alternate screen closes.

## 3. Rules for every owner

- Work only in your worktree `/Users/zaali/dev/swarm-code-cli-wt/p70-<X>` on branch `p70/<X>`
  (created from main with this plan committed; deps and `_build/{dev,test,terminal-port,…}` are APFS
  clones, not symlinks). Never touch `/Users/zaali/dev/swarm-code-cli` itself, the other owners'
  worktrees, or the older worktrees under `~/dev/swarm-code-cli-worktrees/`.
- Edit only the files in your set (§4). If you need a change in someone else's file, do not make it:
  write the exact request in your notes file and code against the agreed contract. Exceptions are
  listed per owner.
- Toolchain: `mise exec -- mix …` from the worktree root; `scripts/dev/check_terminal_port.sh` for
  Rust. Unset `MIX_QUIET`. Iterate with focused tests; run the full umbrella `mise exec -- mix test`
  at most twice (it takes ~15 min and four other owners are compiling). `ui/renderer/locked_branch_test`
  fails whenever `_build/prod` exists; that one failure is expected after you build a release.
- Before each commit: `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, the
  focused tests you touched. Commit small, message `pass70 <X><n>: <what>`, ending with the trailer
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Never push.
- Provenance: only owner A writes `provenance/extracted-files.json`. If you edit a file listed there,
  name it in your notes; the finisher re-pins.
- Real sessions only in a sandbox HOME, never the real DB under `~/Library/Application Support/SwarmCode`:

  ```sh
  N=p70-<X>; SB=/private/tmp/p70cli/$N/home; mkdir -p /private/tmp/p70cli/$N
  cp -c -R /private/tmp/p70cli/sandbox-home "$SB"
  chmod 700 "$SB" "$SB/Library" "$SB/Library/Caches" "$SB/Library/Application Support" "$SB/Library/Application Support/SwarmCode"
  scripts/dev/build_release.sh     # in your worktree → _build/prod/rel/swarm_code_cli
  HOME=$SB SWARM_ENV_FILE=/Users/zaali/.secrets _build/prod/rel/swarm_code_cli/bin/swarmcode <project>
  ```

  `/private` matters (the gate rejects the `/tmp` symlink). The sandbox DB is a copy of prod at 53
  migrations. For prompts that write, use a scratch copy: `cp -c -R ~/dev/ailogic
  /private/tmp/p70cli/$N/ailogic` (never write inside `~/dev/ailogic`). At most 10 real prompts per
  owner (provider from `~/.secrets`: llmotions, deepseek-v4.1-flash). Never print keys. Never run
  `scripts/install.sh`.
- Drive the TUI with GNU screen as AGENTS.md says (`-X stuff $'\r'` for Enter, `$'\033'` for Esc,
  hardcopy with `LC_ALL=C`; the raw-log VT emulator `/private/tmp/p70cli/ux/vt.py` renders true
  glyphs and colours to PNG). Quit with the app's own quit path before closing screen; close every
  screen session you start; kill only pids you started.
- Hand-off notes: keep `docs/superpowers/plans/pass70-notes/<X>.md` current in your branch: what
  landed (task ids + commits), contracts you publish or consume, requests for other owners,
  manifest-listed files you edited, what you verified and how, what is left.

### 3.1 Sync points (git tags, shared by all worktrees)

- `p70-A-sync` — A tags the commit where the synced domain, the 57-migration schema and the
  allowlist compile with `--warnings-as-errors` and the schema tests pass. B and C must
  `git merge --no-edit p70-A-sync` before the tasks marked "after A-sync".
- `p70-C-wire` — C tags the commit where the DTO/wire additions of C1 compile, round-trip and
  exist in the fake data source. D and E merge it before the tasks marked "after C-wire". Until
  then read new DTO fields with `Map.get(dto, :field, default)` so your code compiles either way.
- Wait for a tag with `until git rev-parse -q --verify refs/tags/<tag> >/dev/null; do sleep 30; done`
  inside one Bash call with a 10-minute timeout, repeated as needed; do other tasks first.

## 4. Owners, file sets, tasks

Priorities: **P0** must land this pass; **P1** should land; **P2** only if P0/P1 are done.

### Owner A: engine sync and schema

Files: `apps/swarm_code_daemon/lib/swarm_code/domain/**` except `runtime.ex`, `notifications.ex`,
`paths.ex`, `pub_sub.ex`, `feature_catalog.ex`, `html.ex`;
`apps/swarm_code_daemon/priv/{domain_repo/migrations,agents,workflows,skills,schema}/**`;
`apps/swarm_code_daemon/lib/swarm_code/daemon/schema/**`; in `daemon/foundation_gate.ex` only the
manifest source and the allowlist decision; `provenance/**`;
`apps/swarm_code_core/lib/mix/tasks/swarm_code.provenance.*.ex`,
`apps/swarm_code_core/lib/swarm_code/governance/**`; `apps/swarm_code_daemon/mix.exs`; root
`mix.exs` (precommit alias only); tests under `apps/swarm_code_daemon/test/swarm_code/{domain,daemon/schema}/**`,
`foundation_gate_test.exs`, `apps/swarm_code_core/test/**/provenance*`.

- A1 P0 `mix swarm_code.provenance.sync --upstream <path> --ref <sha> [--check]` per arch §2.3 with
  `provenance/sync-rules.json` (the seven ordered rewrite rules of arch §2.2, include/exclude sets,
  path mapping), read-only `git show`/`git ls-tree`, `mix format`, 3-way merge of CLI-patched files
  stopping on conflict, manifest update; `--check` re-derives and fails on drift; add it to the
  precommit alias.
- A2 P0 Run it to 6dd8d82: all of `lib/swarm_code/**` minus the desktop-only files
  (`application.ex`, `bootstrap.ex`, `desktop*.ex`, `quit.ex`, `tray_menu.ex`, `menu_bar.ex`, and any
  other web/desktop-only module you find), plus `priv/agents/**`, `priv/workflows/**`. Merge the 14
  CLI-patched files. Keep `RunServer.answer_question/5` and `pending_interactions/1`, and extend
  every approval row of `pending_interactions/1` with `tool`, `command`, `cwd`, `reason`,
  `command_family` and `classification` (from `CommandSafety`), `permission`, `requested_at`. Freeze
  and document that shape in your notes (C consumes it).
- A3 P0 Add the four migrations with provenance entries; `Schema.Contract` entry for 6dd8d82 (57);
  regenerate the manifest with `priv/schema/generate_manifest.exs` (absolute `--output` and
  `--fixtures-dir`); point the gate at it; bump pinned counts (arch §2.4).
- A4 P0 `forward_compatible` allowlist (arch F15, §2.4 "what must not happen"). Tests: 53-DB →
  backup → 57; 57 ready; unknown 58th refused; non-allowlisted pending refused; DB ahead refused.
- Tag `p70-A-sync` when A1–A4 compile and the schema/gate tests pass. In your notes list every
  process, supervisor, registry, ETS owner and `Application.get_env(:swarm_code_daemon, …)` key the
  synced domain needs at runtime (compare the desktop's `application.ex:31-66` and `bootstrap.ex`), so
  B can start them.
- A5 P1 Port the pure upstream unit tests (command_safety, fuzzy_match, context hysteresis, edit_file
  fuzzy, ripgrep fallback, lsp language URIs) through the sync tool as provenance test entries.
- A6 P1 Loopback-HTTP engine regression: one test that runs a saved-mode chat turn through the synced
  engine against the existing loopback provider server, with a tool call (`run_command` with
  `yield_ms`, then `edit_file`), proving the synced domain works under the guarded Repo.

### Owner B: runtime, storage safety, terminal robustness, launcher

Files: `vendor/exqlite/**`; `apps/swarm_code_daemon/lib/swarm_code/daemon/{cross_app_lease.ex,
cross_app_lease/**,repo_launcher.ex,runtime/**,application.ex,platform/**,startup_error.ex,backup/**}`;
new `daemon/boot.ex`, `daemon/shutdown.ex`; `domain/{runtime.ex,notifications.ex,paths.ex}`;
`daemon/service/{session_configuration.ex,session_selection.ex}`; `config/*.exs`; `rel/env.sh.eex`;
`rel/overlays/bin/load_provider_env.sh`, `rel/overlays/bin/swarm-code`;
`apps/swarm_code_cli/lib/swarm_code_cli/{application.ex,release/persisted_session.ex}`;
`apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/**`; `native/terminal_port/**`;
`scripts/**` except the demo scripts; their tests.

- B1 P0 rel F1 crash chain, all five fix steps (disconnect always `:ok`; retire and close replaced
  slot handles after a GC; `prepare: :unnamed` or equivalent so Ecto does not pin statements; bounded
  cleanup with one human line), plus the kill-a-checkout-holder regression test (close == :ok in 3 s).
  Repro scripts: `/private/tmp/p70cli/rel/exp/kill_*.exs`.
- B2 P0 The terminal never kills the session (rel F3 hardening half, ux F2, ux M9 second half): in
  `ratatui_port/owner.ex` a paint/encode exception or `:capacity_exceeded` keeps the previous frame
  and shows one error line (logged once), a busy port means "coalesce and draw the latest state
  later"; `persisted_session.ex` never raises on a draw problem. rel F17: the port's OS process dies
  with its owner; the tty open cannot block forever.
- B3 P0 rel F8: startup and session failures print one human sentence plus the action, exit non-zero
  (1 failure, 2 usage, 3 startup refused), say `swarmcode` not `SAVED DEV SESSION`, and never print
  a stack trace to the terminal; Logger writes to `~/Library/Logs/SwarmCode/cli.log` (0600, rotated,
  bounded), never to the tty while the TUI is up; the failure line names the log path.
- B4 P0 Providers per D3 (arch §3.3, arch F4, rel F5): `session_configuration.ex` stops upserting
  rows and rewriting conversations; honour `SWARM_MODEL_OVERRIDE` as a session override resolved
  against DB providers; first-run fallback only with an empty provider table; `load_provider_env.sh`
  whitelists `SWARM_*`, `OPENAI_*`, `ANTHROPIC_*`; after A-sync verify with a real `run_command`
  that a model-run shell does not see `GITHUB_ACCESS_TOKEN` (the synced domain's env scrub plus
  your launcher change). Test: launching with `SWARM_*` set leaves the providers table and the
  conversation row byte-identical.
- B5 P0 arch F8/rel F12: the global dir is resolved at runtime (desktop's
  `~/Library/Application Support/SwarmCode` on macOS, XDG on Linux), nothing of the builder's home in
  `sys.config`.
- B6 P0 after A-sync: runtime children from A's notes (`Tools.BackgroundProcs`, `LSP.Supervisor`,
  `Hooks.TaskSupervisor`, …) in `domain/runtime.ex`; `daemon/boot.ex` (desktop `bootstrap.ex`
  parity: `Conversations.mark_interrupted/0`, `Scheduled.reconcile_claimed/0`,
  `Providers.seed_defaults/0`, `MCP.start_all/0`, research sweeps, `Attachments.prune_abandoned/0`,
  `Isolation.Ownership.cleanup_stale/2`; not the Scheduler, the desktop owns schedules);
  `daemon/shutdown.ex` (`Quit.stop_everything/0` parity: stop workflows, `Engine.stop_all`, kill
  background commands, stop LSP clients). Tests: boot marks an orphaned running run interrupted;
  quit reaps a yielded `sleep 600`.
- B7 P1 rel F7: `RELEASE_DISTRIBUTION=none` (or a unique name) and a 0600 cookie; a second
  `swarmcode` either works or says in one sentence why not (who holds the lease).
- B8 P1 ux M9 output volume: `native/terminal_port/src/output.rs` diffs cell runs, emits SGR only on
  change, one cursor move per run, explicit erase behind forced-width cells. Budgets with tests:
  < 2 KB per keystroke and < 50 KB per streamed delta at 160x45.
- B9 P1 ux M10 exit summary: after leaving the alternate screen print 5–10 lines (conversation
  title, last prompt head, files changed, "stopped N live runs" if any, `swarmcode --continue`).
- B10 P2 `SwarmCodeCLI.UI.Renderer.RatatuiPort.copy(owner, binary)` → OSC 52 (bounded, SafeText
  checked) for E's copy action; opt-in SGR mouse wheel decoded to input events.

### Owner C: service boundary (protocol, backend, dispatcher, data source)

Files: `apps/swarm_code_core/lib/swarm_code/{protocol/**,commands.ex}` and their tests;
`apps/swarm_code_daemon/lib/swarm_code/daemon/service/**` except B's two files;
`apps/swarm_code_daemon/lib/swarm_code/daemon/service.ex`; `domain/feature_catalog.ex`;
`apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/**` and `ui/data_source.ex`; their tests.

- C1 P0 first, then tag `p70-C-wire`: DTO and wire additions, each with codec round-trip tests and a
  fake data source equivalent, documented in your notes as the contract for D and E:
  - interaction (approval): `tool`, `command`, `cwd`, `reason`, `command_family`, `classification`,
    `allowed_decisions` ⊆ `approve | approve_run | always_prefix | deny | deny_stop`;
  - conversation summaries (`id`, `title`, `updated_at`, `run_count`, `live?`) and operations
    `conversation_list`, `conversation_new`, `conversation_open`;
  - run/agent: `stop_reason`, `error_kind`, `model`, `provider_name`; op: `added`, `removed`
    line counts for edits and a detail request that returns the op's unified diff;
  - run-scoped changes (files + counts, diff on demand); background command chip; rate-limit
    (`retry_at`); project `trust` and `approval_mode`; `toast` deltas; `mark_seen`.
- C2 P0 approvals end to end (rel F2 step 1, ux M1 daemon half, arch F11): admit the op-node
  interaction, add a test with a real RunServer op-node approval; after A-sync: `always_prefix`
  with the command family, `approve_run`, `deny_stop`, `mark_seen`; stopped ops stop showing
  "awaiting approval" (rel F11); approval mode change + trust as operations.
- C3 P0 conversations (arch F7): list/new/open with re-subscribe, dropping the `member?/2` pinning;
  resume latest stays the default.
- C4 P0 rel F4 tripwires, daemon and client halves: a slow consumer fails one request, never closes
  the connection; overflow → resync, not close; watch/consume deadlines 30 s with a visible
  "reconnecting" state in the data source.
- C5 P1 subscriptions (arch F10): notifications, mcp, research, workflows, toast, the four ignored ui
  events.
- C6 P1 after A-sync, HEAD projection fields (arch F16): stop reasons, error kinds, agent model,
  background commands, rate limits.
- C7 P1 slash registry + dispatcher: `/new`, `/resume`, `/approval`, `/trust`, `/diff`, `/cost`,
  `/search` (FTS), `/export`, `/agents`, `/help`, `/quit`, `/clear` (entries that are client-only
  carry a flag so E's reducer handles them).
- C8 P1 ux §2.5 backend half: "Full detail" loads; Changes = this run's changes with diffs (from
  checkpoints / the synced run diff), not the whole git tree; `@path` completion as a feature query
  over the project index using the synced `FuzzyMatch`.
- C9 P2 incremental projection instead of a full reload per engine event (arch F14), with golden
  projection-equivalence tests; C10 P2 `PersistedBackend` uses `Domain.Tools.Path` (arch F17).

### Owner D: everything that is drawn

Files: `apps/swarm_code_cli/lib/swarm_code_cli/ui/{projector/**,projector.ex,scene/**,scene.ex,
scene_slot.ex,paint/**,paint.ex,prose.ex,transcript.ex,unified_diff.ex,theme.ex,safe_text.ex,
safe_text/**,layout.ex,layout/**,capabilities.ex,capabilities/**}`;
`apps/swarm_code_cli/lib/swarm_code_cli/{companion/**,companion.ex,demo/**}` and
`apps/swarm_code_cli/priv/companion/**`; their tests (`test/swarm_code_cli/ui/{projector/**,paint/**}`,
`projector*_test.exs`, `theme_test.exs`, `representative_scenes_test.exs`, `layout_test.exs`,
`safe_text_test.exs`, …) and the cell gallery. Exception: you may append fields to the `State`
struct in one block commented `# pass70-D fields` at the end of the defstruct and nowhere else.

Follow ux §4 (M3, M4, M5, M6, M7 visuals, M8, M11, M12, M13) and its sketches:

- D1 P0 M3 conversation-shaped transcript: chronological order inside a run (drop the ranking in
  `projector/workspace/turns.ex:126-163`), thinking folded into the turn header, one tool group per
  step without the repeated speaker, user turn as a card, selected row highlighted, streaming header
  says `writing`, sub-agent reports collapsed to one line.
- D2 P0 rel F3 / ux F2 projector half: project only the visible window plus a margin so the paint
  budget cannot overflow on any conversation at any size; test at 250x70 on a 5-run fixture and on
  a fixture shaped like conversation 7d01acff (10 runs, a failed 14-agent workflow).
- D3 P0 M4 markdown and code: numbered and nested lists, `_em_`, quotes, tables sized with
  `Width.cells`, links, rules; a `:code` role and code card with language chip and a small
  tokenizer (elixir, js/ts, py, rust, sh, json, diff); inline code chip.
- D4 P0 M5 + M6 chrome diet and no internals: one title/tab row, one status line
  (mode · approval · model · ctx gauge · cost · waiting · 2 hints); feedback as toasts; cue prefixes
  only in monochrome; no ids/UUIDs/opaque focus names anywhere; `SAVED · DEV` only for dev
  launchers; sentence case; settings rendered as a form.
- D5 P0 approval card in the composer slot (M1 visual, D4 decision keys) and the dialog text "This
  request is no longer pending" instead of `read_only_resize` for a lookup miss (`dialog.ex:560-568`).
- D6 P1 after C-wire: diffs (M4): `+3 −1` on edit rows expanding to hunks, a changes ledger and a
  diff pager; stop-reason and model chips; error cards with retry (M12); trust banner; rate-limit
  countdown; background command chip.
- D7 P1 M7 palette/picker visuals (groups, fuzzy highlights, right-aligned shortcuts, model picker
  grouped by provider with the current one checked, conversation picker rows); M8 hive strip below
  140 cols, worker lanes, `0 live` and the ticking clock of failed runs; M13 narrow layouts (80x24
  shows ≥ 17 transcript rows); M11 terminal background by default and the desktop's light mode.
- D8 P1 regenerate the cell gallery and golden scenes at 160x45, 120x36, 90x30, 80x24 for every
  screen you touched; keep the companion page working with the new DTO fields.

### Owner E: interaction, sessions, entry points

Files: `apps/swarm_code_cli/lib/swarm_code_cli/ui/{reducer/**,reducer.ex,keymap/**,keymap.ex,
editor/**,editor.ex,vim.ex,switcher.ex,model_picker.ex,slash_palette.ex,library.ex,feature_form.ex,
field_editors.ex,intent.ex,action.ex,action_target.ex,state.ex,init.ex,layer_spec.ex,
session_runtime.ex,effect.ex,effect_runner.ex,draft.ex,draft/**,drafts.ex,draft_key.ex,input.ex,
read_model.ex,watch_state.ex,scroll.ex,scroll_metrics.ex,scroll_operation.ex,destination.ex,
question.ex,request_resolver.ex,request_resolver/**,activity.ex,page_state.ex,mutation_state.ex}`;
`apps/swarm_code_cli/lib/swarm_code_cli/{plain/**,release.ex}`; new
`apps/swarm_code_cli/lib/swarm_code_cli/release/headless.ex`; `rel/overlays/bin/swarmcode`;
`docs/keybindings.md` (regenerated with `mix swarm_code.keymap --write`); `README.md` usage
sections; their tests.

- E1 P0 D5 keyboard (ux M2 table, ux F3, ux F17): letters always type; Esc interrupts/closes and
  never moves focus; PgUp/PgDn and Ctrl-U/D (empty draft) scroll from the composer; Ctrl-T select
  mode (`j/k`, Enter open, `y` copy via B10 when present, Esc back); Ctrl-C ladder; `exit_requested`
  counts live runs; Ctrl-J newline beside Ctrl-O; a non-Alt queue path (Tab while a run streams, or
  `/queue`); rel F6: keystrokes typed while a palette opens go to the palette, never into a prompt.
- E2 P0 approvals (rel F2 steps 2–4): open the approval over the current destination without
  navigating, keep interactions in the read model across destinations, keys
  `y Y A d D n` wired to C's decisions, the status line hint when something waits.
- E3 P0 after C-wire: conversation switcher and `/resume` picker, `/new`, `/approval`, `/clear`,
  `/help`, `/quit`; `/model` model picker grouped by provider with the current selection (state and
  data; D draws it).
- E4 P0 entry points (rel F9, arch F13): `swarmcode [DIR] [--new | --continue | --resume ID]
  [--model M] [-p PROMPT [--json]] [--plain [--ndjson]] [--help] [--version]`; `-p` runs one turn
  headless in the saved session, streams the answer to stdout, applies the project's approval mode
  (auto-deny what would need a person, and say so), exit 0 done / 1 run failed / 2 usage / 3 startup
  refused; `--plain` ships the plain presenter in the release. PTY or subprocess tests for exit
  codes. `--model` sets `SWARM_MODEL_OVERRIDE` (B4 reads it).
- E5 P1 prompt history (Up on an empty draft, per conversation), `@path` completion over C8's
  query, slash popup of 8 rows above the composer.
- E6 P2 Ctrl-X edits the draft in `$EDITOR`; mouse wheel if B10 lands.
- E7 P1 regenerate `docs/keybindings.md`; update README usage for the new flags and keys.

## 5. Acceptance (finisher and QA run all of it on the merged tree)

1. `mix precommit` green on the merged tree (with A's `provenance.sync --check`); `cargo test`;
   `mix swarm_code.keymap --check`; the PTY suites that apply.
2. Sandbox first launch on a fresh 53-migration copy: verified backup, migration to 57, the TUI opens
   on the desktop's default provider with `SWARM_*` from `~/.secrets` present; providers table and the
   conversation row unchanged afterwards.
3. In a scratch ailogic copy: "create notes/x.md with two lines then run ls -la notes" → approve with
   `y` from the composer → the run finishes; `A` always-allows the `ls` family for the next prompt;
   `D` denies and stops.
4. Ctrl-R and Ctrl-G on conversation 7d01acff (sandbox copy) and a 250x70 resize: no crash.
5. The first reply reads text → tools → text, code block on a card, one header row, status line with
   mode, approval, model, ctx and cost.
6. Esc then typing `please` types it; Ctrl-C interrupts a streaming turn; a second Ctrl-C with a live
   run asks before quitting; the exit summary is printed.
7. `swarmcode -p "what is this project? one line" ~/…/ailogic` prints the answer and exits 0; a bad
   flag exits 2; a refused startup exits 3 with one sentence.
8. Two terminals: the second `swarmcode` works or explains itself in one sentence.
9. A streamed reply at 160x45 writes < 1 MB of terminal output; a keystroke < 2 KB.
10. A model-run `env` in the sandbox does not show `GITHUB_ACCESS_TOKEN` or other non-provider
    secrets from `~/.secrets`.
11. Killing a DB client mid-query (B1 test) and a stalled consumer (C4) never close the session.

## 6. Out of scope this pass

Attaching the CLI to a running desktop engine and making the desktop honour the CLI's lease (both
need desktop changes; REVIEW #1 stays open and documented); the prod-DB cleanup of the leaked "CLI …"
provider rows and `/private/tmp/swarm-cli-plain.*` projects (owner decision, with a backup); Keychain
secrets; running the Scheduler in the CLI; deleting the transient live runtime
(`lib/swarm_code/{llm,tools}`, `daemon/runtime/run.ex`).
