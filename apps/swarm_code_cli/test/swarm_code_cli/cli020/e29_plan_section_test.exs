defmodule SwarmCodeCLI.Cli020.E29PlanSectionTest do
  # cli020 E29 (competitors-14): the selected run's plan (C23
  # `RunSummary.plan`) is a `Plan 3/7` section above the agents in the panel,
  # `Plan 3/7` on the strip, and a reason for `:auto` to show the panel.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.Projector.Panel
  alias SwarmCodeCLI.UI.Projector.Panel.Model

  @plan [
    %{text: "Read the router", status: "done"},
    %{text: "List the gaps", status: "done"},
    %{text: "Write the tests", status: "done"},
    %{text: "Run mix test", status: "in_progress"},
    %{text: "Fix the failures", status: "pending"},
    %{text: "Update the docs", status: "pending"},
    %{text: "Report back", status: "pending"}
  ]

  defp with_plan(state, plan) do
    [run | _] = Model.runs(state)
    put_in(state.read_model.runs[run.id], Map.put(run, :plan, plan))
  end

  defp lines(state), do: screen(state)

  test "the panel draws Plan 3/7 with each step's mark, above the agents" do
    state = fixture(:swarm, {160, 40}) |> Map.put(:panel_mode, :full) |> with_plan(@plan)
    rows = lines(state)
    plan = Enum.find_index(rows, &(&1 =~ "Plan 3/7"))
    assert plan
    assert Enum.at(rows, plan + 1) =~ ~r/✓ Read the router/
    assert Enum.any?(rows, &(&1 =~ ~r/▸ Run mix test/))
    assert Enum.any?(rows, &(&1 =~ ~r/· Fix the failures/))
    agents = Enum.find_index(rows, &(&1 =~ ~r/ agents\s+\d+ live/))
    assert agents > plan
  end

  test "at most 7 step rows, then … N more" do
    long = for n <- 1..10, do: %{text: "Step #{n}", status: "pending"}
    rows = fixture(:swarm, {160, 44}) |> Map.put(:panel_mode, :full) |> with_plan(long) |> lines()
    assert Enum.any?(rows, &(&1 =~ "Plan 0/10"))
    assert Enum.any?(rows, &(&1 =~ "Step 7"))
    refute Enum.any?(rows, &(&1 =~ "Step 8"))
    assert Enum.any?(rows, &(&1 =~ "… 3 more"))
  end

  test "ASCII marks" do
    rows =
      fixture(:swarm, {160, 40}, ascii?: true, glyph_tier: :ascii)
      |> Map.put(:panel_mode, :full)
      |> with_plan(@plan)
      |> lines()

    assert Enum.any?(rows, &(&1 =~ ~r/\+ Read the router/))
    assert Enum.any?(rows, &(&1 =~ ~r/> Run mix test/))
    assert Enum.any?(rows, &(&1 =~ ~r/\. Fix the failures/))
  end

  test "the strip shows Plan 3/7" do
    rows =
      fixture(:swarm, {100, 30}) |> Map.put(:panel_mode, :full) |> with_plan(@plan) |> lines()

    assert Enum.any?(Enum.take(rows, 3), &(&1 =~ "Plan 3/7"))
  end

  test "no plan, no section" do
    rows = fixture(:swarm, {160, 40}) |> Map.put(:panel_mode, :full) |> lines()
    refute Enum.any?(rows, &(&1 =~ ~r/Plan \d+\/\d+/))
  end

  test "under :auto a plan shows the panel" do
    state = fixture(:chat, {120, 30}) |> Map.put(:panel_mode, :auto)
    refute Panel.auto_shown?(state)

    if Model.runs(state) != [] do
      assert state |> with_plan(@plan) |> Panel.auto_shown?()
    end
  end
end
