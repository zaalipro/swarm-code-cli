defmodule SwarmCodeCLI.Cli020.E4EffortTest do
  # cli020 E4 (ux-live-14, decision 4f): the effort is visible on the status
  # chip, and D18's `{:effort_picker, scope}` layer is a picker with the
  # current level ticked. The rows are the daemon's levels for the model
  # (C17's `effort_levels`), else the five classic ones.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  defp base do
    fixture(:chat, {120, 30})
    |> put_workspace(chat_model: "claude-sonnet-5", effort: "medium", swarm_effort: "high")
  end

  test "the status chip appends the effort to the model" do
    assert List.last(screen(base())) =~ "claude-sonnet-5 · medium"
  end

  test "without an effort the chip is the model alone" do
    row = base() |> put_workspace(effort: nil) |> screen() |> List.last()
    assert row =~ "claude-sonnet-5"
    refute row =~ "claude-sonnet-5 · medium"
  end

  defp picker(state, scope), do: %{state | layers: [{:effort_picker, scope}], focus: "dialog"}

  test "the chat picker lists five levels with the current one ticked" do
    text = base() |> picker(:chat) |> screen_text()
    assert text =~ "Effort · chat"

    for level <- ~w(low medium high xhigh max), do: assert(text =~ level)
    assert text =~ ~r/✓ medium/
    refute text =~ ~r/✓ high/
  end

  test "the worker picker ticks the worker effort and uses the daemon's levels" do
    state =
      base() |> put_workspace(swarm_effort_levels: ["low", "high", "max"]) |> picker(:swarm)

    text = screen_text(state)
    assert text =~ "Effort · workers"
    assert text =~ ~r/✓ high/
    refute text =~ "xhigh"
  end

  test "each row picks its level" do
    state = base() |> picker(:chat)
    dialog = SwarmCodeCLI.UI.Projector.Dialog.project(state, :wide)

    targets =
      for block <- dialog.blocks, target = Map.get(block, :target), target != nil, do: target

    # STUB until D18 adds `{:effort_pick, level}` to `Action`: no target.
    if match?({:ok, _}, SwarmCodeCLI.UI.Action.validate({:effort_pick, "low"})) do
      assert {:local, {:effort_pick, "low"}} in targets
      assert {:local, {:effort_pick, "max"}} in targets
    else
      assert targets |> Enum.filter(&match?({:local, {:effort_pick, _}}, &1)) == []
    end
  end
end
