defmodule SwarmCodeCLI.Cli020.E20ResumeRowsTest do
  # cli020 E20 (ux-live-24): a resume row says when the conversation last
  # moved, right-aligned (`2 h ago`), and its last prompt on a dim second
  # line (C19's `last_prompt`).
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Switcher, Theme}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @now 1_789_000_000_000

  defp resume do
    state = fixture(:chat, {120, 30}, color_mode: :truecolor)
    layer = {:switcher, "resume"}
    {:ok, query} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, "#"})

    items = [
      %DTO.ConversationSummary{
        id: "c1",
        title: "Fix the router",
        updated_at: @now - 2 * 3_600_000,
        run_count: 3
      }
      |> Map.put(:last_prompt, "Now add the retry test"),
      %DTO.ConversationSummary{
        id: "c2",
        title: "Read the docs",
        updated_at: @now - 3 * 86_400_000,
        run_count: 1
      }
    ]

    %{
      state
      | layers: [layer],
        focus: "query",
        now: @now,
        conversations: %{items: items},
        field_editors: FieldEditors.put(state.field_editors, Switcher.field_key(layer), query)
    }
  end

  defp row(text, needle), do: text |> String.split("\n") |> Enum.find(&(&1 =~ needle))

  test "the time sits at the right edge, not in the detail" do
    text = screen_text(resume())
    row = row(text, "Fix the router")
    assert row =~ ~r/Fix the router\s+3 runs\s{2,}2 h ago\s*│/
    refute row =~ "3 runs · 2 h ago"
  end

  test "the last prompt is a dim second line" do
    state = resume()
    rows = state |> screen_text() |> String.split("\n")
    at = Enum.find_index(rows, &(&1 =~ "Fix the router"))
    assert Enum.at(rows, at + 1) =~ "Now add the retry test"
    {x, y} = locate(state, "Now add the retry test")

    assert cell_style(plan(state), x, y).foreground ==
             Theme.style(:text_faint, state.capabilities).foreground.value

    # A conversation without one has no second line.
    at2 = Enum.find_index(rows, &(&1 =~ "Read the docs"))
    refute Enum.at(rows, at2 + 1) =~ "Now add"
  end

  test "the count line still counts conversations, not the prompt lines" do
    assert screen_text(resume()) =~ ~r/of 3 · Enter chooses/
  end
end
