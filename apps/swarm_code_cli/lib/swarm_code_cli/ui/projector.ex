defmodule SwarmCodeCLI.UI.Projector do
  @moduledoc "Pure renderer-neutral projection. Source permissions remain behind opaque action IDs."
  alias SwarmCodeCLI.UI.{ActionTarget, Layout, SafeText, Scene, State}
  alias SwarmCodeCLI.UI.Scene.Region
  alias SwarmCodeCLI.UI.Projector.{Composer, Density, Dialog, Shell, Support, Workspace}
  @spec project(State.t()) :: {Scene.t(), %{binary() => ActionTarget.t()}}
  def project(state) do
    layout = Layout.for_state(state)

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

      {regions, cursor} =
        case SwarmCodeCLI.UI.Projector.Overlay.project(state, layout) do
          nil -> {regions, cursor}
          covered -> covered
        end

      {scene, background} =
        Support.finalize(%{scene | regions: regions, cursor: cursor}, state.revision)

      # The actions the keys reach without a drawn control (see
      # `Workspace.keyboard_actions/2`) join the background table under their
      # own path, so their ids never collide with a drawn block's.
      {_hidden, keyboard} =
        Support.finalize(
          %{keyboard: Workspace.keyboard_actions(state, layout.class)},
          state.revision
        )

      background = Map.merge(keyboard, background)

      # An approval opened as the top layer is drawn in the composer slot, so
      # the conversation stays in view; only a layout with no composer falls
      # back to the modal card.
      overlay =
        if Map.has_key?(layout.rects, :composer) and Composer.opened_approval(state),
          do: nil,
          else: Dialog.project(state, layout.class, background)

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
