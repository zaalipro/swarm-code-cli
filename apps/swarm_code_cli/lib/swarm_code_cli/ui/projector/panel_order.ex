defmodule SwarmCodeCLI.UI.Projector.PanelOrder do
  @moduledoc """
  The side panel's visible entries in display order, after folding (pass72
  contract between owners P and O): `{:run, run_id}` for every run drawn and
  `{:agent, run_id, node_id, needs_you?}` for every agent drawn, plus the
  agents that need you in a folded run (the band still shows them). Hint
  labels (`UI.Hint.labels/1`) and the overlay's `[`/`]` walk this list.

  It reads the same rows the panel draws (`Panel.plan/3`), so an entry exists
  exactly when its row is on screen. With the panel hidden or in the narrow
  strip, the entries are the strip's: the run in chat and its agents.
  """
  alias SwarmCodeCLI.UI.Layout
  alias SwarmCodeCLI.UI.Projector.{Panel, Strip}

  @type entry :: {:run, binary()} | {:agent, binary(), binary(), boolean()}

  @spec entries(map()) :: [entry()]
  def entries(state) do
    layout = Layout.for_state(state)

    rows =
      cond do
        rect = Map.get(layout.rects, :inspector) -> Panel.plan(state, rect.width, rect.height)
        rect = Map.get(layout.rects, :tabline) -> Strip.plan(state, rect.width)
        true -> []
      end

    rows
    |> Enum.map(&elem(&1, 1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
