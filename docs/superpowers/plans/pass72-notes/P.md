# Pass 72 notes: owner P (the panel)

Branch `p72/P`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p72-P`.

## Contracts published

- `p72-P-order` (commit cbe2fd7): `SwarmCodeCLI.UI.Projector.PanelOrder.entries(state)` — the panel's
  drawn entries in display order after folding: `{:run, run_id}` and `{:agent, run_id, node_id, needs_you?}`.
  It reads the rows `Panel.plan/3` draws (so an entry exists exactly when its row is on screen), plus the
  needs-you agents of a folded run (the band still shows them). Under 120 columns it reads the strip
  (`Strip.plan/2`): the run in chat and its agents. Hidden panel: `[]`.
- `SwarmCodeCLI.UI.Layout.for_state(state)` = `calculate(state.size, state.preferences, Map.get(state, :panel_mode, :full))`.
  `Layout.calculate/3` takes the panel mode: from 120 columns `:full`/`:compact` dock a 46-column panel
  (`inspector_width` default 46, still clamped 38..56), `:hidden` gives main the width; under 120 columns a
  one-row `:tabline` rect (the strip, R17) sits under the title unless `:hidden`. `calculate/2` = `:full`.
- The panel reads O's state fields through `Map.get`: `panel_mode` (`:full | :compact | :hidden`), `hint`
  (`%{labels: %{label => target}}`; badges are drawn from the inverted map).

## Requests for others

(kept current below)

### For owner O (apply after the merge; exact changes)

1. Use the panel-aware layout everywhere the layout decides geometry (the strip under 120 columns moves main
   down one row, and `:hidden` gives main the width): replace `Layout.calculate(state.size, state.preferences)`
   with `Layout.for_state(state)` in `ui/scroll_metrics.ex:7`, `ui/reducer.ex` (lines ~1209, ~1300, ~1476,
   ~1868 at c50b289), `ui/keymap.ex` (~375, ~390) and `ui/keymap/special.ex:106`; in `keymap/special.ex:455`
   the piped form becomes `Layout.calculate(size, state.preferences, Map.get(state, :panel_mode, :full))`.
2. `Ctrl-B` no longer needs `medium_dock` (`reducer.ex:324` toggles it today): the panel mode cycle replaces it
   (P6); `medium_dock` stays in `Layout.Preferences` only so a saved session round-trips.
3. Tests that pin the old geometry (they are reducer/keymap tests, so O's):
   - `test/swarm_code_cli/ui/reducer_presentation_test.exs:79`: `inspector_width == 42` → `== 46` (the panel's
     default width, R13; `Preferences.reset(:inspector)` now resets to 46).
   - `test/swarm_code_cli/ui/reducer_navigation_test.exs:496-502`: the panel is 46 cells, so `107` → `103` in
     the three assertions (`inspector.rect.x - 1 == 103`, `main.rect == %Rect{x: 0, y: 1, width: 103, height: 34}`,
     `div(103 - main.rect.width, 2)`) and the comment's "42-cell inspector" → "46-cell panel".
   - `test/swarm_code_cli/ui/keymap_test.exs:238` ("[ and ] move inspector tabs"): from 120 columns the panel
     docks by default, so `undocked = Map.put(main(), :panel_mode, :hidden)` and `docked = main()` (after (1),
     since `Keymap` must read the panel mode).
4. Stopping one agent: the panel draws no controls (P1). `Workspace.keyboard_actions/2` now carries an undrawn
   `{:intent, {:stop_agent, run, agent, revision}}` for each agent of the run in view that allows it (the
   command-conformance truth table needs it); the overlay should offer "stop this agent" through it.
5. The panel's hint badges come from `state.hint.labels` (`label => target`, targets exactly as
   `PanelOrder.entries/1` returns them, including the `needs_you?` flag). The band shows the badge of the agent
   that asks; the footer spells the letter range and the digit range it finds in the labels.
6. The question dialog is 80 columns centred on the whole screen, so with the panel docked at 160 columns it
   covers the panel's first five columns (panel x = 114, dialog x = 40..119; seen in the real run,
   `/Users/zaali/.cache/p70cli/p72-P/real/r4.png`). It is modal, so nothing is corrupted, but centring it in
   `main` (`Layout.for_state(state).rects.main`) would keep the band readable while the dialog asks.

### For owner S

1. `RunSummary.reported` counts every ended sub-agent (a stopped swarm arrived as 4 of 4). The panel now counts
   only `:done` agents when the run is `:stopped`/`:failed`; if `reported` is meant to be "reported a result",
   count `:done` only on the wire as well.
2. A worker's report ends with the engine's notice `[Changes on branch swarm/… (N files changed, …)]` and
   `Delta patch captured: …`. The panel skips them when it falls back to the report; a wire `finding` would
   make the fallback unnecessary.
3. Real run 1 closed with "the daemon connection closed" 2m 31s into a four-worker swarm, with no error in
   `cli.log` (`source_unavailable` without a crash, so a consume timeout or closed subscriber). The panel at
   the time cost 83-203 ms a frame; after P5 (24-27 ms) two more real runs of ~20 min did not drop. If it
   recurs, the source's close reason should be logged.

## What landed

| commit | what |
|---|---|
| cbe2fd7 (tag `p72-P-order`) | P1: panel skeleton, strip, `Layout.for_state`, `PanelOrder.entries/1` |
| 8341a5b | P2: `Demo.Panel` scenes (the D2 data), the D9 transcript agent line: one row per agent, no spawn row, no isolation text |
| 2fc8ff8 | merge of `p72-S-wire` |
| cb7529d | P3: the S wire in the panel (panel_state, now, rolling lane, needs_you), verdict checks as criteria; `Inspector.Agents` removed |
| 1d6b638 | P4: undrawn `stop_agent` key actions, gallery panel scenes, short trust banner beside the panel |
| c766ea5 | P5: a stopped/failed swarm counts done agents and says "stopped before the merge"; a stopped agent drops its `now`; panel 83-203 ms → 24-27 ms a frame (one sanitise per segment, compiled pads, lazy candidates) |
| 80a9483 | P6: a worker's finding skips the engine's branch notice, reads the last three texts, joins "…is:" with what follows |

Owner bugs, each with a regression test in `test/swarm_code_cli/ui/projector/panel_test.exs`: content past the
edge (every row is exactly the pane width; nothing is painted past the last column), the stray ▐ column, the
"active" pill, names cut at 14 cells, duplicate spawn/lane rows (`workspace_turns_test`), "isolated in swarm/…".

## Screens

Demo / fake (render script `/Users/zaali/.cache/p70cli/p72-P/render.exs`, gallery via `mix swarm_code.demo.cells`):
- `/Users/zaali/.cache/p70cli/p72-P/shots/panel_swarm_2-160x45-truecolor-full.png` (D2 frame 2)
- `/Users/zaali/.cache/p70cli/p72-P/shots/panel_heavy-160x45-truecolor-compact.png` (D2 compact, five runs)

Real sandbox runs (deepseek-v4-pro, read-only, scratch `/Users/zaali/.cache/p70cli/p72-P/ailogic`, 3 real prompts):
- `real/r1b.png`: four workers thinking, the tree, lanes, `reported 0 of 4 · 4 working` (D2 frame 1 shape).
- `real/r2.png` → `real/r2-after.png`: before, a stopped swarm said "4 of 4 · the Lead is merging the findings";
  after, "0 of 4 · stopped before the merge".
- `real/r3.png`: a finished swarm, findings under each agent, "the Lead merged the findings" (D2 frame 3 shape);
  shows the branch-notice finding fixed in P6 (regression test on the exact report text).
- `real/r4.png` (question dialog over main) and `real/r5.png`: the needs-you band with the literal question,
  `^N answer`, the Lead's ▒ lane, "Lead is paused on you", "earlier in this chat" (D2 frame 2 shape).
All under `/Users/zaali/.cache/p70cli/p72-P/`. There is no pass-70 PNG: the "before" of the owner's bugs is the
owner's own screenshots (owner-notes.md).

## Left for later

- Hint mode in the strip under 120 columns: badges are inline before each name; D10's drop-down sheet is not drawn.
- The approval card's line "^N focuses this card · ^F <letter> opens the agent" (D9) is O's card.
- Consensus position rails, the goal iteration rail (no maximum on the wire) and research domains are drawn as
  text rows, not the D2 rails.
- `Inspector.Ops` / verdict helpers no longer reached from the agents tab could be removed in a later pass.
- The rest of the projector costs ~85 ms a frame on the heavy demo scene with the panel hidden (test env); the
  panel adds ~25 ms. Not measured against main.

## Verification

- Full umbrella `mix test` after deleting `_build/prod` (on 80a9483): core 146/0, daemon 969/0, cli 1583/3 (5
  properties). The three failures are exactly O's tests listed in "For owner O" item 3
  (`reducer_presentation_test` dock width 42→46, `keymap_test` `[`/`]` with the docked panel,
  `reducer_navigation_test` 107→103); they pass once O applies those edits.
- `panel_test.exs` 18/0 (goldens at 160x45, 120x36, 90x30, 80x24, NO_COLOR and ASCII; the owner's bugs and two
  real-run regressions), `golden_scenes_test`, `workspace_turns_test`, `inspector_cards_test`, `cells_test`.
- `mix format --check-formatted` clean. The full run showed three test-file warnings of mine (an unused alias,
  an orphaned `dock?/1` in `inspector_cards_test`, an unused default in `panel_test`), fixed in P8 and rerun
  (37/0); the remaining "redefining module …Migrations…" warnings come from the daemon tests and predate this pass.
