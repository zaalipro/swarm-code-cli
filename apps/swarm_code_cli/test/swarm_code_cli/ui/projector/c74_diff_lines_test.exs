defmodule SwarmCodeCLI.UI.Projector.C74DiffLinesTest do
  @moduledoc """
  pass74 U3-10 (§2.15 `terminal.diff_lines`): the transcript's diff preview
  draws as many hunk lines as cli.json says (`state.prefs["diff_lines"]`),
  then how many more; without the preference it stays twelve.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp state_with_long_diff(prefs) do
    size = %Size{columns: 120, rows: 60}
    caps = %Capabilities{size: size, color_mode: :truecolor}
    state = Conversation.state(:trouble, size, caps)
    id = "demo-run-2-item-004"
    item = state.read_model.transcript[id]
    body = Enum.map_join(1..30, "\n", &"+line #{&1}")

    long =
      "--- a/lib/tickets/guard.ex\n+++ b/lib/tickets/guard.ex\n@@ -1,0 +1,30 @@\n" <>
        body <> "\n@@ -80,2 +94,3 @@\n context\n+more\n context"

    state = put_in(state.read_model.transcript[id], %{item | text: long})
    if prefs, do: Map.put(state, :prefs, prefs), else: state
  end

  defp rows(state) do
    {scene, _table} = Projector.project(state)
    options = %Options{color_mode: :truecolor, ascii?: false}
    assert {:ok, plan} = Paint.build(scene, options)

    for y <- 0..(state.size.rows - 1) do
      for x <- 0..(state.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
      |> String.trim_trailing()
    end
  end

  defp edit_row(rows), do: Enum.find_index(rows, &(&1 =~ ~r/edit +lib\/tickets\/guard\.ex/))

  test "diff_lines 4 shows four lines, then how many more" do
    rows = state_with_long_diff(%{"diff_lines" => 4}) |> rows()
    edit = edit_row(rows)
    assert Enum.at(rows, edit + 1) =~ ~r/^ +@@ -1,0 \+1,30 @@/
    assert Enum.at(rows, edit + 4) =~ ~r/^ +\+line 3$/
    assert Enum.at(rows, edit + 5) =~ ~r/^ +… 31 more lines · Enter opens$/
    refute Enum.any?(rows, &(&1 =~ ~r/\+line 4$/))
  end

  test "diff_lines 20 shows twenty" do
    rows = state_with_long_diff(%{"diff_lines" => 20}) |> rows()
    edit = edit_row(rows)
    assert Enum.at(rows, edit + 20) =~ ~r/^ +\+line 19$/
    assert Enum.at(rows, edit + 21) =~ ~r/^ +… 15 more lines · Enter opens$/
  end

  test "no preference, or one out of range, keeps twelve" do
    for prefs <- [nil, %{}, %{"diff_lines" => 2}, %{"diff_lines" => "40"}] do
      rows = state_with_long_diff(prefs) |> rows()
      edit = edit_row(rows)
      assert Enum.at(rows, edit + 13) =~ ~r/^ +… 23 more lines · Enter opens$/, inspect(prefs)
    end
  end
end
