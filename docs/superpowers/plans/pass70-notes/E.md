# pass70 owner E notes

Owner E: interaction, sessions, entry points. Branch `p70/E`, worktree
`/Users/zaali/dev/swarm-code-cli-wt/p70-E`.

## Landed

| task | what | commit |
| --- | --- | --- |
| E1 | composer-first keyboard (D5) | c8eb87c |
| E2 | approvals over the conversation, `y Y A d D n`, auto-open with a typing grace | c8eb87c, e559db2 (read model: background, rate limits, toasts, unknown deltas) |
| E5 (history half) | Up/Down prompt history per conversation | c8eb87c |
| E3 | conversation switcher, `/resume` `/new` `/clear` `/approval` `/trust`, model picker by provider | f48378e, 2a7eaac (after merging `p70-C-wire`, 8d7e37e) |
| E4 | `swarmcode [DIR] [--new\|--continue\|--resume ID] [--model M] [-p PROMPT [--json]] [--plain [--ndjson]] [--help] [--version]`, exit codes 0/1/2/3 | eb99f2a |
| E5 (rest) | `@path` completion over C8's `files` query; the client's commands in the slash popup, `SlashPalette.rows/0` = 8 | 59953d2 |
| E7 | README usage (flags, `-p`, `--plain`, exit codes, composer keys); `docs/keybindings.md` checked current | 195e74e |

### E1 keyboard, as built

- Letters always type in the composer. Tab in the composer completes a slash command, queues the
  draft while a turn runs (the non-Alt queue path), and otherwise does nothing: it never moves focus.
  Shift-Tab is no longer bound in the composer.
- Esc in the composer: `{:interrupt, :escape}`. The reducer stops the turn in view
  (`Keymap.live_turn/2`: newest top-level run of the conversation, state queued/running/streaming/
  retrying, `:stop` allowed) without a confirmation, and does nothing otherwise. Esc never moves focus
  out of the composer (vim: a bare NORMAL Esc interrupts too). Esc still closes the top layer first,
  and in select mode hands back to the composer.
- Ctrl-C: `{:interrupt, :ctrl_c}`, a ladder in the reducer. A press closes the top layer, else clears
  the draft (undoable with Ctrl-Z), else stops the turn (waiting and paused states included), and arms
  a 1.5 s timer (`state.quit_armed`); a second press while armed quits. A third press on the quit
  confirmation confirms it (mash Ctrl-C to leave).
- Quit (`q` in select mode, `/quit`, second Ctrl-C) asks when runs are live: the existing
  `{:unsent_changes, :detach}` layer opens with `state.quit_live_runs = N`. Terminal failure/closing
  paths do not count live runs (unchanged).
- Ctrl-T: select mode = focus `"main"` (or `"inspector"`), with the newest transcript row selected.
  j/k move, Enter opens, `y` copies (`:copy_selection` → effect `{:copy, text}`), Esc/Ctrl-T back,
  `q` quits. An unbound printable key in select mode goes back to the composer and types
  (`{:compose, text}`); a bound key that declines (held `x`, `]` with no inspector) does nothing.
- PgUp/PgDn scroll the transcript from the composer; Ctrl-U/Ctrl-D do too on an empty draft (Ctrl-U
  still deletes to line start when there is text). Ctrl-J is a newline beside Ctrl-O (see B request).
