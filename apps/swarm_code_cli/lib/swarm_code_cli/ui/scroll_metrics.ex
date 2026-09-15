defmodule SwarmCodeCLI.UI.ScrollMetrics do
  @moduledoc "Pure, lazy logical text-line measurements using the same escaping and width policy as projection."
  alias SwarmCodeCLI.UI.{Layout, ReadModel, Transcript}

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

  def height(state, region, id) do
    case ReadModel.transcript_item(state.read_model, id) do
      nil ->
        1

      item ->
        run = Map.get(state.read_model.runs, item.run_id)
        kind = if run, do: run.kind, else: :chat
        Transcript.height(item, kind, viewport(state, region).width, state.capabilities) |> max(1)
    end
  end
end
