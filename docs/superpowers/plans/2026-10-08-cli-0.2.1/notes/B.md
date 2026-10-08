# Lane B notes (input and commands), branch `cli021/B` from CLI main `b6f8c79a`

Done: B1, B2, B3, B4. Parity items taken: none (P1 is lane C/M, P2 and P3 lane C, P4 lane U; the
brief says take S items whose lane is B; none are).

## B1: the effort picker's arrows (root cause)

Reproduced first: `ui/cli021/b1_effort_picker_test.exs` (two failures before the fix) and the PTY
test `LiveDemo.test_effort_picker_arrows_and_enter_change_the_status_line` (fails before, passes
after; the PTY test also proves Enter sets the row under the cursor and the status line shows it).

How the layer gets keys: `Keymap.Layers.key/3` takes ↑/↓ over `{:effort_picker, target}` and
returns `{:effort_move, ±1}`; `Reducer.EffortPicker.move/2` changes `state.selection["effort_picker"]`;
Enter reads that same selection (`EffortPicker.selected/2`). That half worked (the cli020 D18 tests
set the layer by hand and only looked at the selection). The dialog (`Projector.Dialog.effort_picker/3`)
drew its cursor from `state.focus`, which stays "composer" while the picker is open (the layer
is `own_focus_layer?`), so it fell back to the ticked/current row on every frame: the arrows moved
an invisible selection and Enter then picked a row the user could not see.

Fix (one hunk in a U-owned file, unavoidable, `projector/dialog.ex` `effort_picker/3`): the focused
row is `Enum.at(ids, selection["effort_picker"])`, falling back to the current row only when there
is no selection; "N of M" in the footer follows it. The queue list (fix round U5) already did the
same. No focus is written into the composer's `state.focus`.

## B2: worker words

- `core/commands.ex` (repinned, `provenance verify` and `sync --check` clean): builtins are
  `worker_effort` and `worker_model`; `swarm_effort` / `swarm_model` are hidden aliases
  (`Commands.aliases/0`): not in the catalogue, still parsed, the parse result names the worker
  command (`name: "worker_effort"`), a workflow/custom command that really has the old name wins.
- Client: `Keymap.local_command/1` takes `/worker_effort` and `/swarm_effort` (bare = the picker);
  the palette row, `EffortPicker.command/2` and `ModelPicker.command/3` send the new names;
  `ModelPicker.opener/1` takes both.
- Tests changed to the new names (core `commands_test`, `cli020_e_commands_test`, cli
  `e1_worker_words_test`, `e3_palette_rows_test`, `d18`, `d20`, `model_picker_test`) plus
  `cli021_b_commands_test.exs` for the aliases.

Hand-overs for B2:
- **U (status line, settings):** `projector/status.ex:191` still prints `"agents " <> swarm_model`
  (U2 changes it to `worker <model>`); `core/settings/registry/session.ex:75,89` carry
  `parity: "CLI /swarm_model"` / `"CLI /swarm_effort"` (now `/worker_model`, `/worker_effort`;
  regenerate `docs/settings.md` with `mix swarm_code.settings --write`; I did not touch the registry
  so I did not run that generator). Settings sentences that say "swarm"/"agents" for the slot.
- **C (dispatcher):** `daemon/service/command_dispatcher.ex:531` builds the bare `/swarm_effort`
  report with `"/swarm_effort"` ("`/swarm_effort <level>` sets it."); it should say
  `/worker_effort` (the test `c020_dispatcher_test.exs:231` pins the old text). Still works as is
  (the alias is accepted), it only reads old. The `:swarm_efforts` parse option and the wire's
  `swarm_effort(_levels)` / `swarm_model` DTO fields keep their names (wire, not words).

## B3: argument dropdown

`ui/slash_args.ex` (new, pure): the choices of a command's argument.
Static: `/panel` (auto, full, compact, hidden, summaries on, summaries off), `/diff` and `/mouse`
(on/off), `/theme` (dark, light, every `Theme.palettes/0`), `/approval` (read-only, auto, full),
`/ultra` (on/off). Dynamic, from data the client already holds: `/effort` and `/worker_effort`
(`EffortPicker.levels/2`, the daemon's levels for the model), `/model` and `/worker_model` (the
workspace snapshot's `models`, inserted as `provider_id|model`, found by prefix or by a part of the
model name), `/resume` (`state.conversations`, inserts the id). The current value says "(current)"
at the end of the row's description (ASCII-safe; U may draw a mark from `current?: true`).
Commands with free text have no list: `/goal /search /rename /export /queue /consensus /swarm /plan
/workflow /rewind` and so on. Not made: `/consensus` and `/rewind` scopes from the brief's list do
not exist as enumerations in the code (`/consensus [task]` is free text, `/rewind` takes no
argument), `/settings`, `/workflow <name>` and `/deep_research` need data the client does not hold.

