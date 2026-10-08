defmodule SwarmCodeCLI.UI.Cli021.B1EffortPickerTest do
  @moduledoc """
  cli021 B1 (owner report 1: "modal opens but arrow buttons does nothing"). The
  reducer moved `selection["effort_picker"]` but the dialog drew its cursor on
  the ticked (current) row whatever the selection said, so the arrows looked
  dead. The cursor is the selection now, like the queue list's.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap, Projector, Reducer}

  defp leveled(fields \\ []) do
    state = ready()

    workspace =
      Map.merge(
        state.read_model.snapshots.workspace,
        Map.new(
          [
            effort_levels: ~w(low medium high),
            effort: "medium",
            swarm_effort_levels: ~w(low high),
            swarm_effort: nil
          ] ++ fields
        )
      )

    %{
      state
      | read_model: %{
          state.read_model
          | snapshots: Map.put(state.read_model.snapshots, :workspace, workspace)
        }
    }
  end

  defp focused(state), do: Projector.Dialog.project(state, :wide).focused_control_id

  defp arrow(state, code) do
    {:ok, action} = Keymap.resolve(Input.key(code), state, %{})
    {state, _effects} = Reducer.update(state, action)
    state
  end

  test "the dialog's cursor starts on the current level" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :chat}})
    assert focused(state) == "effort-medium"
  end

  test "the arrows move the drawn cursor, not only the selection" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :chat}})
    state = arrow(state, :down)
    assert focused(state) == "effort-high"
    state = arrow(state, :up) |> arrow(:up)
    assert focused(state) == "effort-low"
    assert arrow(state, :up) |> focused() == "effort-low"
  end

  test "the worker picker starts on its default row and walks the levels" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :swarm}})
    assert focused(state) == "effort-default"
    assert state |> arrow(:down) |> focused() == "effort-low"
  end

  test "the typing composer keeps its focus while the picker is open" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :chat}})
    focus = state.focus
    assert arrow(state, :down).focus == focus
  end
end
