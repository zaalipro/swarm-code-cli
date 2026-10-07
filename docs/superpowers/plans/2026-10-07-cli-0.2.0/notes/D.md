# Lane D notes (cli020, CLI 0.2.0)

Branch `cli020/D` in `~/dev/swarm-code-cli-wt/cli020-D`, from M1 `3008f352`. Every D task
D1-D21 is done, plus the §3 hot spot for E5 (`panel_mode :auto`). Nothing merged.

## Commits

| Task | Commit | What |
| --- | --- | --- |
| D1 | 8849c6b | Option/Ctrl-←/→, Alt-b/f/d word moves |
| D2 (+ native D3, D5, D11) | d8b8a99 | kitty probe/push/pop, Ready bit 128, Notify tag 9, Scroll kind 7, Redraw tag 10, ?1007h, tmux OSC 52 |
| D3 | f9575e0 | bell / OSC 9 / OS notification, window title (`Reducer.Attention`, `OsCommand`) |
| D4 | 8407dd6 | pbcopy, honest OSC 52 words |
| D5 | c457053 | `{:scroll, dir, n}` routed like the wheel, `wheel_lines` |
| D6 | 5ea9388, e110741 | Shift-Tab Ask → Auto → Plan; contract words; refusal text |
| D7 | 41f09ed | `!cmd` shell (`Reducer.Remote` seam) |
| D8 | 7a06381 | paste chips (`Draft.Pastes`) |
| D9 | 17918b9 | Ctrl-V image paste (`Reducer.ImagePaste`, osascript/sips jobs) |
| D10 | aaaaaa6 | rewind client (`Reducer.Rewind`, `Keymap.Layers`) |
| D11 | b101024 | Ctrl-L redraw |
| D12 | b81844c | keep the last good frame |
| D13 | 037b1cd | terminal prefs act (wheel, notice, hint letters, reduced motion) |
| D14 | ce46baa | quote-aware editor command |
| D15 | 92a454b | palette typing never lost, Up stays on row 0 |
| D16 | 69095c1 | `r` retries a failed/stopped run |
| D17, D18 | 36db68c | Enter/o on a tool row; effort picker |
| D19 | 2041ba1 | Ctrl-R history search, draft stash |
| D20 | c70e569 | local `/queue` list/clear/drop, `/delete` confirm |
| D21 | 91e2f68 | `State.markdown_cache` (`UI.MarkdownCache`) |
| E5 hot spot | efea55a | `panel_mode :auto` type, default, Ctrl-B cycle |

## Deviations (code vs contract; the smallest change that keeps the intent)

- D2: Ready is deferred until the DA1 answer or 500 ms; the probe runs only on the first
  alternate-screen activation. Probe answers are removed from the read by a raw scan; a late
  answer is swallowed by the parser. The kitty push/pop goes through the guard (socket byte 128)
  so an emergency restore pops it too.
