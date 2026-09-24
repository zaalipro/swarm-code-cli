defmodule SwarmCodeCLI.UI.Projector.SwarmChromeTest do
  @moduledoc """
  pass70 D7 (ux M8, F14): below the width that docks the inspector a live
  swarm keeps its hive on the composer's edge; a finished run's tab stops
  counting; the dashboard counts a run that waits on you as live; select mode
  says so on the status row.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp scene(name, {columns, rows}) do
    size = %Size{columns: columns, rows: rows}
    Conversation.state(name, size, %Capabilities{size: size})
  end

  defp screen(state) do
    {scene, _table} = Projector.project(state)
    assert {:ok, plan} = Paint.build(scene, %Options{color_mode: state.capabilities.color_mode})
    assert :ok = Plan.validate(plan)

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

  defp quiet(state), do: put_in(state.read_model.interactions, %{})

  # pass72: under 120 columns the side panel's strip (R17) shows the swarm on
  # row 1, so the hive edge is drawn only with the panel hidden.
  defp hidden(state), do: Map.put(state, :panel_mode, :hidden)

  describe "the hive strip" do
    test "a live swarm with the panel hidden draws every agent on the composer's edge" do
      rows = scene(:swarm, {110, 34}) |> quiet() |> hidden() |> screen()
      strip = Enum.find(rows, &(&1 =~ ~r/^── hive /))
      assert strip, Enum.join(rows, "\n")

      assert strip =~ "lead"
      assert strip =~ "worker-a-accounts ✓"
      assert strip =~ "worker-b-live !"
      assert strip =~ "merge"
      assert strip =~ ~r/Ctrl-B pane$/
      assert String.length(strip) <= 110
    end

    test "names are shortened only when the row is full" do
      rows = scene(:swarm, {70, 30}) |> quiet() |> hidden() |> screen()
      strip = Enum.find(rows, &(&1 =~ ~r/^── hive /))
      assert strip
      assert String.length(strip) <= 70
      assert strip =~ "…" or strip =~ ~r/\+\d/
    end

    test "with the panel docked or stripped, an approval open, or the run finished there is no strip" do
      refute scene(:swarm, {160, 45}) |> quiet() |> screen() |> Enum.any?(&(&1 =~ "── hive"))
      refute scene(:swarm, {110, 34}) |> quiet() |> screen() |> Enum.any?(&(&1 =~ "── hive"))
      refute scene(:swarm, {110, 34}) |> screen() |> Enum.any?(&(&1 =~ "── hive"))
      refute scene(:first_reply, {110, 34}) |> screen() |> Enum.any?(&(&1 =~ "── hive"))
    end
  end

  describe "clocks and counts" do
    test "a failed run's tab does not keep counting, even with no finish stamp" do
      state = scene(:failed_workflow, {220, 40})
      state = put_in(state.read_model.runs["demo-run-10"].finished_at, nil)
      later = %{state | now: state.now + 3_600_000}
      assert hd(screen(state)) == hd(screen(later))
    end

    test "the dashboard counts a run that waits on you as live" do
      state = scene(:swarm, {160, 45})
      state = put_in(state.read_model.runs["demo-run-2"].state, :waiting_approval)
      state = %{state | layers: [{:runs_dashboard, "d1"}], focus: "dialog"}
      assert Enum.any?(screen(state), &(&1 =~ "2 runs · 1 live"))
    end
  end
end
