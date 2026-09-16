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

  # The shell run list has no region of its own any more, but the reducer still
  # keeps its cursor under `:navigator`; its rows are one line each.
  def height(_, :navigator, _), do: 1

  # The main transcript's rows come from one place, Workspace.Turns, so the
  # height an anchor counts is exactly the height the painter draws.
  def height(state, region, id), do: Turns.height(state, viewport(state, region).width, id)
end
