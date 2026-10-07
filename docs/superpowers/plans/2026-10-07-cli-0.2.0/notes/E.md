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

### E9 Rows for retry, search and stash
- `Switcher`: an entry can be `pinned?` (sorts before every other match); the newest run's
  `Retry failed run` is pinned when that run is failed or stopped. Note: C's resolver
  (`request_resolver.ex` `retry_not_failed?/2`) and the DTO schema (`:retry` only while
  `:failed`) offer the row for failed runs only today; a stopped run's row is pinned once C6
  lets it through.
- STUB: `Stash draft` / `Restore stash` (`{:local, {:stash_draft}}`, `{:local, {:restore_stash}}`)
  are listed only once D19 adds those actions to `Action.validate/1`.
- `/search` hits: interface for C8/D — the reducer keeps C8's `{:select, %{subject: :search,
  options}}` as `state.search_results = %{query, options: [%{conversation_id, title, snippet,
  at}]}` and opens the palette with the query `?`; the switcher lists the hits (kind `:search`,
  prefix `?`, title "Search results: <words>") with Enter = `{:local, {:open_conversation, id}}`.
  Today's client `Feedback` DTO has no `:select` kind (C's), so nothing sets the field yet.
- The failure hint says `r retries · Ctrl-P Retry failed run` (`Turns.next_step_text/2`).

### E10 The Lead's report once
- X14 VERIFIED (with one correction): a done swarm writes a `swarm` message with the Lead's text
  (`domain/engine/run_server.ex` ~4470), `PersistedBackend.message_role/1` maps `"swarm"` to an
  assistant item, and `represented_answer_query/0` only folds the root node into an `assistant`
  message, so the client gets the Lead agent item, its last llm step and the report item. The
  Lead's answer + step decomposition showed the text once; the report item drew it again.
- `Turns.context/2` gathers `repeats` (assistant text items, not the answer, whose trimmed text
  the answer or a step already shows) and `lead_rows/4` draws nothing for them (0 rows, so
  `Turns.height/3` agrees). A report with other words ("Swarm stopped by user.") still draws.
  The panel's "reported" fact is unchanged. Test `cli020/e10_report_once_test.exs`.

### E11 `/agents` and `/workflows`
- Client side only (C9 changes the daemon's data): `Library.detail_text/2` reads a workflow's
  detail as its description plus one argument line (`query (required) · angles=4 · sources=6`,
  required first, then by name) from the JSON object at the end of the detail (today's raw
  `{"meta": …}` or C9's `{"description", "args": […]}`, decoded with OTP's `:json`, no new
  dependency), never the JSON itself; one Start (an item with a form drops its bare `:start`).
- `Dialog`: library and command-report bodies word-wrap (`Prose.wrap/3`), a library detail is one
  row per line; a report's Markdown entries `- **name** (source) — description` (today's `/agents`)
  draw as a two-column list (no asterisks). If C9 sends `/agents` as structured rows over a new DTO,
  the drawing of those rows is still to wire (no DTO for it exists in this branch).
- Test `cli020/e11_agents_workflows_test.exs`.

### E12 Turn header words
- Cause of `thinking ▮` over streamed words (VERIFIED by a failing test): `decompose/2` gives the
  streaming answer's words to its newest step, leaving the residual empty; the header now says
  `writing` once the streaming answer has any words.
- `retrying 2/5 · HTTP 500` from `RunSummary.retry_detail` (C5; read with `Map.get`, so it is
  inert until C adds the field; the test puts it on the run). Without the field a `:retrying`
  run still says `retrying`.
- A failed run's per-agent error item draws nothing when it says what the failure block says
  (`failure_repeat?/2`); `econnrefused` reads `Cannot connect to the provider (connection
  refused).` in both places (`Turns.humane_error/1`) and the hint is `is the provider running?
  · r retries · Ctrl-P Retry failed run` (not "connection dropped").
- Test helper `item/2` moved to `test/support/cli020_e_helpers.ex`. Test
  `cli020/e12_turn_header_test.exs`; projector/paint/demo tests 586/0.

### E13 Worker changes, user-facing
- `Turns.worker_report/2` strips the engine's trailing note (`run_server.ex` `report_with_note/5`:
  `[Changes on branch <b> (<stat>). Integrate them …]` / `[No file changes.]`) and returns the
  dim row: `+N −M in K files` from the agent's `changes_stat` (git shortstat words or `+N −M`),
  else from the note's own stat, or `no file changes`. Used where a worker's report is drawn in the
  transcript (expanded lane, stopped swarm's report rows). Stored text unchanged. The panel's
  finding already drops the note (`panel_facts.ex` `without_engine_notes/1`).
- Test `cli020/e13_worker_changes_test.exs` (unit level; the transcript path is the existing
  `prose_rows` call sites switched to `report_rows/5`).

### E14 Read-only approval card
- `ApprovalCard.facts/1` gains `read_only?` from `Map.get(approval, :approval_mode)` (C adds the
  DTO field per §8.2; **stub-free but inert** until then: the test puts the key on the struct).
  Read-only: title `! Ask · <tool>` (also `ApprovalCard.title/2`), the `D` chip reads
  `deny and stop`; the keys row was already limited to the offered decisions (A'2 sends
  `[:approve, :deny, :deny_stop]`).
- Deviation: the diff is built with `List.myers_difference/2` over each edit's old/new lines
  (`- `/`+ `/context), because `UI.UnifiedDiff` only parses git's diff text. 12 lines, then
  `… N more`; `write_file` shows the first 12 lines of `content`; the card's line limit for a
  read-only file ask is path + 12 + the count (other cards keep 6). Keys keep the card's chip
  layout (`y  once     d  deny     D  deny and stop`), not literal ` · ` separators.
- Test `cli020/e14_read_only_card_test.exs`; projector/paint/approval tests 586/0.

### E15 Drawing the new features
- Composer rule (`Projector.Composer.hairline/2`): after two cells of rule, `$ shell` (accent,
  bold) while the draft starts with `!` and the rest is not blank (D7's rule, computed here from
  the draft text: `Composer.shell_draft?/1`; **handoff D**: if D exposes `shell?` differently, swap
  the predicate), then one `[Image #N · 412 KB]` chip per `draft.attachments` entry; the queued
  label keeps its place at the right. The chips are on the hairline only: when the workflow hint or
  the hive strip takes the edge row they are not drawn (deviation; noted for review).
- Paste placeholders `[Pasted text #N · L lines]` are drawn `:text_faint` as one span; cursor
  skipping is D8's editor.
- Transcript `kind: :shell` (C15; the DTO enum gains `:shell` in C, so tests put it with
  `struct!`/`Map.put`): its own block, no turn header: `$ <command>` with `exit 0` muted, `exit N`
  error, `stopped` warning, `running… ▮` accent; output through the usual `preview/6` (its
  detail_ref "N more" line). The text `"$ cmd\noutput\n[exit N]"` is parsed; the item's `exit` wins.
- Layers (`Dialog.contents/4`): `{:rewind, …}` rows `Turn 7 · <prompt> · 3 files · 2 h ago`
  (`Switcher.ago/2` words, which read `2 h ago`), empty `Nothing to rewind yet.`;
  `{:rewind_confirm, turn}` with `b/c/f` rows and the fold sentence (word-wrapped);
  `{:history_search, …}` query row + matches + `No earlier prompt matches.`; `{:queue_list}` from
  `queued_texts` numbered, `Nothing queued.`. **STUB** `rewind_target/1`: `{:rewind_choose, scope}`
  targets appear only once D10's action validates.
- Gallery: `Demo.Cli020` (8 scenes) wired into `Demo.Cells` at 120x36 rich (`cli020-*.svg`);
  `cells_test` count +8.
- Tests: `cli020/e15_drawing_test.exs` (12); ui + cli020 + demo dirs 2509 tests, 1 failure (the
  cells count, fixed and re-run green).

### E16 Dialogs sized to content
- `Dialog.modal/3`: `message_layer?/1` (`:unsent_changes`, `:confirm_intent`, `:command_report`):
  no chooser count line, the controls on one `Block.ActionDeck` row, the box as tall as its rows
  (centred), at every class but `:compressed_small`.
- Quit with live runs: `Enter/X quit` and `Esc cancel` on one row. **Handoff D**: `reducer.ex`
  `exit_requested/3` opens the layer with `focus: "cancel"`, so Enter cancels today; for
  "Enter quits" D must open it with `focus: "confirm"` (the projector draws the focus it is given).
- `/cost`: a report with C18's `rows` draws `model  12k in · 3k out  $0.04` aligned plus `Total`
  (C18's `total` when sent, else the sum; no price `—`); without `rows` the text as before.
- Empty states: Checkpoints `No checkpoints yet: they are taken before each edit.`; the runs
  dashboard `Nothing has run yet: send a message, or /swarm <task>.`; (E15's rewind/queue/history
  empties).
- Desktop open (C4): a persistent warning row at the top of main (beside the trust banner) from
  `state.desktop_running` or the workspace's `desktop_running`. Deviation: drawn in main's banner
  slot, not the one-line status bar (the sentence does not fit beside the status items at 80).
- Test `cli020/e16_dialog_sizes_test.exs` (80x24); ui + cli020 + demo 2514/0.

### E17 Run palette states
- `RunPalette.row/3`: done/failed/stopped/interrupted/superseded rows drop the gauge; a glyph
  `✓`/`✕`/`■` (ASCII `+`/`x`/`#`, success/error/muted) and the words column widened by the gauge's
  cells (columns stay aligned). Test `cli020/e17_run_palette_test.exs`.

### E18 Task lists
- `Projector.Markdown` `block_rows({:item, …})`: a bullet item starting `[ ] `/`[x] `/`[X] ` draws
  `☐`/`☑` (bullet style) in place of the bullet; ASCII keeps the brackets. The hang is the measured
  marker width (`Width.cells/2` under the policy). Test `cli020/e18_task_list_test.exs` (both
  policies).

### E19 Background command row
- `Turns.tool_rows/4`: an item's `background_state` (C10, read with `Map.get`) replaces the
  `exit code pending …` summary and the `background` word, with a mark from it (`exit 0` done,
  `exit N` failed, `killed…` stopped, `still running` keeps the clock). Test
  `cli020/e19_background_row_test.exs` (the field is put on the read model after DTO validation,
  which refuses it until C10 lands).