- Ctrl-P only ever opens the palette; pressed again it refocuses the palette query (rel F6). Ctrl-G
  and Ctrl-R still toggle (D's projector tests pin that).
- Client slash commands (`Keymap.local_command/1`, answered in the reducer, never sent):
  `/help`, `/quit` `/exit`, `/queue <text>`; `/new` `/clear` `/resume` `/conversations` land with E3.
- Final paint text is now "Closing SwarmCode." / "Leaving the full-screen view." instead of
  `DETACHED — RUNS CONTINUE`.

### E2 approvals, as built

- `{:open_interaction, id}` opens the card over the current destination; it navigates (to the run)
  only when the interaction belongs to another conversation.
- The first pending approval or question of the conversation in view opens by itself
  (`state.auto_opened`). For 700 ms after it opens, and for as long as the user keeps typing, printable
  keys and Backspace go into the draft underneath (`state.interaction_grace`), Enter waits, Esc
  dismisses. A card closes by itself when its interaction stops being pending; an auto-opened card
  closes when the view moves away. Esc puts a pending one aside
  (`state.dismissed_interactions`, `{id, expected_revision}`); Ctrl-N (composer) / `n` (select mode)
  brings it back.
- Keys on an approval card: `y` once, `Y` this run, `A` always (`:always_prefix`, falling back to
  `:always_allow`), `d` deny, `D` deny & stop, `n` next waiting. The intent is built from the read
  model's interaction (not looked up among drawn targets), so the keys work wherever D draws the card.
  `a` stays as a legacy alias of `y` because `projector/dialog.ex` reads `Bindings.fetch(:approve)` at
  compile time.

### E3 conversations, as built

- Opening the palette (`{:open_layer, {:switcher, _}}`) sends one `{:conversation_list, nil, 50, _}`
  query (origin `{:conversation, :list}`, shell watch scope); the answer is kept in
  `state.conversations` (a `DTO.ConversationList`). Conversation entries are listed by title, never by
  id: `Title · N runs · live · k waiting · open` ("Untitled conversation" when empty), target
  `{:local, {:open_conversation, id}}`, never marked recent. "New conversation" is always there.
- `{:open_conversation, id}` closes the palette and sends `{:conversation_open, id}` (origin
  `{:conversation, :open}`); the view navigates only once the service accepts, then re-asks for the
  list and focuses the composer. The conversation already open only closes the palette.
- `/new` and `/clear`: `{:conversation_new}`; accepted → the new conversation opens (identifiers[0]).
  `/resume` and `/conversations` open the palette with the query `#` (conversations only).
- `/approval read-only|auto|full` sends `{:project_update, mode, nil}`; bare it says the current mode;
  anything else leaves the draft and says the three words. `/trust` sends `{:project_update, nil, true}`.
  Refusals become a sentence in the notice.
- Run entries in the palette read `Run: <title>` (no uuid). "Detach" is now "Quit".
- Model picker rows carry `provider_id`, `first_in_group?` (a provider heading goes above) and
  `current?` = the model matches and (the provider matches `chat_provider`/`swarm_provider`, or none
  is known). Group order is the daemon's order.

### E4 entry points, as built

- `rel/overlays/bin/swarmcode` parses the whole command line in bash and answers `--help`,
  `--version` (from `releases/start_erl.data`) and every usage error (one line, exit 2) before any VM
  starts. It exports `SWARM_PROJECT_ROOT` (DIR or `$PWD`), `SWARM_TERMINAL_PORT`, `SWARM_CONVERSATION`
  (`new` / `latest` / the id; the flag wins over an export) and `SWARM_MODEL_OVERRIDE` **only** from
  `--model` (it is unset otherwise, D3). The full screen is `bin/swarm_code_cli start` with
  `SWARM_RELEASE_TUI=1` (unchanged, B's `application.ex` + `persisted_session.ex`). `-p` and `--plain`
  are `bin/swarm_code_cli eval 'SwarmCodeCLI.Release.main(System.argv())' -p PROMPT [--json]` /
  `--plain [--ndjson]`. When stdin or stdout is not a terminal (or `TERM=dumb`) the plain presenter
  answers by itself, with one stderr line saying so.
- `SwarmCodeCLI.Release.parse/1` is the same grammar (tests pin both), `run/1` returns the code and
  `main/1` halts with it. `-p -` reads the prompt from stdin (≤ 256 KiB).
- `SwarmCodeCLI.Release.Headless.run/2` opens the saved session like `PersistedSession` (a thin copy of
  its startup, see requests) and runs `Plain.OneShot` (`-p`) or `Plain.Session` with `eof: :wait`
  (`--plain`). It moves the console log handler to stderr at `:warning` (stdout is the answer).
  Startup refusals are one line and exit 3 (`Headless.refusal/1` words `StartupError`, missing
  provider, unknown conversation); a crash is one line and exit 1, never a stack trace.
- `SwarmCodeCLI.Plain.OneShot` drives the same `Reducer`/`ReadModel`/`RequestResolver` as the TUI
  (it owns a `UI.State`, runs effects through `EffectRunner`, ignores local ones). It pastes the
  prompt into the draft and invokes `{:dispatch, :send, …}`; the answer is the run's assistant
  *message* items (`id != node_id`, role assistant, kind text) streamed to stdout (a longer text
  continues what was written, a shorter one is a preview, anything else is a restart said on
  stderr). After the run ends it reads the workspace once more and pages any `detail_ref` rest.
  Approvals of its runs are denied (`:deny`, else `:deny_stop`), each said on stderr; 8 denials, a
  question, or a deny the service refuses stop the run (said once). `--json` prints one object:
  `conversation_id run_id state text error question denied exit_code`. Tool lines (`· title`) go to
  stderr only when stderr is a terminal. C0/C1 control characters never reach the terminal.
- Checked for real in a sandbox HOME (`/private/tmp/p70cli/p70-E`, scratch ailogic, 3 real prompts):
  `-p "Reply with exactly the word pong…"` → stdout `pong`, exit 0, empty stderr; an approval →
  denied line, (the p70/E backend still refuses op-node approvals, C2 fixes that) the run stopped and
  exit 1; the missing 0700 product dirs → one refusal line and exit 3; `--plain` with `help` on
  stdin → exit 0.

### E5 rest, as built

- `Reducer.PathCompletion` (`state.path_completion`): an `@` token at the caret (`@` at the start or
  after whitespace) sends `{:feature_query, :files, query | nil, nil, 20, 65_536}` (origin
  `{:feature, :files}`, workspace scope); a newer token cancels the older request and drops it from
  `state.requests`. Down/Up move (`{:move, _}`), Tab → `{:complete_path, path}` replaces the token
  with `@path ` as one undoable edit, Esc → `:dismiss_completion` (before any layer or interrupt).
  `PathCompletion.visible(state, limit)` returns the rows with `selected?` (items keep `matches`).
- `SlashPalette.catalogue/1` merges the client's commands (new, resume, approval, trust, queue,
  help, quit) first, each name once, over an older catalogue entry of the same name; an entry the
  catalogue flags `client: true` (C7) replaces the local one. `SlashPalette.rows/0` = 8.

### E5 history half

- Up on an empty draft walks `Reducer.prompt_history/2`: prompts accepted in this session (newest
  first, 100 per conversation, 16 conversations, prompts over 64 KiB skipped) then the transcript's
  user turns. Down walks back and finally restores the draft that was there. Editing a recalled prompt
  makes it the draft (`state.history_cursor` cleared).

## Contracts published

- **Intent** `{:resolve_approval, run, node, id, rev, decision}`: `decision` ∈
  `Intent.decisions/0` = `[:approve, :approve_run, :always_prefix, :always_allow, :deny, :deny_stop]`.
  `:always_prefix` carries no family: the daemon uses the pending interaction's own `command_family`
  (clients never make policy). The three new atoms are also `Intent.permissions/0`, so a DTO may list
  them in `allowed_actions`. `RequestResolver` admits `:approve_run` / `:always_prefix` / `:deny_stop`
  by their own permission or by the one they refine (`:approve` / `:always_allow` / `:deny`).
- **Allowed decisions** are read with `Keymap.decisions/1`: `Map.get(item, :allowed_decisions)`, else
  `item.approval.allowed_decisions`, else derived from `allowed_actions` (approve / deny / always).
- **State fields** (block `# pass70-E fields`, after `command_report`): `quit_armed`,
  `quit_live_runs`, `interaction_grace`, `auto_opened`, `dismissed_interactions`, `prompt_history`,
  `history_cursor`, `conversations`, `path_completion`.
- **Select mode** ⇔ `state.focus in ["main", "inspector"] and state.layers == []`.
- **Actions** (validated in `UI.Action`): `{:interrupt, :escape | :ctrl_c}`, `:select_mode`,
  `{:compose, text}`, `{:history, :previous | :next}`, `:copy_selection`,
  `{:slash_local, :help | :quit | :new | :resume | :conversations | :queue | :approval | :trust}`,
  `{:open_conversation, id}`, `:new_conversation`.
- **Switcher entries** (`Switcher.Entry`) gain `title`, `detail`, `current?`: D may draw the title
  bold and the detail dim, and mark `current?`. `state.conversations` is the last list answer.
- **Model picker rows** gain `provider_id`, `first_in_group?`, and `current?` per provider.
- **Palette order**: other conversations in the service's order, then the open one, then "New
  conversation" (`Switcher.Entry.order`); Enter after `/resume` opens the newest other one.
- **Launcher → release**: env `SWARM_PROJECT_ROOT`, `SWARM_CONVERSATION`, `SWARM_MODEL_OVERRIDE`
  (only from `--model`), `SWARM_TERMINAL_PORT`; headless argv `-p PROMPT [--json]` or
  `--plain [--ndjson]`. Exit codes 0 done, 1 run failed/stopped, 2 usage, 3 startup refused.
- **`@path` popup**: `Reducer.PathCompletion.visible/2`, actions `{:complete_path, path}`,
  `:dismiss_completion`.
- **Effect** `{:copy, text}` (≤ `Effect.max_copy_bytes/0` = 256 KiB). The session runtime sends the
  terminal `{:terminal_copy, generation, token, text}` and waits 1 s for
  `{:terminal_copy_result, token, :ok | {:error, reason}}`; the notice then says "Copied N lines." or
  "This terminal cannot take a copy from SwarmCode." (The UI may not reference the renderer module:
  `architecture_test.exs`.)

## Requests for other owners

- **B (terminal port, B10):** handle `{:terminal_copy, generation, token, text}` in
  `ui/renderer/ratatui_port/owner.ex`: write OSC 52 (bounded, SafeText-checked) and reply
  `send(runtime, {:terminal_copy_result, token, :ok | {:error, reason}})`. Until then `y` says the
  terminal cannot copy.
- **B (Rust decoder):** `native/terminal_port/src/input.rs` `ordinary/2` maps `b'\n'` (0x0A) to
  `Key::Enter`. Terminals send CR for Enter and LF for Ctrl-J, so please decode 0x0A as the text
  fragment `j` with Ctrl, like the other C0 bytes; the keymap already binds Ctrl-J to newline. Until
  then Ctrl-J sends.
- **D (dialog/composer card):** the approval card's key hints are the bindings `:confirm_yes` (y),
  `:approve_run` (Y), `:always_allow` (A), `:deny` (d), `:deny_stop` (D), `:confirm_no` (n). Please
  stop reading `Bindings.fetch(:approve)` so the legacy `a` alias can go. Controls you draw may use
  focus ids `approve`, `approve_run`, `always_prefix`/`always_allow`, `deny`, `deny_stop`
  (`Keymap.approval_key/3` maps them).
- **D (quit confirmation):** `{:unsent_changes, :detach}` is also the live-run quit question. When
  `state.quit_live_runs > 0` please title it "Stop N live runs and quit?" (and mention unsent work only
  when `State.dirty?/1`).
- **D (palette/model picker):** draw `Switcher.Entry.title` with `detail` dimmed (the `label` keeps
  both for older painters), and in the model picker a provider heading above each row with
  `first_in_group?`, plus a check on `current?`.
- **D (composer popups):** draw `SlashPalette.visible(state, SlashPalette.rows())` (8 rows, name,
  `args` dim, `desc`) and `Reducer.PathCompletion.visible(state, 8)` (path with `matches` graphemes
  bold) *above* the composer; today `projector/composer.ex` shows `min(4, rect.height - 1)` rows inside
  it, and at 80x24 only one row fits.
- **D (status line):** the composer hints now come from `:send`, `:interrupt_turn` (Esc "Interrupt"),
  `:composer_newline`, `:command_palette`, `:complete` (Tab), `:next_need_chord` (Ctrl-N "Waiting"),
  `:select_mode` (Ctrl-T "Select"), `:interrupt` (Ctrl-C). Select mode (`focus == "main"`, no layer)
  wants the banner `SELECT · j/k move · Enter open · y copy · Esc back`.

- **B (`release/persisted_session.ex`):** please expose the startup as public functions so
  `Release.Headless` stops keeping a copy: e.g. `PersistedSession.open(root, selection, env) ::
  {:ok, %{session, source, source_epoch, close: (-> :ok)}} | {:error, reason}` covering RepoLauncher,
  SessionSelection/SessionConfiguration, PersistedBackend, Service and the Daemon source, plus
  `close/1`. Headless mirrors your current `launch/1` + `run_ui/2` minus the terminal; any B3/B4/B5
  change there (StartupError words, `SWARM_MODEL_OVERRIDE`, the global dir) needs the same change in
  `Release.Headless.open/3` until then. Headless needs `umask 077` from `rel/env.sh.eex` (the product
  dirs are refused at 0755).
- **B (B3 logging):** Headless swaps the console handler to stderr at `:warning`; a file handler you
  add is left alone. The TUI still printed `[notice] Application swarm_code_daemon exited: :stopped`
  onto the terminal at close.
- **Finisher (merge order):** E3 sends `conversation.list` whenever the palette opens. On p70/E alone
  the persisted service does not implement it and closes the connection, which ends the session
  (seen in the sandbox smoke). C3 (list/new/open) and C4 (a failed request fails alone) fix both;
  merge C before judging E3.

## Manifest-listed files edited

None.

## Verification

- New tests: `ui/composer_first_test.exs` (26), `ui/conversations_test.exs` (11),
  `ui/data_source/read_model_pass70_test.exs` (4), `plain/one_shot_test.exs` (9),
  `entry/launcher_test.exs` (subprocess against a stub release: usage → 2 before any VM, flag → env,
  exit code pass-through, auto-plain), `entry/release_test.exs` (grammar, and `main/1` in a VM of its
  own halting 0 / 2), `ui/path_completion_test.exs` (6). Test dirs avoid `test/swarm_code_cli/release`
  (a locked campaign path in `locked_branch_fixtures.ex`).
- GNU screen smoke of the saved TUI (80x24, sandbox): letters type (`qjk hello`), Ctrl-C clears and
  Ctrl-Z restores the draft, the approval card opens over the conversation by itself, `d` reaches the
  service (refused on p70/E, see C2), Esc puts it aside and Ctrl-N brings it back, Ctrl-C stops the
  waiting turn ("Stopping the turn."), `/resume` opens the palette on `#` (and ended the session on
  p70/E alone, see the merge-order note).

## Left

- E6 (P2): see below.
