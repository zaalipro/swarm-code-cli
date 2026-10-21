defmodule SwarmCodeCLI.UI.R1019StashPastesTest do
  @moduledoc """
  C-BUG-13: a stash keeps a collapsed paste's payload. The payload lives in the
  draft, which a send clears, so the stash stores the expanded text.
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Drafts, Editor, Input, Reducer}
  alias SwarmCodeCLI.UI.Draft.Pastes

  @too_large {:command_feedback, "The draft is too large to stash (over 256 KiB)."}

  defp sixty, do: Enum.map_join(1..60, "\n", &"line #{&1}")
  defp bracketed(state, text), do: press(state, Input.paste(text)) |> elem(0)
  defp draft(state), do: Drafts.fetch(state.drafts, key())

  defp expanded(state) do
    draft = draft(state)
    {:ok, text} = Pastes.expand(Editor.text(draft.editor), draft.pastes)
    text
  end

  # What an accepted send does to the composer it came from.
  defp sent_and_cleared(state) do
    drafts =
      state.drafts
      |> Drafts.mark_submitted(key(), "request-1")
      |> Drafts.clear_origin(key(), "request-1")

    %{state | drafts: drafts}
  end

  defp replace_fixture(state, text) do
    draft = draft(state)
    {:ok, editor} = Editor.apply(draft.editor, :select_all)
    {:ok, editor} = Editor.apply(editor, {:paste, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  test "a stashed paste survives a send from the same composer" do
    state = ready() |> type("see ") |> bracketed(sixty())
    assert text(state) =~ "[Pasted text #1"

    {state, _} = Reducer.update(state, {:stash_draft})
    assert text(state) == ""
    assert state.stashes[key()] == "see " <> sixty()

    # Another, short prompt goes from the same composer and clears the draft
    # (and with it the paste table the old placeholder pointed into).
    state = state |> type("quick question") |> sent_and_cleared()
    assert draft(state).pastes == %{}

    {state, _} = Reducer.update(state, {:restore_stash})
    assert state.notice == {:command_feedback, "Stash restored"}
    assert expanded(state) == "see " <> sixty()
    refute expanded(state) =~ "[Pasted text"
  end

  test "restore keeps the pasted text of the draft it puts aside" do
    state = ready() |> type("first") |> then(&elem(Reducer.update(&1, {:stash_draft}), 0))
    state = state |> type("second ") |> bracketed(sixty())

    {state, _} = Reducer.update(state, {:restore_stash})
    assert expanded(state) == "first"
    assert state.stashes[key()] == "second " <> sixty()

    {state, _} = Reducer.update(state, {:restore_stash})
    assert expanded(state) == "second " <> sixty()
  end

  test "a draft over 256 KiB expanded is refused and nothing changes" do
    state = ready() |> bracketed(String.duplicate("x", 262_144))
    marker = text(state)
    state = replace_fixture(state, String.duplicate(marker, 8192))

    {next, effects} = Reducer.update(state, {:stash_draft})
    assert effects == []
    assert next.notice == @too_large
    assert next.stashes == state.stashes
    assert draft(next) == draft(state)
  end

  test "a restore that would stash a draft over 256 KiB is refused" do
    state = ready() |> type("small") |> then(&elem(Reducer.update(&1, {:stash_draft}), 0))
    state = state |> bracketed(String.duplicate("x", 262_144))
    marker = text(state)
    state = replace_fixture(state, String.duplicate(marker, 8192))

    {next, effects} = Reducer.update(state, {:restore_stash})
    assert effects == []
    assert next.notice == @too_large
    assert next.stashes == state.stashes
    assert next.stashes[key()] == "small"
    assert draft(next) == draft(state)
  end
end
