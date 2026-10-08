defmodule SwarmCodeCLI.Cli020.E9PaletteRowsTest do
  # cli020 E9 (ux-live-4, tui-code-11, competitors-19): the palette shows
  # "Retry failed run" first when the newest run failed or stopped, lists the
  # stash rows (D19), shows `/search` hits (C8) as rows that open their
  # conversation, and the failure hint names the real keys.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Switcher}

  defp palette(state, query) do
    layer = {:switcher, "palette"}
    {:ok, editor} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, query})

    %{
      state
      | layers: [layer],
        focus: "dialog",
        field_editors: FieldEditors.put(state.field_editors, Switcher.field_key(layer), editor)
    }
  end

  alias SwarmCodeCLI.UI.Pass73Helpers, as: H

  defp with_runs(states) do
    runs =
      states
      |> Enum.with_index(1)
      |> Enum.map(fn {run_state, n} ->
        # A run carries :retry only while failed (DTO schema invariant).
        actions = if run_state == :failed, do: [:retry, :stop], else: [:stop]
        %{H.run("r#{n}", run_state, actions: actions) | created_sequence: n}
      end)

    H.ready(runs)
  end

  test "a failed newest run puts Retry failed run first" do
    state = with_runs([:done, :failed]) |> palette("")
    [first | _] = Switcher.visible(state)
    assert first.label == "Retry failed run"
    assert first.target == {:intent, {:retry_run, "r2", 3}}
  end

  # C's resolver offers a retry only for a failed run today
  # (`request_resolver.ex` `retry_not_failed?/2`); a stopped newest run's row
  # is pinned too once C6 lets it through.
  test "a running newest run keeps the usual order" do
    state = with_runs([:failed, :running]) |> palette("")
    [first | _] = Switcher.visible(state)
    refute first.label == "Retry failed run"
  end

  test "the stash rows are listed once D19's actions exist" do
    state = fixture(:chat, {120, 30}) |> palette("stash")
    labels = state |> Switcher.visible() |> Enum.map(& &1.label)

    assert "Stash draft" in labels
    assert "Restore stash" in labels
  end

  test "search hits are rows under ? whose Enter opens the hit's conversation" do
    hits = %{
      query: "router",
      options: [
        %{conversation_id: "c-1", title: "Fix the router", snippet: "the router drops…", at: nil},
        %{conversation_id: "c-2", title: "Docs", snippet: "router table", at: nil}
      ]
    }

    state = fixture(:chat, {120, 30}) |> Map.put(:search_results, hits) |> palette("?")
    entries = Switcher.visible(state)

    assert Enum.map(entries, & &1.target) == [
             {:local, {:open_conversation, "c-1"}},
             {:local, {:open_conversation, "c-2"}}
           ]

    assert hd(entries).title == "Fix the router"
    assert screen_text(state) =~ "Search results: router"
  end

  test "the failure hint names the key that works where the focus is (fix round U2)" do
    turns = SwarmCodeCLI.UI.Projector.Workspace.Turns

    # In the composer `r` types an `r`: only the palette row is named.
    assert turns.next_step_text(%{error_kind: "network"}, %{focus: "composer"}) ==
             "connection dropped · Ctrl-P → Retry failed run"

    assert turns.next_step_text(%{error_kind: "network"}, %{}) ==
             "connection dropped · Ctrl-P → Retry failed run"

    # ASCII terminals get an ASCII arrow.
    assert turns.next_step_text(%{error_kind: "network"}, %{capabilities: %{ascii?: true}}) ==
             "connection dropped · Ctrl-P -> Retry failed run"

    # In select mode (focus "main") `r` retries the selected run.
    assert turns.next_step_text(%{error_kind: "network"}, %{focus: "main"}) ==
             "connection dropped · r retries · Ctrl-P Retry failed run"

    refute SwarmCodeCLI.UI.Projector.Workspace.Turns.next_step_text(%{}, %{}) =~
             "from the palette"
  end
end
