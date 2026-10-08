defmodule SwarmCodeCLI.UI.Reducer.EffortPicker do
  @moduledoc """
  cli020 D18 (ux-live-14, decision 4f): bare `/effort` and `/worker_effort`
  open `{:effort_picker, :chat | :swarm}` whose rows are exactly the levels
  the daemon accepts for the model (workspace `effort_levels` /
  `swarm_effort_levels`, C17), the current one (`effort` / `swarm_effort`)
  ticked and nil shown as `default`. Enter sends `/effort <level>` (or
  `/worker_effort <level>`) the way a typed command goes; Esc closes. The
  cursor is `state.selection["effort_picker"]`.

  cli022 F2: the `default` row is always there. Picking it while a level is
  set sends `/effort default` (`/worker_effort default`), which clears the
  conversation's value so it follows the global default; while nothing is set
  it only closes the picker. `effective/2` is the level in effect (the
  daemon's F4 fact), shown beside the ticked `default` row.
  """

  alias SwarmCodeCLI.UI.Reducer.Remote

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

  @doc """
  The rows the picker draws: `default` first (cli022 F2: always, so a level can
  be given back to the global default), then the daemon's levels.
  """
  @spec rows(map(), :chat | :swarm) :: [binary()]
  def rows(state, target) do
    case levels(state, target) do
      [] -> []
      levels -> ["default" | levels]
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

  @doc """
  The level in effect for `target`: the conversation's value, else the
  environment's, else the global default (cli022 F4, the workspace's
  `effective_effort` / `effective_swarm_effort`); nil while the daemon does
  not say.
  """
  @spec effective(map(), :chat | :swarm) :: binary() | nil
  def effective(state, target) do
    field = if target == :chat, do: :effective_effort, else: :effective_swarm_effort

    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace ->
        case Map.get(workspace, field) do
          level when is_binary(level) and level != "" -> level
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "The row under the cursor."
  def selected(state, target) do
    rows = rows(state, target)
    Enum.at(rows, min(Map.get(state.selection, "effort_picker", 0), max(length(rows) - 1, 0)))
  end

  @doc "Opens the picker on the current level."
  def open(state, target) do
    rows = rows(state, target)
    layer = {:effort_picker, target}

    cond do
      rows == [] ->
        {%{state | notice: {:command_feedback, "This model has no effort levels to pick."}}, []}

      not Remote.drawable?(layer) ->
        {%{
           state
           | notice: {:command_feedback, "The effort picker is not drawn in this build yet."}
         }, []}

      true ->
        at = Enum.find_index(rows, &(&1 == (current(state, target) || "default"))) || 0

        {%{
           state
           | layers: [layer | state.layers],
             selection: Map.put(state.selection, "effort_picker", at)
         }, []}
    end
  end

  @doc "↑/↓."
  def move(%{layers: [{:effort_picker, target} | _]} = state, delta) do
    last = max(length(rows(state, target)) - 1, 0)
    at = min(max(Map.get(state.selection, "effort_picker", 0) + delta, 0), last)
    {%{state | selection: Map.put(state.selection, "effort_picker", at)}, []}
  end

  def move(state, _delta), do: {state, []}

  @doc "The command Enter sends for `level`, or nil when the level is not offered."
  def command(%{layers: [{:effort_picker, target} | _]} = state, level) do
    if level == "default" or level in levels(state, target),
      do: if(target == :chat, do: "/effort ", else: "/worker_effort ") <> level
  end

  def command(_state, _level), do: nil
end
