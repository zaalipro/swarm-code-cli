# pass71 owner V notes

Owner V: visuals. Branch `p71/V`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p71-V`, from main
`6e8dad1`. S's and I's branches are **not** merged here; S5's `queued` is read with `Map.get`.

## Landed

| task | what | commits |
| --- | --- | --- |
| V1 (R3) thin rails | `Support.rail/1` / paint `rail_glyph/1`: `▏` at the rich tier, a one-cell gap at the measured tier (every one-cell-under-both-policies thin bar, `⎸ ⏐ ❘`, is missing from Menlo / SF Mono / MesloLGS), `▐` kept only in monochrome where no surface carries the cue, `|` in ASCII. Used by the prompt card, the selection rail, the active tab, surfaces and run cards, dialog/palette/@path selections, the approval card; the composer gutter is `▏` at rich and keeps its stripe below (its only focus cue). New SafeText tokens `:rail` (rich, measured twin `:rail_gap`), `:rail_gap`, `:rail_ascii`. | 3ef959e |
| V1 (R3) compact side pane | `Inspector.Agents.compact?/2`: a `:chat`/`:goal` run with no sub-agents shows a run card (glyph + name, status dot + word, model, `elapsed · tokens · cost · files` two per row, the error of a failed turn, `stop` when allowed) then the Changes ledger (`Changes.tab/4`); never Current task / Operations. The first tab is labelled `run` then. Swarms, workflows and a chat that spawned sub-agents keep the hive. "No files changed" (no "yet") once the run is finished. | b7a8f6f, 1ebc947 |
| V2 (R4) code card | the fence's header row is the language as a chip (`:code_lang` on the hover surface), `y copy` right-aligned in select mode (`focus == "main"`, no layer); one blank card row closes the card. `Turns.style_of/3` keeps a chip's own background on a card. | 91dcde0 |
| V3 (R5) inline hunk | every edit row shows its first hunk (the `@@` line plus body, at most 12 lines) without expanding; longer diffs end `… N more lines · Enter opens`. Source: `ToolCall.hunk` (see request S-1) else the item's text when it is a unified diff. `+N −M` counted from a whole diff when the daemon sent none. | bb7b1bb |
| V4 (R6) light | `Paint.Options.theme :: :dark \| :light` (default dark; `validate/1` now 5 keys); `Paint.build` swaps the palette through `Theme.light_entry/2` (Carbon light tokens from `themes.css`, dark value → light twin, 256-colour indices too; the canvas becomes `--bg #f4f3f1` / `--text #1a1a1a` so a dark terminal shows the light theme; ANSI-16 and monochrome unchanged). `Theme.mode(env, settings_mode)` decides: `SWARM_THEME` wins, then the desktop's settings `mode`, then dark. **Not wired to a live session yet** (request I-2/S-2). | 301cebf |
| V5 | sentence case: help-sheet group headings (`Vim`, `Navigate`…), request outcomes (`Rejected`, `Needs input`, `Deadline exceeded`…), `Status.notice/2`; `{:run_inspector, run, :changes}` as a dialog lists the run's files (`A/M/D path +N −M`, Enter opens the diff or the checkpoints), falling back to the conversation's changes, titled `Changes · N files` (the reducer part is request I-1); `N queued` on the composer rule (warning, bold) from `snapshots.workspace.queued` (S5, `Map.get`, 0 hides it). | 7fed411 |
| V6 | gallery +9 (`conversation-{first-reply,trouble,swarm}-{160x45,120x36}-truecolor-rich`, `light-{first-reply,trouble,approval}-160x45-truecolor-rich`), 66 files; golden scenes: pass71 evidence at 160x45 (run tab, facts, Changes, code chip, inline `@@`, no `Operations ·` on one-agent turns, the hive on a swarm). | 1ebc947 |

## Contracts published

