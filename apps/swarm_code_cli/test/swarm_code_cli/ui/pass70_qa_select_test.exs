defmodule SwarmCodeCLI.UI.Pass70QaSelectTest do
  @moduledoc """
  pass70 Q9, found driving the release: select mode says "Enter open", but
  Enter on an edit row only folded it open onto the tool's own words
  ("edited notes/x.md: 1 replacement(s)"); the diff was reachable only from
  the palette. Enter on an edit now opens its diff.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Keymap, ReadModel, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp state(tool) do
    item = %DTO.TranscriptItem{
      id: "e1",
      run_id: "r",
      conversation_id: "c",
      node_id: "e1",
      role: :tool,
      kind: :tool,
      text: "edited notes/x.md: 1 replacement(s)",
      tool: tool
    }

    %{
      State.__struct__()
      | focus: "main",
        selection: %{"main" => "e1"},
        read_model: %{%ReadModel{} | transcript: %{"e1" => item}}
    }
  end

  @edit %DTO.ToolCall{
    name: "edit_file",
    title: "edit notes/x.md",
    added: 1,
    removed: 1,
    diff_ref: %DTO.DetailRef{id: "e1:diff", total_bytes: 120}
  }

  @table %{
    "a1" => {:local, {:expand, "e1", true}},
    "a2" => {:local, {:open_detail, "r", "e1:diff"}}
  }

  test "Enter on an edit opens its diff" do
    assert {:ok, {:open_detail, "r", "e1:diff"}} = Keymap.content_activate(state(@edit), @table)
  end

  test "a tool without a diff still folds open" do
    read = %DTO.ToolCall{name: "read_file", title: "read mix.exs"}
    assert {:ok, {:expand, "e1", true}} = Keymap.content_activate(state(read), @table)
  end

  test "an edit whose diff is not on offer folds open instead of doing nothing" do
    table = Map.delete(@table, "a2")
    assert {:ok, {:expand, "e1", true}} = Keymap.content_activate(state(@edit), table)
  end
end
