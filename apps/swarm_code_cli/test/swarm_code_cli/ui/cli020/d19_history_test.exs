defmodule SwarmCodeCLI.UI.Cli020.D19HistoryTest do
  @moduledoc "cli020 D19 (competitors-19): Ctrl-R history search and the draft stash."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.Cli020State

  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer}
  alias SwarmCodeCLI.UI.Reducer.HistorySearch

  defp ctrl_r, do: Input.text_fragment(:press, "r", [:control])

  defp layer(state, fields),
    do: %{
      state
      | layers: [{:history_search, Map.merge(%{query: "", rows: [], selected: 0}, fields)}]
    }

  test "Ctrl-R in the composer opens history; in the transcript it is still Switch run" do
    state = ready()
    assert {:ok, :history_search} = Keymap.resolve(ctrl_r(), state, %{})
    refute match?({:ok, :history_search}, Keymap.resolve(ctrl_r(), %{state | focus: "main"}, %{}))
  end

  test "typing edits the query and restarts the 150 ms debounce" do
    state = layer(ready(), %{})

    assert {:ok, {:history_query, {:append, "f"}}} =
             Keymap.resolve(Input.text_fragment(:press, "f", []), state, %{})

    {state, [{:start_timer, first, 150, {:timer_fired, first}}]} =
      Reducer.update(state, {:history_query, {:append, "f"}})

    {state, effects} = Reducer.update(state, {:history_query, {:append, "x"}})
    assert [{:cancel_timer, ^first}, {:start_timer, second, 150, _}] = effects
    assert [{:history_search, %{query: "fx"}}] = state.layers
    {state, _} = Reducer.update(state, {:history_query, :backspace})
    assert [{:history_search, %{query: "f"}}] = state.layers
    assert state.history_timer != second
  end

  test "only the newest request's answer is taken; Enter puts the prompt in the draft" do
    state = %{layer(ready() |> type("mine"), %{}) | history_request: "new"}
    rows = [%{"text" => "fix the tests"}, %{"text" => "add a flag"}]
    {stale, []} = HistorySearch.answer(state, %{request_id: "old"}, rows)
    assert [{:history_search, %{rows: []}}] = stale.layers
    {state, []} = HistorySearch.answer(state, %{request_id: "new"}, rows)
    assert [{:history_search, %{rows: [_, _]}}] = state.layers
    {state, []} = Reducer.update(state, {:history_move, 1})
    {state, _} = Reducer.update(state, {:history_pick})
    assert state.layers == []
    assert text(state) == "add a flag"
    {state, _} = Reducer.update(state, {:editor, key(state), :undo})
    assert text(state) == "mine"
  end

  test "stash puts the draft aside; restore swaps it back" do
    state = ready() |> type("work in progress")
    {state, _} = Reducer.update(state, {:stash_draft})
    assert text(state) == ""
    assert state.notice == {:command_feedback, "Draft stashed · Ctrl-P Restore stash"}
    state = type(state, "quick question")
    {state, _} = Reducer.update(state, {:restore_stash})
    assert text(state) == "work in progress"
    {state, _} = Reducer.update(state, {:restore_stash})
    assert text(state) == "quick question"
  end

  test "nothing to stash or restore says so" do
    {state, []} = Reducer.update(ready(), {:stash_draft})
    assert state.notice == {:command_feedback, "Nothing to stash."}
    {state, []} = Reducer.update(ready(), {:restore_stash})
    assert state.notice == {:command_feedback, "No stash to restore."}
  end
end