- `Projector.Support.rail/1` → SafeText; `Inspector.Agents.compact?/2` (state, run).
- `Markdown.rows/4`: a code block's first row carries `header: true`; the last row is a blank card row.
- Consumed, not yet on the wire: `ToolCall.hunk :: binary | nil` (a unified-diff fragment starting at
  its first `@@`, ideally only the first hunk, ≤ 13 lines) and `ToolCall.diff_lines :: count` (body
  lines of the whole diff, headers excluded), both read with `Map.get`.
- `Paint.Options.theme`, `Theme.mode/2`, `Theme.light_entry/2`, `Theme.light/3`.
- `Composer.queued/1` (reads `snapshots.workspace.queued`).

## Requests for other owners

- **I-1 (reducer, `/diff` below the docking width)**: `Reducer.show_feedback(state, :navigate,
  %{feature: :changes}, _)` sets the inspector tab, which does nothing when the layout has no
  inspector rect. When `Layout.calculate(state.size, state.preferences).rects` has no `:inspector`,
  open `{:run_inspector, run_id, :changes}` instead (run id = the current run, `Projector.Support.run(state)`,
  else the newest run of the conversation). V draws that layer as the changes dialog (7fed411).
- **I-2 / S-2 (light mode wiring)**: `renderer/ratatui_port/owner.ex` `frame/3` builds `%Options{}`
  from caps; add `theme: <mode>` where mode = `Theme.mode(System.get_env("SWARM_THEME"),
  desktop_settings_mode)` decided once by the launcher (the desktop keeps it in the `settings`
  row's `mode` column, default "dark"; the daemon could put it on `ShellSnapshot`). Capabilities
  was not extended because `Action.valid_capabilities?/1` pins its 18 keys.
- **S-1 (inline hunks for real edits)**: the persisted backend's `tool_call/2` has `added`/`removed`/
  `diff_ref` for a finished edit but not its text; add `"hunk"` (first hunk of the op's diff, ≤ 13
  lines, from the same `change_diff` work S2 moved to supervised jobs) and `"diff_lines"`, and the
  DTO fields (`{:optional, {:text, 4096}}`, `:count`). Until then only a transcript item whose text
  is a unified diff shows its hunk (the demo, and any backend that sends the diff as the result).
- The run-palette focus stripe (`run_palette.ex` `stripe/2`) still uses `▐`/`▐` in colour: it is a
  selection column, not a rail; left as is.

## Manifest-listed files edited

None (all edits under `apps/swarm_code_cli/lib/swarm_code_cli/{ui,demo}` and tests).

## Verification

- Focused suites after each step (`test/swarm_code_cli/ui`, `demo`): see the commits; the whole
  `apps/swarm_code_cli/test` ran green after V5 except the two tests fixed in 7fed411.
- New tests: `projector/code_card_test.exs` (2), `projector/pass71_chrome_test.exs` (4),
  `paint/light_theme_test.exs` (5), signals_test (+3 inline hunk), inspector_cards_test (+2, one
  rewritten), new_blocks_test (+1 rail tiers), golden_scenes_test (+6), cells_test (+light/rich).
- PNGs (Paint → SVG → PNG, `/private/tmp/p70cli/p71-V/shots/`):
  - before: `before-first_reply-160x45.png`, `before-trouble-160x45.png`, `before-swarm-160x45.png`,
    `before-first_reply-90x30.png`, `before-trouble-120x36.png`
  - after: `rails-first_reply-160x45-rich.png` (thin rails), `v1-trouble-160x45-rich.png`,
    `v1-approval-160x45-rich.png` (compact card), `v2-first_reply-160x45-rich.png` (code card, select
    mode), `v3-trouble-160x45-rich.png` (inline hunk), `v4-trouble-160x45-rich-light.png`,
    `v4-approval-120x36-measured-light.png`, `v5-trouble-90x30-measured.png` (changes dialog),
    `v5q-first_reply-120x36-measured.png` (2 queued), `gallery-*.png` (from the cell gallery).