`SlashPalette` (B-owned) now has an argument mode next to the command-name mode: when the draft is
one line `/<command> <typed>` with the caret at its end, `entries/1`, `visible/2`, `selected/1`,
`open?/1`, `move/2` return argument rows (`arg?: true`, `name: "panel full"`, `text: "panel full"`,
`command`, `value`, `current?`, `desc`) so the existing popup (`Projector.Composer.slash_popup/3`,
above the composer, same row layout, Enter/Tab hints on the selected row) draws them unchanged.
- Up/Down: the existing `{:move, dir}`. Tab: `{:complete_argument, text}` (the draft becomes
  `/<text>`, the list stays with that one row). Enter: `{:run_argument, text}` completes and sends
  the command (a local command like `/panel` runs locally, `/effort high` goes to the daemon),
  except when the draft already says one row exactly (`/panel hidden`), then Enter sends it as typed.
- Esc (`:dismiss_completion`, also `Composer.esc_action/1` so the status row says "Esc close"):
  closes the list only; it stays closed while the draft is still that command's arguments
  (`slash_palette: %{dismissed: {key, command}}`, kept by `SlashPalette.after_edit/1`, which
  replaced the blanket `slash_palette: nil` after an edit) and reopens after the draft leaves it.
- New actions `{:complete_argument, t}` and `{:run_argument, t}` (validated in `action.ex`; the
  reducer checks `t` is a row the list shows).
- Behaviour change to know: `/effort ` or `/approval ` with a trailing space now opens the list and
  Enter takes its first row; `/effort` without the space is unchanged (opens the picker), and Esc
  then Enter on `/effort ` gives the picker too.
- **U (drawing):** nothing needed; if U wants a different look, the rows carry `arg?`, `current?`
  and `value`; the popup is `projector/composer.ex slash_popup/3`.

## B4: command colour in the composer

`projector/composer.ex` (U's file, one hunk next to the workflow-keyword colouring): the first
token of a draft that starts `/<word>` is drawn in the accent, bold, when `SlashPalette.known?/1`
(client commands, core registry, the old worker names, `exit conversations config prefs`); any other
word is muted. Only when the draft's start is on screen (a scrolled long draft has no command row
visible). Arguments and later rows keep their colour; the editor, cursor and wrapping are untouched
(the rows are only split). A project's custom commands and workflows are the daemon's to know, so
they read as unknown (muted), not as errors. Monochrome terminals get the bold/not-bold cue.

## Fake (C's file, small)

`ui/data_source/fake/session.ex`: the demo session answers `/effort <level>` and
`/worker_effort <level>` (`effort` and `swarm_effort` on the session struct, in the metadata facts
and the workspace fields), so the demo's status line shows the effort; the PTY test needs it.

## Tests and gates run

- New: `ui/cli021/b1_effort_picker_test.exs` (4), `b3_arg_dropdown_test.exs` (15),
  `b4_command_highlight_test.exs` (7), core `cli021_b_commands_test.exs` (5); PTY
  `test_terminal_demo_pty.py` +2 tests (effort picker end to end, `/panel` dropdown + Esc + Enter).
- Watched failing first: B1 reducer/projector test (2 failures), B1 PTY (fails without the
  `dialog.ex` hunk), B3/B4 (before the code).
- Gates before `done`: see the final commit message and the orchestrator report (format,
  `compile --warnings-as-errors --force`, focused suites, `provenance.repin` of `commands.ex`,
  `provenance.verify`, `provenance.sync --check`, `keymap --check`, the demo PTY suite 10/10).
- Not run: `settings --write` (no registry entry touched), the live/saved PTY suites (the demo suite
  is the one closest to this change), a full `mix test` or `mix precommit` (integrator's slot).
- Known unrelated: `ui/cli020/d4_copy_test.exs` (pbcopy through the macOS clipboard) fails in this
  sandbox with and without these changes.

## AGENTS.md text for the integrator

- The worker slot's commands are `/worker_effort` and `/worker_model`; `/swarm_effort` and
  `/swarm_model` are hidden aliases (`SwarmCode.Commands.aliases/0`).
- `/<command> ` opens an argument dropdown (`UI.SlashArgs` lists the choices, `UI.SlashPalette`
  has the argument mode); the composer draws the command word (`SlashPalette.known?/1`).
