defmodule SwarmCodeCLI.UI.Cli020.QaLayerFocusTest do
  @moduledoc """
  cli020 live QA: the layers lane D opens from the composer (the effort
  picker, the rewind list and its confirm, history search, the queue list)
  push no layer context, so closing one used to fall back to the transcript
  ("main", select mode): after `/effort` + Enter the next keys typed nothing.
  Closing them gives the focus back to where it was.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.Reducer

  defp leveled do
    state = ready()
    workspace = Map.put(state.read_model.snapshots.workspace, :effort_levels, ~w(low high))

    %{
      state
      | read_model: %{
          state.read_model
          | snapshots: Map.put(state.read_model.snapshots, :workspace, workspace)
        }
    }
  end

  test "the composer has the focus before any layer opens" do
    assert ready().focus == "composer"
  end

  test "picking an effort level leaves the focus in the composer" do
    {state, []} = Reducer.update(leveled(), {:slash_local, {:effort, :chat}})
    assert [{:effort_picker, :chat} | _] = state.layers
    {state, _effects} = Reducer.update(state, {:effort_pick, "high"})
    assert state.layers == []
    assert state.focus == "composer"
  end

  for layer <- [
        {:effort_picker, :chat},
        {:rewind, %{turns: [], selected: 0}},
        {:rewind_confirm, %{turn: 1, message_id: "m1", prompt: "p", files: 0}},
        {:history_search, %{query: "", rows: [], selected: 0}},
        {:queue_list}
      ] do
    test "Esc over #{inspect(elem(layer, 0))} gives the focus back to the composer" do
      state = %{leveled() | layers: [unquote(Macro.escape(layer))]}
      {state, _effects} = Reducer.update(state, :close_top_layer)
      assert state.layers == []
      assert state.focus == "composer"
    end
  end
end
