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
    assert Keymap.local_command("/worker_effort") == {:effort, :swarm}
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

  describe "fix round U4: a default row while no effort is set" do
    test "the swarm picker with no effort starts on a default row and offers the levels after it" do
      state = leveled()
      assert EffortPicker.current(state, :swarm) == nil
      assert EffortPicker.rows(state, :swarm) == ~w(default low high)
      {opened, []} = Reducer.update(state, {:slash_local, {:effort, :swarm}})
      assert [{:effort_picker, :swarm} | _] = opened.layers
      assert opened.selection["effort_picker"] == 0
      assert EffortPicker.selected(opened, :swarm) == "default"
    end

    test "with an effort set there is no default row" do
      assert EffortPicker.rows(leveled(), :chat) == ~w(low medium high)
    end

    test "Enter on the default row sends nothing and closes the picker" do
      {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :swarm}})
      assert {:ok, {:effort_pick, "default"}} = Keymap.resolve(Input.key(:enter), state, %{})
      {state, effects} = Reducer.update(state, {:effort_pick, "default"})
      assert requests(effects) == []
      assert state.layers == []
    end

    test "the picker draws the default row ticked and the levels under it" do
      state = %{leveled() | layers: [{:effort_picker, :swarm}], focus: "dialog"}
      dialog = SwarmCodeCLI.UI.Projector.Dialog.project(state, :wide)
      text = inspect(dialog.blocks, limit: :infinity)
      assert text =~ ~s({:effort_pick, "default"})
      assert text =~ ~s({:effort_pick, "low"})

      screen = SwarmCodeCLI.Cli020EHelpers.screen_text(state)
      assert screen =~ ~r/✓ default/
      refute screen =~ ~r/✓ low/
    end
  end
end
