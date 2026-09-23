# pass70 owner D notes

Owner D: everything that is drawn. Branch `p70/D`, worktree
`/Users/zaali/dev/swarm-code-cli-wt/p70-D`. `p70-C-wire` merged (b5942da). E's branch is **not**
merged here; everything of E's is read with `Map.get` so it lights up when the finisher merges.

## Landed

| task | what | commits |
| --- | --- | --- |
| D2 | paint budget scales with the terminal (`Budget.node_limit/2`), `Demo.Conversation` fixtures, scene budget test at 250x70 on the 5-run and 7d01acff-shaped conversations | fc4b09c |
| D1 | conversation-shaped transcript (`Workspace.Turns` rewrite) | b235397 |
| D3 | `Projector.Markdown` + `Projector.Syntax`, code card with language chip | b235397 |
| D4 | one title/tab row, one status line, no deck rows, no ids, colour-only cues | b235397 |
| D5 | approval card above the draft, growing into main; modal fallback uses the same decisions | b235397, 1ef4482 |
| D6 | diffs in place, exit codes, background chip, stop/retry words per error kind, trust banner, rate-limit countdown, background command and daemon toasts on the status row, changes ledger with A/M/D and +N −M opening the diff, diff detail titled and coloured | 9d5648e |
| D7 | palette/picker visuals, `@path` popup and slash args, hive strip below the docking width, select-mode status, sentence case, line gauge, honest tab clock and dashboard live count, sub-agent names use free room | 5b249a8, 05265dc |
| D8 | golden scenes (every conversation scene × 160x45/120x36/90x30/80x24 × both width policies × colour/monochrome-ASCII), gallery +34 previews, companion reads the C1 facts | 05265dc |

## Contracts published

