# Lane E notes (cli020, CLI 0.2.0)

Branch `cli020/E` from M1 `3008f352`, worktree `~/dev/swarm-code-cli-wt/cli020-E`.

## Per task

### E1 Worker and Validator words
- Labels only; keys unchanged. Every `sub-agent model/effort` string in `apps/*/lib` is gone
  (`cli020/e1_worker_words_test.exs` greps all three apps).
- New entries `models.validator`, `efforts.validator`, `session.validator_model` (registry 171 →
  174, scalar keys 131 → 134; `c74_registry_test` updated). `applies: :desktop` (only the ncode
  app's missions read them).
- Deviation/handoff: `efforts.validator` uses `dynamic_choices: {:effort_of, :validator_default}`.
  The daemon's `Settings.Values` (`@global_models`, C's file) has no `validator_default` key yet,
  so it falls back to the chat default model (which is the validator's null meaning, "the main
  model"). For exact levels of a set validator model, C or the finisher adds
  `validator_default: {:default_validator_provider_id, :default_validator_model, :chat}` to
  `@global_models` in `dmn/daemon/service/settings/values.ex`.
- `core/commands.ex` repinned.

### E2 Honest Ultra
- `commands.ex` mode hint and `/ultra` description per the contract; the status chip says
  `Ultra · workflows` (`Projector.Composer.mode_title/2`); the help sheet ends with a `Modes`
  section from `Commands.modes/0` (Ultra as `Ultra · workflows`). The composer label and the
  welcome keep `Ultra`. `Dialog.help_lines/2` is public (`@doc false`) for the tests.

### E3 Command registry additions
- `core/commands.ex`: `/rename <title>` (`:rename_conversation`, `%{title}`; empty →
  `missing_argument`, control characters → `invalid_argument`), `/delete`
  (`:delete_conversation`), `/fork` (`:fork_conversation`), `/undo` (`:undo_turn`); bare
  `/effort`/`/swarm_effort` → `:show_effort` `%{target: :chat | :swarm}`; reworded `/rewind`,
  `/consensus`, `/quit`. Small extra: the effort args hint is now `[low|medium|high|max]` (the
  argument is optional now). Repinned.
- C's dispatcher must handle `:rename_conversation`, `:delete_conversation`,
  `:fork_conversation`, `:undo_turn`, `:show_effort` (§3); until C lands they reach its fallback.
- `slash_palette.ex` `@local`: `queue` (`<text> | clear | drop N`), `rewind`, `undo`, `delete`,
  `effort`, `swarm_effort`. Deviation (smallest change that keeps the intent): the rows of core
  commands (`rewind undo delete effort swarm_effort`) keep the catalogue's position (`@in_place`)
  with the local words, instead of moving to the top with the other local rows, so `/sw` still
  selects `/swarm` (the existing `slash_palette_test` pins that).
- Tests: `swarm_code_core/test/swarm_code/cli020_e_commands_test.exs`,
  `cli020/e3_palette_rows_test.exs`; `commands_test.exs` updated (builtin list, bare
  `/swarm_effort`). The ui test directory: 2419 tests, 0 failures.

### E4 Effort is visible
- Status chip: `<model> · <effort>` from the workspace DTO `effort`.
- `LayerSpec` validates the five §8.3 layers (`{:effort_picker, scope}`, `{:rewind, …}`,
  `{:rewind_confirm, turn}`, `{:history_search, …}`, `{:queue_list}`) so D's `Action` can open them.
- `Dialog` draws `{:effort_picker, :chat | :swarm}` as a picker (`Effort · chat model` /
  `Effort · workers`), the rows from `effort_levels` / `swarm_effort_levels` (C17), else the five
  classic levels; the current one ticked and focused when the focus is not on a row.
- STUB: `Dialog.effort_target/1` gives a row the `{:local, {:effort_pick, level}}` target only
  once D18 adds `{:effort_pick, level}` to `Action.validate/1` (until then rows have no target).
  The finisher may drop the guard after D merges; `e4_effort_test` covers both branches.

### E5 Side panel auto
- `Preferences`: `"auto" => :auto`, default `:auto` (defaults, a missing/unknown `panel`);
  registry `terminal.panel` choices `auto, full, compact, hidden`, default `auto`.
- `Projector.Panel.effective_mode/1` (`:auto` → `:full` when `auto_shown?/1`, else `:hidden`),
  `auto_shown?/1` (≥ 2 agents of the visible runs in `read_model.agents`, a pending approval or
  question, a run's `needs_you`, or a run with a `plan` (E29)), `cycle_order/0` = the order E gives
  D for Ctrl-B: `[:auto, :full, :compact, :hidden]`. `Layout.for_state/1` lays out the effective
  mode (strip below 120 columns as before); a bare `Layout.calculate(…, :auto)` is hidden.
- The chat run's subtitle is `chat · 2k` (no `in chat` for a chat run; other kinds keep it).
- For D (not done here, D's files): add `:auto` to `State.panel_mode` default/type
  (`state.ex:66`), to `Reducer.init`'s guard (`reducer.ex:69`, today it raises on `:auto`: until
  D lands, a launch whose cli.json has no `panel` would get `:auto` from `Preferences.read/1` and
  fail the guard; the finisher must merge D with E), to `next_panel/1` (`reducer.ex:3326`) in
  `Panel.cycle_order/0`'s order, and to `Action.validate({:panel_mode, …})` (`action.ex:328`) and
  the switcher rows (`switcher.ex:72-75` are E's: an `auto` row can be added once D's action
  accepts it).
- Tests updated for the new default: `c74_commit_test`, `c74_undo_test`, `c74_search_test`,
  `c74_safety_test`, `pass72_preferences_test`, `golden_scenes_test` (`chat · `).

### E6 Palette selection always visible
- Cause (verified by a failing test): with the focus in the query (a fresh Ctrl-P) no row id
  equals the focus, so the window kept the stale `dialog_scroll` offset of an earlier dialog.
  `Dialog.modal/3` now anchors a picker's window on the selected entry (the one the footer
  counts) when the focus is on no row. The keymap half of ux-live-1 (Up on row 0, typing while a
  row has focus) is D15's.
- Test `cli020/e6_palette_visible_test.exs` (offsets 0/5/15/40 → window at 0; first and last of
  ≥ 24 entries visible). Also moved E4's picker below an unrelated comment it had split.

### E7 Help sheet
- Cause of the `g…` rows and the blank row after every entry (X18, now VERIFIED): the lines were
  built at the dialog's inner width but every option row is indented by a 2-cell rail in colour,
  so each padded line overflowed by 2 cells and the modal soft-wrapped it.
  `Dialog.help_geometry/2` is the text width (inner − 2 in colour, inner in monochrome, where
  help rows carry no prefix); the test asserts it equals the painted text width.
- Help longer than its cell word-wraps (`Prose.wrap/3`) onto continuation rows under the help
  column; two-column pairs are padded row by row. Session first (after Vim in vim modes), with
  Ctrl-C, Esc first; bindings whose every spelling needs Alt are dropped (`help_sheet_test`'s
  "every binding once" now skips those). The sheet ends with `Modes` (E2) and `Commands` (the
  `/` list's rows, `/name args  description`).
- "Opens at the top" is the reducer's (D): `reducer.ex:2045` deletes `dialog_scroll` only for
  approvals and command reports when a layer opens; add `:help` there (D's file, handoff).

### E8 Slash list
- `Composer.slash_popup/3`: descriptions start in one column (the widest `/name args` of every
  match, capped at 2/5 of the row; a longer signature elides its args), elided with `…` via
  `Width.elide`; a top rule `─── 8 of 40 · ↑↓` (ASCII `- … up/down`) while some matches are
  not shown. `Workspace.slash_rows/4` keeps the popup inside its rows (one suggestion gives way to
  the rule when the room is exact). Test `cli020/e8_slash_list_test.exs`.
