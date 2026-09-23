# pass70 owner E notes

Owner E: interaction, sessions, entry points. Branch `p70/E`, worktree
`/Users/zaali/dev/swarm-code-cli-wt/p70-E`.

## Landed

| task | what | commit |
| --- | --- | --- |
| E1 | composer-first keyboard (D5) | see `git log --grep 'pass70 E1'` |
| E2 | approvals over the conversation, `y Y A d D n`, auto-open with a typing grace | same commit as E1 |
| E5 (history half) | Up/Down prompt history per conversation | same commit as E1 |

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
  `history_cursor`.
- **Select mode** ⇔ `state.focus in ["main", "inspector"] and state.layers == []`.
- **Actions** (validated in `UI.Action`): `{:interrupt, :escape | :ctrl_c}`, `:select_mode`,
  `{:compose, text}`, `{:history, :previous | :next}`, `:copy_selection`,
  `{:slash_local, :help | :quit | :new | :resume | :conversations | :queue}`.
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
- **D (status line):** the composer hints now come from `:send`, `:interrupt_turn` (Esc "Interrupt"),
  `:composer_newline`, `:command_palette`, `:complete` (Tab), `:next_need_chord` (Ctrl-N "Waiting"),
  `:select_mode` (Ctrl-T "Select"), `:interrupt` (Ctrl-C). Select mode (`focus == "main"`, no layer)
  wants the banner `SELECT · j/k move · Enter open · y copy · Esc back`.

## Manifest-listed files edited

None.

## Verification

- `mise exec -- mix test apps/swarm_code_cli/test` → 1208 tests, 5 properties, 0 failures.
- New `test/swarm_code_cli/ui/composer_first_test.exs` (26 tests: Esc, Ctrl-C ladder, select mode,
  scrolling, Tab queue, approvals, history, slash commands).

## Left

- E3, E4, E5 (@path, slash popup rows), E6, E7: see below as they land.
