defmodule SwarmCodeCLI.UI.Cli020.D10RewindTest do
  @moduledoc """
  cli020 D10 (competitors-8, decision 4h): /rewind, Esc Esc and /undo, the
  turn list, the confirm and the draft fill.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.Cli020State

  alias SwarmCodeCLI.Test.Cli020State
  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer}
  alias SwarmCodeCLI.UI.Reducer.Remote

  @c Cli020State.conversation()
  @t1 %{
    message_id: "3f0c1a2b-4d5e-4f60-8a71-b2c3d4e5f603",
    turn: 3,
    prompt: "third",
    at: nil,
    run_id: nil,
    files: 2
  }
  @t2 %{
    message_id: "3f0c1a2b-4d5e-4f60-8a71-b2c3d4e5f602",
    turn: 2,
    prompt: "second",
    at: nil,
    run_id: nil,
    files: 0
  }

  defp list(state), do: %{state | layers: [{:rewind, %{turns: [@t1, @t2], selected: 0}}]}

  test "bare /rewind and /undo are local; with an argument /rewind goes to the daemon" do
    assert Keymap.local_command("/rewind") == :rewind
    assert Keymap.local_command("/undo") == :undo
    assert Keymap.local_command("/rewind 3") == nil
  end

  test "/rewind asks for the turns" do
    {state, effects} = ready() |> type("/rewind") |> send_draft()

    assert commands(effects) == [{:rewind_turns, @c}]
    assert state.rewind == %{mode: :pick}
  end

  test "the turns' answer opens the list, or says there is nothing" do
    state = %{ready() | rewind: %{mode: :pick}}
    request = %{kind: {:rewind_turns, @c}, origin: {:conversation, :rewind}}

    rows = [
      %{
        "message_id" => "3f0c1a2b-4d5e-4f60-8a71-b2c3d4e5f603",
        "turn" => 3,
        "prompt" => "third",
        "files" => 2
      }
    ]

    {opened, []} = Remote.answer(state, request, {:ok, rows})

    assert [{:rewind, %{selected: 0, turns: [%{turn: 3}]}}] = opened.layers

    {empty, []} = Remote.answer(state, request, {:ok, []})
    assert empty.notice == {:command_feedback, "Nothing to rewind yet."}
  end

  test "↑/↓ move in the list and Enter opens the confirm for that turn" do
    state = list(ready())
    assert {:ok, {:rewind_move, 1}} = Keymap.resolve(Input.key(:down), state, %{})
    {state, []} = Reducer.update(state, {:rewind_move, 1})
    assert [{:rewind, %{selected: 1}}] = state.layers
    {state, []} = Reducer.update(state, {:rewind_move, 1})
    assert [{:rewind, %{selected: 1}}] = state.layers
    assert {:ok, {:rewind_open}} = Keymap.resolve(Input.key(:enter), state, %{})
    {opened, []} = Reducer.update(state, {:rewind_open})

    assert [{:rewind_confirm, @t2}, {:rewind, _}] = opened.layers
  end

  test "the confirm's keys choose the scope and send rewind.apply" do
    state = %{ready() | layers: [{:rewind_confirm, @t1}, {:rewind, %{turns: [@t1], selected: 0}}]}

    for {key, scope} <- [
          {Input.key(:enter), :both},
          {Input.text_fragment(:press, "b", []), :both},
          {Input.text_fragment(:press, "c", []), :conversation},
          {Input.text_fragment(:press, "f", []), :files}
        ] do
      assert {:ok, {:rewind_choose, ^scope}} = Keymap.resolve(key, state, %{})
    end

    {next, effects} = Reducer.update(state, {:rewind_choose, :conversation})
    assert next.layers == []

    assert commands(effects) == [
             {:rewind_apply, @c, "3f0c1a2b-4d5e-4f60-8a71-b2c3d4e5f603", :conversation}
           ]
  end

  test "the answer fills the draft as one undoable edit and says what came back" do
    state = ready() |> type("draft before")
    state = %{state | rewind: %{mode: :apply, turn: @t1, scope: :both}}

    request = %{
      kind: {:rewind_apply, @c, "3f0c1a2b-4d5e-4f60-8a71-b2c3d4e5f603", :both},
      origin: {:conversation, :rewind}
    }

    {state, _} =
      Remote.answer(state, request, {:ok, %{"text" => "third", "restored" => 2, "skipped" => 1}})

    assert text(state) == "third"

    assert state.notice ==
             {:command_feedback,
              "Rewound to turn 3 · 2 files restored · edit and press Enter to resend · 1 skipped (see the transcript)"}

    {state, _} = Reducer.update(state, {:editor, key(state), :undo})
    assert text(state) == "draft before"
  end

  test "files only leaves the draft and says the files came back" do
    state = ready() |> type("keep")
    state = %{state | rewind: %{mode: :apply, turn: @t1, scope: :files}}

    request = %{
      kind: {:rewind_apply, @c, "3f0c1a2b-4d5e-4f60-8a71-b2c3d4e5f603", :files},
      origin: {:conversation, :rewind}
    }

    {state, []} = Remote.answer(state, request, {:ok, %{restored: 1, skipped: 0}})
    assert text(state) == "keep"
    assert state.notice == {:command_feedback, "Files back to before turn 3 · 1 restored"}
  end

  test "Esc Esc within 600 ms on an empty draft asks for the turns; a slow one only arms" do
    state = %{ready() | now: 1_000}
    {state, []} = press(state, Input.key(:escape))
    assert state.last_escape_at == 1_000
    {slow, []} = press(%{state | now: 1_700}, Input.key(:escape))
    assert slow.last_escape_at == 1_700
    {quick, effects} = press(%{state | now: 1_400}, Input.key(:escape))
    assert quick.last_escape_at == nil

    assert commands(effects) == [{:rewind_turns, @c}]
  end

  test "Esc with a draft never opens the rewind" do
    state = %{ready() | now: 1_000} |> type("x")
    {state, _} = press(state, Input.key(:escape))
    {state, effects} = press(%{state | now: 1_100}, Input.key(:escape))
    assert commands(effects) == []
    assert state.last_escape_at == nil
  end
end
