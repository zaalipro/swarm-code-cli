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
