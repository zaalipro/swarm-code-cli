defmodule SwarmCodeCLI.UI.DraftPasteTest do
  @moduledoc """
  cli020 D8 (ux-live-16, decision 4e): a large paste collapses to one
  placeholder; send expands it; a deleted placeholder sends nothing.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Drafts, Input, Reducer}
  alias SwarmCodeCLI.UI.Draft.Pastes

  defp sixty, do: Enum.map_join(1..60, "\n", &"line #{&1}")
  defp pastes(state), do: Drafts.fetch(state.drafts, key()).pastes
  defp bracketed(state, text), do: press(state, Input.paste(text)) |> elem(0)

  test "a 60-line paste becomes one placeholder and keeps its text" do
    state = ready() |> type("see ") |> bracketed(sixty())
    assert text(state) == "see [Pasted text #1 · 60 lines]"
    assert pastes(state) == %{1 => sixty()}
  end

  test "send expands every placeholder still present" do
    state = ready() |> type("see ") |> bracketed(sixty()) |> type(" ok")
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == "see " <> sixty() <> " ok"
  end

  test "Backspace after the placeholder deletes all of it, and nothing is sent of it" do
    state = ready() |> type("a ") |> bracketed(sixty())
    {state, _} = press(state, Input.key(:backspace))
    assert text(state) == "a "
    assert pastes(state) == %{}
    state = type(state, "b")
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, "a b", :main, []}}] = requests(effects)
  end

  test "an edited placeholder is sent as typed" do
    state = ready() |> bracketed(sixty())
    {state, _} = press(state, Input.key(:left))
    {state, _} = press(state, Input.key(:backspace))
    {_state, effects} = send(state)

    assert [%{kind: {:dispatch, :send, "[Pasted text #1 · 60 line]", :main, []}}] =
             requests(effects)
  end

  test "small pastes stay inline; 0 lines never collapses; over 4 KiB always does" do
    assert text(ready() |> bracketed("one\ntwo")) == "one\ntwo"
    refute Pastes.collapse?(sixty(), 0)
    assert Pastes.collapse?(String.duplicate("x", 4_097), 8)
    state = %{ready() | paste_collapse_lines: 100} |> bracketed(sixty())
    assert text(state) == sixty()
  end

  test "Ctrl-Z after deleting the placeholder brings it back with its text" do
    state = ready() |> bracketed(sixty())
    {state, _} = Reducer.update(state, {:editor, key(), :select_all})
    {state, _} = Reducer.update(state, {:editor, key(), :delete_backward})
    {state, _} = Reducer.update(state, {:editor, key(), :undo})
    assert text(state) == "[Pasted text #1 · 60 lines]"
    {_state, effects} = send(state)
    assert [%{kind: {:dispatch, :send, sent, :main, []}}] = requests(effects)
    assert sent == sixty()
  end

  test "over 256 KiB after expansion is refused" do
    big = String.duplicate("x\n", 70_000)
    state = ready() |> bracketed(big) |> bracketed(big)
    {state, effects} = send(state)
    assert requests(effects) == []
    assert state.notice == {:command_feedback, "The message is over 256 KiB."}
  end
end
