defmodule SwarmCodeCLI.UI.Reducer.EffortPicker do
  @moduledoc """
  cli020 D18 (ux-live-14, decision 4f): bare `/effort` and `/swarm_effort`
  open `{:effort_picker, :chat | :swarm}` whose rows are exactly the levels
  the daemon accepts for the model (workspace `effort_levels` /
  `swarm_effort_levels`, C17), the current one (`effort` / `swarm_effort`)
  ticked and nil shown as `default`. Enter sends `/effort <level>` (or
  `/swarm_effort <level>`) the way a typed command goes; Esc closes. The
  cursor is `state.selection["effort_picker"]`.
  """

  alias SwarmCodeCLI.UI.LayerSpec

  @doc "The levels the picker offers for `target`, from the workspace snapshot."
  @spec levels(map(), :chat | :swarm) :: [binary()]
  def levels(state, target) do
    field = if target == :chat, do: :effort_levels, else: :swarm_effort_levels

    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace ->
        workspace |> Map.get(field) |> List.wrap() |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  end

  @doc "The current level for `target` (nil = the default)."
  def current(state, target) do
    field = if target == :chat, do: :effort, else: :swarm_effort

    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace -> Map.get(workspace, field)
      _ -> nil
    end
  end

  @doc "The row under the cursor."
  def selected(state, target) do
    rows = levels(state, target)
    Enum.at(rows, min(Map.get(state.selection, "effort_picker", 0), max(length(rows) - 1, 0)))
  end

  @doc "Opens the picker on the current level."
  def open(state, target) do
    rows = levels(state, target)
    layer = {:effort_picker, target}

    cond do
      rows == [] ->
        {%{state | notice: {:command_feedback, "This model has no effort levels to pick."}}, []}

      not match?({:ok, _}, LayerSpec.validate(layer)) ->
        {%{
           state
           | notice: {:command_feedback, "The effort picker is not drawn in this build yet."}
         }, []}

      true ->
        at = Enum.find_index(rows, &(&1 == current(state, target))) || 0

        {%{
           state
           | layers: [layer | state.layers],
             selection: Map.put(state.selection, "effort_picker", at)
         }, []}
    end
  end

  @doc "↑/↓."
  def move(%{layers: [{:effort_picker, target} | _]} = state, delta) do
    last = max(length(levels(state, target)) - 1, 0)
    at = min(max(Map.get(state.selection, "effort_picker", 0) + delta, 0), last)
    {%{state | selection: Map.put(state.selection, "effort_picker", at)}, []}
  end

  def move(state, _delta), do: {state, []}

  @doc "The command Enter sends for `level`, or nil when the level is not offered."
  def command(%{layers: [{:effort_picker, target} | _]} = state, level) do
    if level in levels(state, target),
      do: if(target == :chat, do: "/effort ", else: "/swarm_effort ") <> level
  end

  def command(_state, _level), do: nil
end
