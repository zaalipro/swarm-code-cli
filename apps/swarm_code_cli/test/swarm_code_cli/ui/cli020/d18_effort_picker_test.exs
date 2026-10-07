defmodule SwarmCodeCLI.UI.Cli020.D18EffortPickerTest do
  @moduledoc "cli020 D18 (ux-live-14, decision 4f): the effort picker layer."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer}
  alias SwarmCodeCLI.UI.Reducer.EffortPicker

  # C17's workspace fields, put on the snapshot the way the DTO will carry them.
  defp with_levels(state, fields) do
    workspace =
      Enum.reduce(fields, state.read_model.snapshots.workspace, fn {k, v}, w ->
        Map.put(w, k, v)
      end)

    model = %{
      state.read_model
      | snapshots: Map.put(state.read_model.snapshots, :workspace, workspace)
    }

    %{state | read_model: model}
  end

  defp leveled,
    do:
      with_levels(ready(),
        effort_levels: ~w(low medium high),
        effort: "medium",
        swarm_effort_levels: ~w(low high),
        swarm_effort: nil
      )

  test "bare /effort and /swarm_effort are local; with a level they go to the daemon" do
    assert Keymap.local_command("/effort") == {:effort, :chat}
    assert Keymap.local_command("/swarm_effort") == {:effort, :swarm}
    assert Keymap.local_command("/effort high") == nil
    assert {:ok, {:slash_local, {:effort, :chat}}} = Keymap.draft_send(type(ready(), "/effort"))
  end

  test "the rows are the daemon's levels, the cursor on the current one" do
    state = leveled()
    assert EffortPicker.levels(state, :chat) == ~w(low medium high)
    assert EffortPicker.levels(state, :swarm) == ~w(low high)
    {opened, []} = Reducer.update(state, {:slash_local, {:effort, :chat}})

    assert [{:effort_picker, :chat} | _] = opened.layers
    assert opened.selection["effort_picker"] == 1
  end

  test "no levels says so" do
    {state, []} = Reducer.update(ready(), {:slash_local, {:effort, :chat}})
    assert state.notice == {:command_feedback, "This model has no effort levels to pick."}
  end

  test "↑/↓ move, Enter sends /effort <level> and keeps the draft" do
    state = leveled() |> type("half")

    state = %{
      state
      | layers: [{:effort_picker, :chat}],
        selection: Map.put(state.selection, "effort_picker", 1)
    }

    assert {:ok, {:effort_move, 1}} = Keymap.resolve(Input.key(:down), state, %{})
    {state, []} = Reducer.update(state, {:effort_move, 1})
    {state, []} = Reducer.update(state, {:effort_move, 1})
    assert state.selection["effort_picker"] == 2
    assert {:ok, {:effort_pick, "high"}} = Keymap.resolve(Input.key(:enter), state, %{})
    {state, effects} = Reducer.update(state, {:effort_pick, "high"})
    assert [%{kind: {:dispatch, :send, "/effort high", :main, []}}] = requests(effects)
    assert state.layers == []
    assert text(state) == "half"
  end

  test "a level the daemon does not offer is never sent" do
    state = %{leveled() | layers: [{:effort_picker, :swarm}]}
    assert {_state, []} = Reducer.update(state, {:effort_pick, "medium"})
  end
end
