defmodule SwarmCodeCLI.UI.ScrollMetrics do
  @moduledoc "Pure, lazy logical text-line measurements using the same escaping and width policy as projection."
  alias SwarmCodeCLI.UI.Layout
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  def viewport(state, region) do
    layout = Layout.calculate(state.size, state.preferences)
    Map.get(layout.rects, region, layout.rects.main)
  end

  def content_height(state, :main) do
    rect = viewport(state, :main)
    SwarmCodeCLI.UI.Projector.Workspace.content_height(state, rect, Layout.classify(state.size))
  end

  def content_height(state, region), do: max(1, viewport(state, region).height)

  # The ids a region scrolls over, in drawn order. The main transcript is
  # painted in Workspace.Turns' view order (runs grouped, superseded runs left
  # out), which differs from the daemon's order when runs interleave, so line
  # scrolling walks that order (pass70 F, D's request).
  def order(state, :main, :workspace) do
    case Turns.view_order(state) do
      [] -> Map.get(state.read_model.order, :workspace, [])
      ids -> ids
    end
  end

  def order(state, _region, slot), do: Map.get(state.read_model.order, slot, [])

  # The shell run list has no region of its own any more, but the reducer still
  # keeps its cursor under `:navigator`; its rows are one line each.
  def height(_, :navigator, _), do: 1

  # The main transcript's rows come from one place, Workspace.Turns, so the
  # height an anchor counts is exactly the height the painter draws.
  def height(state, region, id), do: Turns.height(state, viewport(state, region).width, id)
end
