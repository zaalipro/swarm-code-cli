defmodule SwarmCodeCLI.UI.Cli022.X1EffortDefaultTest do
  @moduledoc """
  cli022 F2: the effort pickers always offer a `default` row; picking it sends
  `/effort default` (`/worker_effort default`), which clears the conversation's
  value so it follows the global default. The row is ticked while no effort is
  set and names the level in effect when the daemon reports it.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.Cli020EHelpers
  alias SwarmCodeCLI.UI.{Input, Keymap, Projector, Reducer}
  alias SwarmCodeCLI.UI.Reducer.EffortPicker

  defp leveled(fields \\ []) do
    state = ready()

    workspace =
      Map.merge(
        state.read_model.snapshots.workspace,
        Map.new(
          [
            effort_levels: ~w(low medium high),
            effort: "high",
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

  defp sent(effects),
    do: for(%{kind: {:dispatch, :send, text, :main, []}} <- requests(effects), do: text)

  test "the rows always start with default, whether or not an effort is set" do
    assert EffortPicker.rows(leveled(), :chat) == ~w(default low medium high)
    assert EffortPicker.rows(leveled(effort: nil), :chat) == ~w(default low medium high)
    assert EffortPicker.rows(leveled(), :swarm) == ~w(default low high)
    assert EffortPicker.rows(leveled(effort_levels: []), :chat) == []
  end

  test "with a level set the cursor opens on it and default is one Up-arrow row away" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :chat}})
    assert focused(state) == "effort-high"
    state = state |> arrow(:up) |> arrow(:up) |> arrow(:up)
    assert focused(state) == "effort-default"
  end

  test "Enter on default sends /effort default while a level is set" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :chat}})
    state = state |> arrow(:up) |> arrow(:up) |> arrow(:up)
    {closed, effects} = Reducer.update(state, {:effort_pick, EffortPicker.selected(state, :chat)})
    assert sent(effects) == ["/effort default"]
    assert closed.layers == []
  end

  test "the worker picker sends /worker_effort default after a level" do
    state = leveled(swarm_effort: "high")
    {state, []} = Reducer.update(state, {:slash_local, {:effort, :swarm}})
    assert focused(state) == "effort-high"
    {_closed, effects} = Reducer.update(state, {:effort_pick, "default"})
    assert sent(effects) == ["/worker_effort default"]
  end

  test "default is the ticked row while nothing is set, and picking it only closes" do
    {state, []} = Reducer.update(leveled(effort: nil), {:slash_local, {:effort, :chat}})
    assert focused(state) == "effort-default"
    {closed, effects} = Reducer.update(state, {:effort_pick, "default"})
    assert sent(effects) == []
    assert closed.layers == []
  end

  test "the default row says which level is in effect when the daemon reports it" do
    state = leveled(effort: nil, effective_effort: "medium")
    {state, []} = Reducer.update(state, {:slash_local, {:effort, :chat}})
    text = Cli020EHelpers.screen_text(state)
    assert text =~ ~r/default · medium/
    # a pinned level is ticked "in use" and default shows nothing
    pinned = leveled(effort: "high", effective_effort: "high")
    {pinned, []} = Reducer.update(pinned, {:slash_local, {:effort, :chat}})
    refute Cli020EHelpers.screen_text(pinned) =~ "default ·"
  end

  test "EffortPicker.effective reads the daemon's field, nil when it sends none" do
    assert EffortPicker.effective(leveled(effective_effort: "max"), :chat) == "max"
    assert EffortPicker.effective(leveled(effective_swarm_effort: "low"), :swarm) == "low"
    assert EffortPicker.effective(leveled(), :chat) == nil
  end
end
