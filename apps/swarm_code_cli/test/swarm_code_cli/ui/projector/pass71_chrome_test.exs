defmodule SwarmCodeCLI.UI.Projector.Pass71ChromeTest do
  @moduledoc """
  pass71 V5: the queue count on the composer rule, the changes as a dialog
  below the docking width, and sentence case where chrome still shouted.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, SafeText, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp state(scene, {columns, rows}) do
    size = %Size{columns: columns, rows: rows}
    Conversation.state(scene, size, %Capabilities{size: size, color_mode: :truecolor})
  end

  defp screen(state) do
    {scene, table} = Projector.project(state)
    assert {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})

    rows =
      for y <- 0..(state.size.rows - 1) do
        for x <- 0..(state.size.columns - 1), into: "" do
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> glyph
            _ -> ""
          end
        end
      end

    {rows, table}
  end

  defp queued(state, n),
    do: update_in(state.read_model.snapshots.workspace, &Map.put(&1, :queued, n))

  test "prompts waiting behind the live turn are counted on the composer rule" do
    state = state(:first_reply, {120, 36})
    {rows, _} = screen(queued(state, 2))
    rule = Enum.find(rows, &(&1 =~ "queued"))
    assert rule =~ ~r/─+ 2 queued ──$/

    {rows, _} = screen(queued(state, 0))
    refute Enum.any?(rows, &(&1 =~ "queued"))

    # An older daemon without the field shows nothing.
    {rows, _} = screen(state)
    refute Enum.any?(rows, &(&1 =~ "queued"))
  end

  test "the inspector opened as a dialog on its changes tab lists the files and opens their diffs" do
    state = state(:trouble, {90, 30})
    state = %{state | layers: [{:run_inspector, "demo-run-2", :changes}]}
    {rows, table} = screen(state)
    screen = Enum.join(rows, "\n")

    assert screen =~ "Changes · 2 files"
    assert screen =~ ~r/M lib\/tickets\/guard\.ex  \+5 −1/
    assert {:local, {:open_detail, "demo-run-2", "demo-checkpoint-1:diff"}} in Map.values(table)
  end

  test "a turn that changed nothing shows the conversation's changes" do
    state = state(:trouble, {90, 30})
    state = %{state | layers: [{:run_inspector, "demo-run-3", :changes}]}
    {rows, _table} = screen(state)
    assert Enum.join(rows, "\n") =~ "lib/tickets/guard.ex"
  end

  test "request outcomes read in sentence case" do
    for {token, words} <- [
          rejected: "Rejected",
          needs_input: "Needs input",
          deadline_exceeded: "Deadline exceeded",
          outcome_unknown: "Outcome unknown",
          revision_conflict: "Revision conflict"
        ],
        do: assert(SafeText.value(SafeText.chrome(token)) == words)
  end
end
