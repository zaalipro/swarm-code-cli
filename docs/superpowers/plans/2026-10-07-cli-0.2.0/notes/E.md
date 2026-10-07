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

### E20 Resume rows
- `Switcher.Entry` gains `right` and `subline`. A conversation entry: its detail is runs/live/
  waiting; `right` is the age (`2 h ago`, `Switcher.ago/2` words) or `open`; `subline` is C19's
  `last_prompt` (first line; `Map.get`). `Dialog` draws `right` at the right edge (a long title is
  elided to keep it while ≥ 16 cells of title remain) and the subline as its own dim row
  (`decor_spans(%{subline: …})`), not counted as an item.
- Tests updated: `pass70_qa_picker_row_test` (`11 runs  open │`), `conversations_test` (the label
  no longer ends `· open`; the entry's `right` is `open`). New `cli020/e20_resume_rows_test.exs`.
  ui + demo dirs 2438/0.

### E21 Syntax
- `Projector.Syntax.lines/2` carries `{:comment | :string, close}` from line to line of a fence
  (`/* */` in js/rust/go/c/cpp/java/sql/css, `<!-- -->` in html; triple quotes in python/elixir/toml,
  backticks in js/go); `line/2` is the same tokenizer with no carry. Comments, quotes and
  multi-line delimiters are tables per language; keyword tables for go, c, cpp, java, ruby, sql
  (case-insensitive), yaml, toml, css, html (tags with their bracket are keywords); YAML/CSS keys
  before `:` and TOML keys before `=` are `:type`. `@line_bytes` unchanged (a long line inside a
  comment stays one `:comment` token and keeps the carry).
- Test `cli020/e21_syntax_test.exs` (17); paint + projector dirs (goldens included) 527/0.

### E22 Schedules note
- `Dialog` library contents: for `:schedules` the first row is `Scheduled tasks fire only while the
  ncode app is running. Run now works here.` (not focusable), with the list, the detail and a save's
  message after it, so it shows again after Save. Test `cli020/e22_schedules_note_test.exs`.

### E23 Contrast
- `Theme`: dark `text_faint` `0x868583` (4.77:1 surface, 4.52:1 card), `text_ghost` `0x6A6967`
  (3.21/3.04). 256 colours: faint `245` (4.94:1 on 234; deviation: the same index as muted, the
  grey ramp has no step between `244` = 4.32:1 and `245`), ghost `242` (3.25:1). ANSI-16 faint
  `:white`. Carbon light twins: faint `0x72706C` (4.70/4.94 on `0xFAF9F7`/`0xFFFFFF`), ghost
  `0x8A8883` (3.37/3.54); index twins `245→242`, `242→244`. `disabled` keeps `0x5E5D5A` (not in
  the contract).
- High contrast: `Theme.put_high_contrast/1` + `high_contrast?/0` (`:persistent_term`, like the
  accent): faint and ghost draw as muted, bold. `terminal.colors` gains `high_contrast` ("high
  contrast"). **Handoff B** (`release/terminal_preferences.ex:166`): map `"high_contrast"` to the
  probed colour mode (today it falls to the `_ ->` probe already) and call
  `Theme.put_high_contrast(true)` at launch (beside `put_accent`).
- Tests: `cli020/e23_contrast_test.exs` (computes WCAG for dark and light); `theme_test` row values
  updated. `docs/settings.md` regenerated: unchanged (the table lists no choices). ui + cli020 +
  demo 2557/0; core settings 40/0.

### E24 Settings detail scrolls
- `Settings.Layer` gains `detail_scroll`; `i` resets it. With the detail open, the verbs
  `:page_up`/`:page_down` (bound today) and `:half_page_up`/`:half_page_down` move it by a page
  (`rows - 8`) or half; the reducer clamps with `Projector.Settings.Note.detail_max_scroll/1` (a
  pure function of the state). The page shows `↑ N lines above` first when scrolled and keeps
  `↓ N lines below` last.
- **Handoff D** (`keymap/settings_bindings.ex`), binding rows to add:
  `{:settings_half_page_down, [{"d", [:control]}], :half_page_down, [:settings], "Half page down", "Half a page down in the open detail (i)", 0, false},`
  and `{:settings_half_page_up, [{"u", [:control]}], :half_page_up, [:settings], "Half page up", "Half a page up in the open detail (i)", 0, false},`
  (the 8-field shape of `:settings_page_down`, `settings_bindings.ex:47`; the reducer ignores the
  verbs while no detail is open).
- Test `cli020/e24_settings_detail_scroll_test.exs`; `c75_note_test` green.

### E25 Research levels
- The research form's levels read `Fastest · about a minute`, `Standard`, `Deep`, `Ultra`
  (`Dialog.research_level/1`); the option ids and `{:research_depth, atom}` are unchanged. Test
  `cli020/e25_research_levels_test.exs`; `research_form_test`, `bindings_test` green.

### E26 New terminal settings
- Registry (`core/settings/registry/terminal.ex`): `terminal.mouse` default `false` with the
  contract's description; new `terminal.notify` (enum auto|bell|osc9|os|off, default auto, group
  "notices"), `terminal.title` (toggle, on), `terminal.paste_collapse_lines` (0..200, 8),
  `terminal.exit_transcript` (0..20, 3, next launch), all on the Layout page; `terminal.wheel_lines`
  reads `Lines per wheel notch.` and `keys_input.ex` no longer disables its row (the `wheel on/off`
  words default to off). `terminal.panel` per E5.
- `Init.Preferences`: `defaults/0`/`legacy/1` gain `notify`, `title?`, `paste_collapse_lines`,
  `wheel_lines`, `notice_seconds`, `hint_letters` (checked by `Settings.Validate.hint_letters/1`),
  `reduced_motion?`, `exit_transcript`, each bounded as the registry and falling back alone; they are
  writable through `write/2` (`@keys`). `mouse?` defaults to `false`.
- Counts: registry 174 → 178, scalar keys 134 → 138, cli entries 21 → 25 (`c74_registry_test`,
  the Layout key list). `docs/settings.md` regenerated (+5 rows).
- Tests updated for the mouse default and the wider map: `pass72_preferences`,
  `pass73_preferences`, `pass73_mouse` (B's `start_preferences/3` now yields `mouse?: false` from
  the defaults; no B change needed), `c74_preferences`, `c74_keys_layout_startup` (the wheel row stays
  editable). New `cli020/e26_terminal_settings_test.exs`. Deviation: that test was written before
  the code but first run after it (green at once). Runs: core 208 (3 count failures, fixed, 11/11
  re-run), CLI ui + cli020 + c74 + release 2573 with 5 (the tests above, fixed, 39/39 re-run).
- **Handoff D**: read the new `Preferences` fields into `State` (D3 notify/title, D5 mouse default,
  D8 `paste_collapse_lines`, D13 wheel/notice/hints/reduced motion); **handoff B**: pass them
  through `start_preferences/3` like `mouse?`; B21 reads `exit_transcript` via `CliFile`.

### E27 The desktop's themes
- `Theme.palettes/0` (carbon aurora dusk ember fjord graphite obsidian paper), `palette_value/3`,
  `palette_entry/4`; `@palettes` maps each Carbon dark value to the palette's dark and light value,
  token by token from `~/dev/swarm-code/assets/css/themes.css` (read-only): `--bg-elev` surface,
  `--bg-card` card, `--bg-hover`, `--popover-bg`, `--border`, `--bar-track` (CLI ticks track),
  `--text`, `--text-muted`, `--text-faint` (faint, ghost, disabled), `--accent`, `--on-accent`,
  `--ok`, `--warn`, `--err`, `--info`; `page` = `--bg` (the light canvas). Aurora's rgba surfaces
  are composited over its `--bg`; graphite's striped track is its stripe colour; obsidian, graphite
  and aurora have `--text-faint: var(--text-muted)`, so faint = ghost = muted there. Generator:
  `~/.cache/ncode/cli020/E/tools/palettes.py` (scratch, not committed).
- `Paint.Options` gains `palette: :carbon` (6 fields, validated against the eight); `Paint.build`
  substitutes through `palette_entry/4` (truecolor by value, 256 colours by nearest index of the
  palette's accent/status values; grey ramp keeps Carbon's indices; 16 colours and monochrome are
  the terminal's own and unchanged).
- Registry `terminal.palette` (enum of the eight, default carbon, `{:cli, "palette"}`, at once);
  `Preferences` `palette` (fixed map, no atoms from input). Counts 178 → 179, scalar 138 → 139,
  cli entries 25 → 26; `docs/settings.md` +1 row. Slash palette `/theme` args list the names.
- **Contrast floor changes** (E23's 4.5 faint / 3.0 ghost on surface and card; faint raised toward
  `--text`, ghost — the desktop has none — from its faint): carbon dark 5E5D5A → 868583 / 6A6967
  (E23); carbon light 96948F → 72706C / 8A8883 (E23); dusk dark 6A5F80 → 8C829E / 6F6585; dusk
  light 9B92B0 → 756D89 / 948BA8; ember dark 6B6157 → 8D847A / 70675D; ember light A3968A →
  7B6F65 / 9B8E82; fjord dark 5F7385 → 7B8C9C / 5F7385; fjord light 8EA1B2 → 637382 / 8092A2;
  paper dark 6F655A → 91877C / 746A5F; paper light A0958A → 7B7168 / 9A8F84. Aurora, graphite,
  obsidian: no change (their faint is muted, ≥ 4.9:1).
- Deviation: the Carbon accent tint (0x3E291D, accent chip backgrounds) has no desktop token and
  keeps its value under every palette. Settings page arrows (`projector/settings/page.ex`) now keep
  whole names (the extra Appearance row made `↓ …` clip a name mid-word at 80x24, failing
  `c75_twin_test`); `c75_chrome_search_test` counts 3 `/theme` matches in Appearance.
- **Handoff D**: `/theme <palette>` in `keymap.ex` (`command?(trimmed, "/theme")`) sets
  `terminal.palette`; `dark|light` keeps setting the mode. **Handoff B/D**: pass the
  `Preferences.palette` into the renderer owner's `%Paint.Options{palette: …}`
  (`renderer/ratatui_port/owner.ex:526`, not E's file) — until then every palette paints Carbon.
- Tests: `cli020/e27_palettes_test.exs` (21: a contrast test per palette and mode, values, paint
  substitution, options, preference + registry). Runs: core settings + commands 76/0; CLI ui +
  cli020 + demo + c74 2 failures (above, fixed), settings re-run 524/0.

### E28 Status line items
- Registry `terminal.status_items` (Layout page, group "status line", `:checklist` of mode approval
  model effort branch ctx cost waiting, default all but branch, `{:cli, "status_items"}`, at once).
  Counts 179 → 180, scalar 139 → 140, cli entries 26 → 27; `docs/settings.md` +1 row.
- `projector/status.ex` `facts/2`: the listed items in the listed order, read from
  `state.prefs["status_items"]` (json names, as `diff_lines` is); an unknown or repeated name means
  the default. The effort is its own item now (the default still reads `model · effort`). Companions
  keep today's places: trust after approval, the agents' model after the model, background work
  after the cost (each still drawn when its item is not listed); provider, rate limit and connection
  are always drawn. Narrow classes leave out branch, ctx and cost, as before for ctx/cost.
- `branch`: `⎇ <git_branch> +<git_dirty>` (no `+` at 0; ASCII `br:`), STUB read with `Map.get` from
  the workspace snapshot until C22 lands `git_branch`/`git_dirty`.
- Tests: `cli020/e28_status_items_test.exs` (6). Runs: core settings 40/0; CLI ui + cli020 + demo +
  c74 2606/0.

### E29 Plan section
- New `projector/panel/plan_section.ex` (`Panel.PlanSection`): `steps/1` reads the run's `plan`
  (STUB `Map.get` until C23's `RunSummary.plan` lands; items `%{text, status}` with atom or string
  keys, statuses `done`/`in_progress`/`pending` as F11's `update_plan`, anything else pending, the
  first line of a text), `counter/1` (`Plan 3/7`, done over all), `rows/2` (the counter bold, at
  most 7 steps `✓`/`▸`/`·`, ASCII `+ > .`, then `… N more`), `strip_part/1`.
- `panel.ex` full body: the plan of the run in chat between the found blocks and the agents;
  compact: the counter row under the run in chat. `strip.ex`: `Plan 3/7` after the needs-you part.
  `:auto` already counts a plan (E5's `auto_shown?/1`).
- Tests: `cli020/e29_plan_section_test.exs` (6). Run: CLI ui + cli020 + demo 2599/0.

### E30 Hooks and rules in Settings
- `ui/settings/sections/project_file.ex`: `@events` gains F9's `stop`, `notification`,
  `user_prompt_submit`, `pre_compact`, `session_end` (with picker hints), so their hooks are rows of
  the existing hooks table (`event · matcher · command · timeout`, still editable as pass74 made it,
  and `a` can add them once C23 widens the service's `@events`). New read-only block
  `permission rules` (hint `Edit .swarm_code/config.json; ncode reads it for trusted projects
  only.`) with `rule:allow`, `rule:ask`, `rule:deny` info rows (`a · b` or `none`).
- STUB: the rules are read from the `project_config` record's `permissions` field (`%{allow, ask,
  deny}`); **handoff C**: add `"permissions"` to the record fields in
  `service/settings/project_config.ex` `record/1` (or the finisher points `rules/1` at C23's
  `project_config.summary`).
- Deviation: hooks stay the pass74 editable table rather than a new read-only `event · command`
  list (it already shows both; a read-only copy would duplicate it).
- Tests: `cli020/e30_hooks_rules_test.exs` (3). Run: CLI settings + E30 527/0.

### E31 Markdown rows cached
- Locked fixture first: `UI.Fixtures.long_conversation/3` (200 messages, user and assistant in turn,
  every answer a heading, list, task item, Elixir code block, table and quote; deterministic).
  Bench `scripts/dev/bench_markdown.exs` (`cd apps/swarm_code_cli && mise exec -- mix run
  --no-start ../../scripts/dev/bench_markdown.exs`): 160x50 truecolor, 40 frames, median frame,
  reductions per frame, post-GC process memory, cache entries/bytes, warm == cold scene.
- **Before** (the change stashed; three runs): median 5.25 / 5.17 / 4.85 ms per frame, 681 127 /
  677 090 / 681 096 reductions per frame, post-GC process memory 602 392 bytes.
- **After** (three runs, final code): cold (empty cache) 5.20 / 4.98 / 5.67 ms, 681 200 / 681 309 /
  681 203 reductions — the same as before (the per-frame collection costs nothing measurable); warm
  3.98 / 4.41 / 4.20 ms, 644 581 / 644 599 / 644 606 reductions (−5.4 % reductions, about −20 %
  time; the wall times are noisy on a loaded machine, the reductions are stable); post-GC process
  memory 602 392 bytes in both; 2 Markdown blocks computed per cold frame and 0 warm (the window at
  160x50 shows two answers); the cache holds 2 entries, 7 890 bytes (external term size); warm
  scene == cold scene in every run. Query/process counts: the projection makes no queries and
  starts no process, before and after (the bench runs with `--no-start`: no Repo or application
  is up).
- `projector/markdown_rows.ex` (`Projector.MarkdownRows`): key `{sha256(text), inner, ambiguous
  policy, glyph tier, ascii?}`; `rows/3` reads `state.markdown_cache` (`%{entries: map, bytes: n}`,
  read with `Map.get`; STUB until D21 adds the field), else this frame's computed map, else computes
  `Markdown.rows/4` and reports it. `turns.ex` `prose_rows/4` goes through it (the only change
  there). New `Projector.project_reporting/1` → `{scene, table, markdown_rows}` wraps the frame in
  `MarkdownRows.collect/1`; `project/1` is it without the third element.
- Deviation: the computed entries are collected in the projecting process's dictionary for the
  length of one `project/1` call (removed in an `after`, so on a raise too; a nested projection
  leaves collecting to the outer one), instead of threading an accumulator through every
  projector function; the scene and table stay functions of the state. A frame that draws the
  same text twice computes it once.
- Deviation (contract says `table.markdown_rows`): the report is a third element, not a key of the
  action table. Putting `:markdown_rows` in the table broke 19 projector tests that check every
  table entry is `binary id => target` (`ui/paint/projector_test.exs`, `ui/projector_test.exs`,
  `ui/projector_runs_dashboard_test.exs`), and `Keymap.activate/3` scans the table's values.
- **Handoff D (D21)**: `session_runtime.ex:1012` — call `Projector.project_reporting(state.ui)`
  instead of `project/1`, merge the third element into `state.ui.markdown_cache` (`%{entries: map,
  bytes: n}`, ≤ 4 MiB by `:erlang.external_size/1`, LRU), and clear it on a conversation switch.
- Run: the CLI app suite (`apps/swarm_code_cli/test`) 2833/0.
- Tests: `cli020/e31_markdown_cache_test.exs` (7: golden empty/warm/half-evicted at 160x120,
  100x40, 80x24; table equal apart from the report; key inputs; an ASCII entry never drawn on a
  rich frame; the collection cleared on a raise). Deviation: written after the module (it needs
  the report to exist); green at first run.