- D3: the title is saved lazily (`CSI 22;2t`) right before the first title is written, not at
  init, and restored (`CSI 23;2t`) by the writer session on suspend/shutdown/EOF, not by the
  guard (a writer crash skips the title restore). Bell and title run only for full-screen
  capabilities (the port owner's), so the plain presenter, demos and pure tests see neither. The
  reducer emits both `{:bell, k}` and `{:notify_os, text}`; the runtime picks one by
  `terminal.notify`. `notify`/`title` are read from `state.prefs` (cli.json names) as well as
  `Init`, so they work before B's pass-through lands.
- D4: pbcopy reads a private temp file through `/bin/sh -c 'exec /usr/bin/pbcopy < "$1"'`:
  an Erlang port cannot close the stdin of the program it runs while still waiting for its
  exit status ("write the text, close" is not possible). tmux passthrough is decided in the port
  from `TMUX`.
- D5: the Scroll record's `up` byte is 1 for up (the Wheel kind 6 uses 0 for up). The burst is
  detected only on credit reads. The mouse default `false` is E26's (Preferences); D's branch
  still starts with wheel reports on until E lands. The help text of the contract is the
  keyboard reference's mouse note (`keymap/docs.ex`).
- D6: `/plan` goes out as a dispatch from a blank copy of the draft, which is then put back
  unchanged (`send_command_text/2`), so a half-typed draft survives; `/approval` goes as
  `project_update`, like `slash_local(:approval)`.
- D7: "a shell command runs" = an unanswered `shell.run` request or a `:shell` transcript row
  without `exit` (C15).
- D8: the expansion happens in `Commands.invoke/3` (D's), in the request and in the text the
  resolver compares, so E's drawn Send target needs no change; the pending mutation keeps the
  drawn intent. One line is `[Pasted text #N · 1 line]`.
- D9: the reducer owns requests, so the runtime asks it for the slot
  (`{:paste_image_slot, c}`), the slot's answer becomes the effect
  `{:paste_image_write, c, token, path}` and the job answers `{:paste_image_done, c, token,
  result}` (names beyond §8.3). There is no slot-release op in §8.2: a slot that is never
  attached expires on the daemon (60 s, C14).
- D10: extra action `{:rewind_move, ±1}`; "N file(s)" is pluralised ("1 file", "2 files");
  new State fields `rewind`, `last_escape_at`.
- D11: the action is `:redraw_screen`; the runtime asks for a frame at once after the control.
- D12: the explain path (stderr or the sink) runs on the closing (fifth) failure; earlier ones
  log the same words through `Logger.warning` (a raise through `Logger.error`), so a TUI frame is
  never overwritten by stderr. The projector is injectable (`opts[:projector]`) for the test.
- D13: reduced motion sets `capabilities.reduced_motion?` and survives a new terminal's
  capabilities; drawing a static glyph for the pulses/spinners is the projector's (E) and is not
  in this lane.
- D15: Up on the query field also stays (the picker ring starts with "query").
- D17: a tool row without `detail_ref` keeps pass70 Q9's fold-open where one is drawn
  (`pass70_qa_select_test` "a tool without a diff still folds open"); with nothing drawn Enter
  does nothing; `o` does nothing.
- D19: words "Nothing to stash.", "No stash to restore.", "Stash restored".
- D20: bare `/delete` asks with a notice and a second `/delete` within 5 s sends it (LayerSpec's
  `confirm_intent` takes only stop intents, so no confirm layer). Out of range:
  "The queue has N message(s): /queue drop 1..N."; not a number: "Drop which message? /queue
  drop N, N from 1."
- D21: the cache scope is `ui.destination`; `table.markdown_rows` is popped so the action table
  stays clean.
- E5 hot spot: `:auto` is not written to cli.json until `UI.Init.Preferences.valid?/1` accepts it
  (E5); until then the session keeps it unsaved. Layout and panel draw `:auto` as `:full` today.

## Stubs the finisher removes or checks (§8.1)

1. `SwarmCodeCLI.UI.Reducer.Remote.send/3` (`ui/reducer/remote.ex`) is D's one seam to C's new
   ops. It builds `%Request{kind, scope: workspace watch scope, origin: {:conversation, action},
   expected_response: :outcome}` and sends it only when `Request.validate/1` accepts it; until C's
   intents land it shows "This ncode daemon cannot do that yet." and sends nothing. Ops and
   origins: `{:shell_run, c, text}`/`{:shell_stop, c}` → `:shell`; `{:attachment_slot, c}`/
   `{:attach_slot, c, token}` → `:attachment`; `{:rewind_turns, c}`/`{:rewind_apply, c, mid,
   scope}` → `:rewind`; `{:history_search, query}` → `:history`; `{:queue_edit, c, rev, edit}` →
   `:queue` (C's `Intent.conversation_action/1` already says `:queue`). After M2 check:
   (a) C's `conversation_action/1` names match these origins; (b) the queries
   `rewind_turns`/`history_search` may want their own `expected_response` (Remote uses
   `:outcome`); (c) `{:history_search, query}` has no conversation id as its second element, so
   C's `Request.conversation_scope?/2` refuses it if `:history` is a conversation action: scope it
   the way C defines.
2. `Remote.outcome_payload/1` reads the answer from `outcome.result`, else `outcome.feedback.rows`;
   a non-outcome body is passed through as is. Map C's real answer shapes (§8.2: `rewind.turns`
   rows, `rewind.apply` `%{type: :rewound, text, attachments, restored, skipped}`,
   `attachment.slot` `%{token, path}`, `history.search` rows) here. `Remote.field/2` accepts
   atom or string keys.
3. `Remote.drawable?/1` opens D's new layers only when `LayerSpec.validate/1` knows them:
   `{:rewind, %{turns, selected}}`, `{:rewind_confirm, turn}`, `{:effort_picker, :chat | :swarm}`,
   `{:history_search, %{query, rows, selected}}`, `{:queue_list}`. E adds them to `LayerSpec`
   with the drawing; until then the notice says "… is not drawn in this build yet." The gate may
   stay (it is correct) or go.
4. `Reducer.set_panel/2` saves `panel_mode: :auto` only when `UI.Init.Preferences.valid?/1`
   accepts it (E5); drop the guard after E5 if wanted.
5. Tests with a stub branch (assert the sent request when C's op validates, else the stub
   notice): `cli020/d7_shell_test.exs`, `d9_image_paste_test.exs`, `d10_rewind_test.exs`,
   `d20_local_commands_test.exs` (`Cli020State.landed?/1`), and the layer branches in
   `d10_rewind_test.exs`, `d18_effort_picker_test.exs`, `d20_local_commands_test.exs`
   (`Remote.drawable?/1`). After M2 make them unconditional.
6. D18 reads `effort_levels`/`swarm_effort_levels`/`effort`/`swarm_effort` and D20
   `queue_revision` from the workspace snapshot with `Map.get` (C17/C1 add the DTO fields); the
   tests put them on the snapshot with `Map.put`.

## Cross-lane facts for the finisher

- `apps/swarm_code_cli/test/swarm_code_cli/ui/settings/c74_editors_u3_test.exs:14` (E's) captures
  Ctrl-L as a free chord for the palette; D11 binds Ctrl-L (Redraw), so it fails with
  "Ctrl-L is taken by "Redraw"". Change the chord in that test (Ctrl-Q is unbound; Ctrl-H, -I,
  -M arrive as Backspace/Tab/Enter, Ctrl-K is forbidden).
- `UI.Hint.labels/2`/`letter_labels/2` take the letters; E's projector calls none of them.
- D3's title/bell need `capabilities.full_screen?` (the port owner sets it).
- D21: E31 reports computed rows under `table.markdown_rows` (`key => rows`) and reads them back
  with `UI.MarkdownCache.get(state.markdown_cache, key)`.
- E draws: the `$` chip from `Composer.shell?/1`, the paste chip from the draft's `pastes`,
  `nothing more to open` for D17, the new layers above, the queue list's numbered
  `queued_texts`, and the palette rows `{:stash_draft}` / `{:restore_stash}` (D19) and the new
  local commands (D20) in `slash_palette.ex` `@local`.

## AGENTS.md text for the finisher (CLI `AGENTS.md`, "TUI facts that constrain changes")

Replace "Enhanced keys (kitty protocol) are always unavailable." with:

> Enhanced keys (kitty protocol) are used when the terminal offers them: the port probes
> `CSI ? u` + DA1 on the first alternate-screen activation (Ready waits for the DA1 answer, at
> most 500 ms), pushes `CSI > 1 u` (disambiguate) through the guard and pops it on every
> restore, suspend and emergency exit; Ready's bit 128 reports it and Shift-Enter then inserts a
> newline. A terminal that never answers starts normally.

Replace the wheel sentence ("Wheel reports are on by default (pass73 T9) …") with:

> Wheel reports are off by default (cli020 D5, cli.json `mouse`): the port writes `CSI ? 1007 h`
> (alternate scroll), the terminal sends the wheel as arrows, and one read of two or more
> identical Up/Down arrows is the Scroll input (`{:scroll, :up | :down, 1..32}`), which scrolls
> what the wheel scrolls by `count × terminal.wheel_lines`; the terminal selects text. `/mouse on`
> (or `SWARM_MOUSE=1`) sends wheel reports instead (Shift-drag selects).

Add:

> - Keys of cli020 (lane D): Option/Ctrl-←/→ and Alt-b/f move by word, Alt-d deletes one;
>   Shift-Tab in the composer cycles Ask → Auto → Plan (`/approval`, `/plan`); `!cmd` runs a
>   shell command (Ctrl-S sends it plain, Esc stops it); Ctrl-V attaches the clipboard's image
>   (macOS, osascript/sips); Ctrl-L repaints every cell; Ctrl-R in the composer searches the
>   project's prompt history (Switch run stays on Ctrl-R elsewhere); Esc Esc on an empty draft
>   opens the rewind list; `r` in select mode retries a failed or stopped run; Enter/`o` on a tool
>   row open its full output. Large pastes collapse to `[Pasted text #N · L lines]` and are
>   expanded on send (`Draft.Pastes`).
> - Attention (cli020 D3): while the terminal reports focus lost, a new approval/question or the
>   end of a run this session started rings once per 2 s as BEL, OSC 9 or an OS notification
>   (`terminal.notify`), and the window title says `ncode · <project>` [`· working`, `· needs
>   you`, `· done`] (`terminal.title`); the port saves and restores the terminal's own title.
> - Copy (cli020 D4): `y` uses `/usr/bin/pbcopy` on macOS outside SSH, otherwise OSC 52 (tmux
>   passthrough when `TMUX` is set); the notice says which.
> - A failed screen update keeps the last good frame; only five failures in a row close the
>   session (cli020 D12). New client-to-daemon ops go through `UI.Reducer.Remote`.

## Tests run

Lane D's own tests: `apps/swarm_code_cli/test/swarm_code_cli/ui/cli020/` (19 files: d1, d3 ×2,
d4-d21), `ui/draft_paste_test.exs` (D8) and `ui/renderer/ratatui_port/cli020_port_test.exs`:
116 tests, 0 failures at the done commit; `native/terminal_port/tests/cli020.rs` (11).
Each new test was seen failing first (D1, D14 checked by stashing the fix; the others failed on
the missing function/clause before the code).

Focused batches (one app, explicit files, umbrella root, `MIX_QUIET` unset):

- 90 files matching Esc/Ctrl-L/V/R, notices, hints, pastes, drafts, editor context, capabilities:
  1,186 tests, 1 failure, the E-owned `settings/c74_editors_u3_test.exs:14` (Ctrl-L, above).
- 53 hint + settings files: 575 tests, the same single failure.
- 35 SessionRuntime/select-mode files: 317 tests, 0 failures after fixing `bindings_test`
  (D15) and keeping pass70's fold-open (D17).
- 34 picker/palette/dialog/keymap/pass7x files: 368, 0; 29 pass7x+keymap: 257, 0;
  17 panel files: 394, 0; 16 binding files: 367, 0 after D19's keymap_test update;
  5 queue/slash files: 131, 0 after composer_first/pass70_qa_clock updates.

D-owned tests changed to the contract's new behaviour: `bindings_test.exs` (D15 decline),
`keymap_test.exs` (D19 Ctrl-R), `composer_first_test.exs` (D10 Esc memory),
`pass70_qa_clock_test.exs` (D20 bare `/queue`), `pass72_overlay_keys_test.exs`,
`pass73_keys_test.exs`, `c75_reducer_panel_test.exs` (E5 `:auto`), `test/support/pass73_helpers.ex`
(`outcome/5` takes `:reason`). New support: `test/support/cli020_runtime.ex`,
`test/support/cli020_state.ex`.

§9.1 gates at the done commit:

- `mise exec -- mix format --check-formatted`: clean.
- `mise exec -- mix compile --warnings-as-errors --force`: 0 warnings.
- `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --check)`: matches.
- `scripts/dev/check_terminal_port.sh`: `cargo fmt --check` clean, `cargo test --locked` all
  ok (11 cli020 tests among them), 58 crate records / 108 licence texts verified.
- `python3 scripts/dev/test_terminal_port_pty.py`: 22 tests OK.
- `python3 scripts/dev/test_terminal_demo_pty.py`: 8 tests OK after the harness learned to skip
  OSC (the window title stopped its CSI-only parser; 5 failures before the fix).
  Other PTY harnesses (`test_live_session_pty.py` C, `test_saved_session_pty.py` B) may need the
  same OSC skip once D3's title reaches them.

Process note: two `mix test` runs started with an empty file list (a zsh glob in
`grep --include=*_test.exs` matched nothing), so they ran the whole umbrella suite without a
§4.4 slot; I killed both by pid (about 6 and 15 minutes in) and re-ran the intended focused files.
No other lane's process was touched. No real HOME, database, provider or `install.sh` was used.
