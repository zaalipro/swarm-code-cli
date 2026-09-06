defmodule SwarmCodeCLI.UI.ScrollMetrics do
  @moduledoc "Pure, lazy logical text-line measurements using the same escaping and width policy as projection."
  alias SwarmCodeCLI.UI.{Layout, ReadModel, SafeText, Width}

  def viewport(state, region) do
    layout = Layout.calculate(state.size, state.preferences)
    Map.get(layout.rects, region, layout.rects.main)
  end

  def content_height(state, :navigator), do: max(1, viewport(state, :navigator).height - 1)

  def content_height(state, :main) do
    rect = viewport(state, :main)
    SwarmCodeCLI.UI.Projector.Workspace.content_height(state, rect, Layout.classify(state.size))
  end

  def content_height(state, region), do: max(1, viewport(state, region).height)

  def height(_, :navigator, _), do: 1

  def height(state, region, id) do
    case ReadModel.transcript_item(state.read_model, id) do
      nil ->
        1

      item ->
        limits = %{
          SafeText.Limits.content()
          | ambiguous_width: state.capabilities.ambiguous_width
        }

        text =
          case SafeText.external(item.text, limits) do
            {:ok, text} -> text
            {:error, _} -> SafeText.chrome(:text_limit)
          end

        width = max(1, viewport(state, region).width)

        text
        |> SafeText.value()
        |> Width.wrap(width, state.capabilities.ambiguous_width)
        |> length()
        |> max(1)
    end
  end
end