- `Projector.ApprovalCard` (new): `decisions/2` → `[{decision, key, words, target}]` with keys
  `y` `:approve`, `Y` `:approve_run`, `A` `:always_prefix` (or legacy `:always_allow`, worded
  "for this run" because C1 says the service reads it as approve_run), `d` `:deny`, `D`
  `:deny_stop`; `n` next is drawn only when more than one approval waits. Allowed set: the
  item's / approval's `allowed_decisions` when non-empty, else `allowed_actions`.
  `facts/1`, `title/2`, `layout/2` (`%{rows, growth, window: {first, shown, total}}`).
  The card never reads `Bindings.fetch(:approve)` (E's request): its keys are the fixed letters above.
- `Composer.slot_interaction/1`, `Composer.waiting_approvals/1` (opened layer first, E's
  `dismissed_interactions` `{id, expected_revision}` excluded), `Composer.opened_approval/1`,
  `Composer.approval_decisions/2` (delegates to ApprovalCard), `Composer.path_popup/3`.
- The opened `{:approval, id}` layer is **not a modal** when the layout has a composer: the card's
  keys are on the activity row right above the composer, the title/body/where grow into the bottom
  of main (≤ half of it), the draft stays visible. Focus ids `approve`, `approve_run`,
  `always_prefix`/`always_allow`, `deny`, `deny_stop` put that decision on the on-warn chip.
  Paging: `selection["dialog_scroll"]`; `Dialog.project/3` answers `Reducer.Pages.scroll_dialog`
  with the card's own window, so PgUp/PgDn/End page the card exactly.
- `Workspace.keyboard_actions/2`: everything that used to be a deck row (run controls, plan gate,
  interaction openers, the slot approval's decisions, "Full arguments", full-text openers, "Open
  diff" for the selected or newest edit with a `diff_ref`, seen, page retry/diagnostics) is in the
  action table without a drawn control; the palette lists them. The paint invariant is now
  "painted ⊆ table and table − painted ⊆ keyboard actions".
- `Workspace.Turns`: `order/1` is daemon order grouped by run (the old rank sort is gone; the
  companion keeps its own reading rank), `view_runs/1`, `view_order/1`, `context/2`, `rows/4`,
  `height/3` (0 for an item of a run out of view), `viewport/3`, `clock/1`, `duration_text/1`,
  `compact/1`, `margin/0` (2), `body_column/0` (4). A worker's lane expands by the id of the
  worker's first item. The selection rail/highlight shows only when `focus == "main"`.
  Tool rows: a non-zero `exit_code` makes the row failed and says `exit N`; `background: true`
  says `background`; a command's summary is its output's last line; an expanded edit whose text is
  a unified diff shows 12 hunk lines in the diff colours. A failed turn's card reads
  `run.error || run.stop_label`, then `retrying in Xs · provider` while `retry_at > now`, else a
  next step per `error_kind` (rate_limit, usage_limit, overloaded, unauthorized,
  context_overflow, network, timeout).
- Status row: `Status.waiting_count/1`; facts are ranked and dropped whole when short (mode 100,
  connection 95, waiting 90, rate limit 85, approval 70, trust 65, model 60, context 50,
  background 45, cost 40, agents 20); the hints give way only when the ≥85 facts do not fit.
  Reads E's read-model `rate_limits` (map by provider) over the shell snapshot's list,
  `background` (map) over the workspace snapshot's list, and the newest of `toasts` for 8 s.
  Select mode (`focus in ["main","inspector"]`, no layer) leads with `SELECT` and hints
  `j/k move · Enter open · y copy · Esc back` from the bindings `:move_next`, `:move_previous`,
  `:activate`, `:copy_selection` (E's, skipped until merged), `:escape`.
- `Projector.HiveStrip.block/2` (new): the composer edge row for a live multi-agent run when the
  inspector is not docked; `Hive.cell_role/2` is public for it.
- Dialog: picker rows (`switcher`, `model_picker`) carry decor in colour — title with the query's
  letters in the accent, detail dimmed (E's `Entry.title`/`detail`/`current?` via `Map.get`), kind
  or key right-aligned, provider headings (E's `first_in_group?`, else a provider change), the
  pickers are as tall as their rows, headings are not counted in "item N of M". A `{:detail, run,
  ref}` layer is titled from the ref's suffix (`:diff` → "Diff", `:reasoning`, `:arguments`, else
  "Full text", "· continued" past offset 0); diff text and the `{:library, :changes}` detail are
  coloured by line. Dialog frames use the ghost text colour.
- `Paint.Blocks`: a non-rich `:smooth` gauge paints as `▬▬▬▭▭` (`#---` in ASCII), not stripes.
- `Inspector.Changes.fit_path/3`: paths lose whole directories from the middle (`lib/…/repo.ex`).
- `Demo.Conversation.scenes/0` and the new `:trouble` scene; `Demo.Cells.file_count/0`.

## Contracts consumed

- C1 (`p70-C-wire`): `Approval.{command,cwd,reason,command_family,classification,agent_name,
  allowed_decisions,arguments_detail_ref}`, `WorkspaceSnapshot.{approval_mode,trusted,
  context_used,context_window,cost_usd,chat_model,swarm_model,project,background}`,
  `RunSummary.{stop_label,error_kind,provider_name,retry_at}`, `ToolCall.{added,removed,diff_ref,
  exit_code,background}`, `Change.{file_state,added,removed,diff_ref}`,
  `ShellSnapshot.rate_limits`, `RateLimit`, `BackgroundCommand`, `Toast`.
- E (read via `Map.get`, not merged here): `state.quit_live_runs`, `state.dismissed_interactions`,
  `state.path_completion` (`%{items, index, dismissed?}`), `read_model.rate_limits`,
  `read_model.background`, `read_model.toasts`, `Switcher.Entry.{title,detail,current?}`,
  model picker rows' `first_in_group?`, `SlashPalette` items' `args`, binding `:copy_selection`.

## Requests for other owners

- **E**: `Reducer.Pages.scroll/3` pages main over `order[:workspace]`; the view is
  `Turns.view_order/1` (grouped by run, superseded runs hidden, their items measure 0). Paging the
  view order instead would keep line scroll exact when runs interleave.
- **E**: `Switcher` labels on this base still read `Always_allow`, `inspector width balanced`, `Run
  demo-run-1`, `Conversation <id>`; the dialog sentence-cases what it draws, but the labels
  themselves (and the duplicate "Inspect run") are yours. `Entry.title`/`detail` are drawn as soon
  as they exist.
- **E / B (light mode, M11)**: not done. A light palette needs a `background: :dark | :light`
  capability. `UI.Action.valid_capabilities?/1` (E) pins `map_size(capabilities) == 18` and the
  exact key list, so D cannot add the field alone; B's probe would fill it from `COLORFGBG` / OSC 11
  and pass it into `Paint.Options`. With the field in place D adds the Carbon-light values
  (tokens in `~/dev/swarm-code` `assets/css/themes.css`, `html[data-theme="carbon"][data-mode="light"]`)
  as an override table in `Theme.style/2` and a `background` in `Paint.Options`/`Paint.Style.resolve`.
- **C**: the transcript text preview is 2048 bytes in snapshots; the answer is shown whole only via
  the detail. A larger preview (or the full answer for the newest run) would let the transcript
  show real answers without a detail round trip. Also: an edit's `ToolCall` text carrying its
  unified diff (or the first hunks) lets the expanded row show it without a `diff_ref` round trip.
- **B**: `⬤` (U+2B24, the tab status dot) is missing from common terminal fonts' coverage in the
  PNG renderer; worth checking in ghostty/iTerm2 during the B smoke.

## Manifest-listed files edited

None (every edited path checked against `provenance/extracted-files.json` destinations).

## Verification

- `mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli` after each step; last run before
  this note: 5 properties, 1301 tests, 0 failures (05265dc).
- New tests: `ui/projector/signals_test.exs` (15, D6), `ui/projector/pickers_test.exs` (7),
  `ui/projector/swarm_chrome_test.exs` (5), `ui/projector/golden_scenes_test.exs` (64: 8 scenes ×
  4 sizes × 2 policies, each in colour and monochrome ASCII), ledger/companion additions.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` clean.
- PNGs rendered through `Paint` → SVG → PNG and read while iterating, in
  `/private/tmp/p70cli/p70-D/shots/`: before-{first_reply,approval,swarm}.png (main before pass
  70); v5/v6 (approval card), v7/v7x-trouble-120x40 (D6), v8pal/v8mp (palette, model picker),
  v8hive-swarm-110x34 (strip), v8sel (select mode), v8insp-swarm-160x45 (inspector);
  after-{first_reply,approval,swarm,trouble}-{160x45,120x36,90x30,80x24}.png.
- Not done: a real TUI session in GNU screen (no real prompts spent by D); the PNG path paints the
  same `Plan` the port encodes, but glyph coverage in a real terminal font was not checked.

## Left

- Light mode (see the E/B request above).
- ASCII mode still prints `·` and `…` as punctuation (pre-existing `Width.elide/4` and separators);
  the golden test allows exactly those two.
- The model picker's `in use` and heading rows are drawn only in colour; monochrome keeps the old
  `✓ model  provider` label.
- Performance: `Paint.ProjectorTest` takes ~16 s and `Turns.context/2` is O(n) per height; the E
  paging request above would let the projector measure only the view.
