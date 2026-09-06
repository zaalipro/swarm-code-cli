defmodule SwarmCodeCLI.UI.Projector do
  @moduledoc "Pure renderer-neutral projection. Source permissions remain behind opaque action IDs."
  alias SwarmCodeCLI.UI.{ActionTarget, Layout, SafeText, Scene, State}
  alias SwarmCodeCLI.UI.Scene.Region
  alias SwarmCodeCLI.UI.Projector.{Density, Dialog, Shell, Support}
  @spec project(State.t()) :: {Scene.t(), %{binary() => ActionTarget.t()}}
  def project(state) do
    layout = Layout.calculate(state.size, state.preferences)

    scene = %Scene{
      size: state.size,
      revision: state.revision,
      ambiguous_width: state.capabilities.ambiguous_width,
      layout_class: layout.class
    }

    if layout.class == :too_small do
      tiny(state, scene, layout)
    else
      {regions, cursor} = Shell.project(state, layout)

      {scene, background} =
        Support.finalize(%{scene | regions: regions, cursor: cursor}, state.revision)

      overlay = Dialog.project(state, layout.class, background)
      # While a modal owns focus its background actions are not activatable.
      if overlay do
        {overlay, table} = Support.finalize(overlay, state.revision)
        regions = Enum.map(scene.regions, &clear_actions/1)
        {%{scene | regions: regions, overlay: overlay, cursor: nil}, table}
      else
        {scene, background}
      end
    end
  end

  defp tiny(state, scene, layout) do
    dirty =
      case state.layers do
        [{:unsent_changes, _} | _] -> true
        _ -> false
      end

    lines =
      if dirty,
        do: ["UNSENT CHANGES", "Esc CANCEL", "X CONFIRM EXIT"],
        else: [
          "SIZE #{state.size.columns}x#{state.size.rows} NEED 50x14",
          "? HELP",
          "q DETACH",
          "P EXIT; RERUN --plain"
        ]

    blocks =
      lines
      |> Enum.take(state.size.rows)
      |> Enum.map(fn line ->
        %Scene.Block.Text{text: Density.clip(line, state, state.size.columns)}
      end)

    region = %Region{
      id: "main",
      role: :main,
      rect: layout.rects.main,
      label: SafeText.chrome(:empty),
      blocks: blocks
    }

    {%{scene | regions: [region]}, %{}}
  end

  defp clear_actions(%{__struct__: module} = value) do
    values =
      value
      |> Map.from_struct()
      |> Enum.map(fn {key, v} ->
        {key, if(key == :action_id, do: nil, else: clear_actions(v))}
      end)

    struct(module, values)
  end

  defp clear_actions(value) when is_list(value), do: Enum.map(value, &clear_actions/1)
  defp clear_actions(value), do: value
end
