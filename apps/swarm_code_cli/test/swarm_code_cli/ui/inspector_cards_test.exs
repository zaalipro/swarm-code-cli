defmodule SwarmCodeCLI.UI.InspectorCardsTest do
  @moduledoc """
  Cell-level assertions for the docked inspector: the tab strip, the hive
  lanes, the changes ledger, the verdict card and the timeline, painted at
  170x34 (xl) and 150x30 (wide), in colour, monochrome and ASCII.
  """
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, Scene, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Projector.Inspector.Words

  # The fixture clock: the run started five minutes before it.
  @now 1_788_436_800_000
  @run "fixture-run"
  @warning {:rgb, 245, 180, 0}

  defp state(kind, cols, rows, opts \\ []) do
    size = %Size{columns: cols, rows: rows}
    caps = struct(Capabilities, Keyword.get(opts, :caps, []))
    state = Fixtures.representative(kind, size, caps)
    state = %{state | now: @now}

    case Keyword.get(opts, :tab) do
      nil -> state
      tab -> %{state | tabs: Map.put(state.tabs, :inspector, tab)}
    end
  end

  # Paints the state and returns the inspector's rows as text, the action
  # table, the plan and the region rect.
  defp painted(state, color_mode \\ :monochrome) do
    {scene, table} = Projector.project(state)
    assert Scene.validate(scene) == :ok

    assert {:ok, plan} =
             Paint.build(scene, %Options{
               color_mode: color_mode,
               ascii?: state.capabilities.ascii?
             })

    assert :ok = Plan.validate(plan)

    inspector = Enum.find(scene.regions, &(&1.role == :inspector))
    assert inspector, "no docked inspector at this size"

    rows =
      for y <- inspector.rect.y..(inspector.rect.y + inspector.rect.height - 1) do
        row_text(plan, y, inspector.rect)
      end

    {rows, table, plan, inspector.rect}
  end

  defp row_text(plan, y, rect) do
    for x <- rect.x..(rect.x + rect.width - 1), into: "" do
      case Plan.cell(plan, x, y) do
        {:glyph, glyph, _, _} -> glyph
        _ -> ""
      end
    end
    |> String.trim_trailing()
  end

  defp rows(kind, cols, rows, opts \\ []),
    do: kind |> state(cols, rows, opts) |> painted() |> elem(0)

  defp targets(table, target), do: for({id, ^target} <- table, do: id)

  # The foreground of the first cell of `text` on the row that contains it.
  defp foreground(plan, rect, rows, text) do
    y = Enum.find_index(rows, &String.contains?(&1, text))
    assert y, "no row contains #{inspect(text)}"
    x = rows |> Enum.at(y) |> String.split(text) |> hd() |> String.length()
    {:glyph, _, _, style} = Plan.cell(plan, rect.x + x, rect.y + y)
    elem(plan.palette, style).foreground
  end

  describe "tab strip" do
    test "the first row names the four tabs and each name is clickable" do
      {rows, table, _plan, _rect} = :swarm |> state(170, 34) |> painted()

      assert hd(rows) == "thread  agents  timeline  changes"

      for tab <- [:thread, :agents, :timeline, :changes] do
        assert length(targets(table, {:local, {:set_tab, tab}})) == 1
      end
    end
  end

  describe "hive lanes" do
    test "the thread tab of a swarm paints the HIVE header, the summary and one lane per agent" do
      rows = rows(:swarm, 170, 34)

      assert Enum.at(rows, 1) == "HIVE  Swarm · independent agent lanes"
      # Five agents, five minutes on the fixture clock, 22 850 tokens.
      assert Enum.at(rows, 2) == "5 agents · 05:00 · 22k tokens"

      # Every fixture agent may be stopped, so each lane packs `stop` on its
      # row; at the default 42-cell dock the tokens column yields to it.
      assert Enum.at(rows, 4) =~ ~r/^⬢ lead {6}planning {10}▬▬▭▭▭▭  stop$/
      assert Enum.at(rows, 5) =~ ~r/^⬢ scout-1 {3}grep "Repo\\." {5}▬▬▬▬▭▭  stop$/
      assert Enum.at(rows, 7) =~ ~r/^⬢ builder-4 edit lib\/swarm_…  ▬▬▭▭▭▭  stop$/
      assert Enum.at(rows, 8) =~ ~r/^⚖ judge {5}waiting for you {3}▭▭▭▭▭▭  stop$/

      assert "WAITING FOR YOU · 1" in rows
      assert "CHANGES · 3 files" in rows
    end

    test "every lane is one action that opens the run's agents, with its own stop beside it" do
      state = state(:swarm, 170, 34)
      {rows, table, _plan, _rect} = painted(state)

      lanes = targets(table, {:local, {:open_layer, {:run_inspector, @run, :agents}}})
      assert length(lanes) == 5

      for agent <- Map.values(state.read_model.agents) do
        stop = {:intent, {:stop_agent, @run, agent.id, agent.revision}}
        assert length(targets(table, stop)) == 1
      end

      assert Enum.count(rows, &String.starts_with?(&1, "⬢ ")) == 4
      assert Enum.count(rows, &String.starts_with?(&1, "⚖ ")) == 1
    end

    test "a waiting lane is painted in the warning colour with its step in plain words" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor])
      {rows, _table, plan, rect} = painted(state, :truecolor)

      assert foreground(plan, rect, rows, "waiting for you") == @warning
      assert foreground(plan, rect, rows, "⚖ judge") == @warning
      refute Enum.any?(rows, &String.contains?(&1, "NEEDS ANSWER"))
    end

    test "a failed lane carries its error in the error colour" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor])

      state =
        put_in(state.read_model.agents["agent-4"], %{
          state.read_model.agents["agent-4"]
          | state: :failed,
            error: "mix test exited with status 1"
        })

      {rows, _table, plan, rect} = painted(state, :truecolor)
      assert Enum.any?(rows, &(&1 =~ ~r/^⬢ builder-4 mix test exited…/))
      assert foreground(plan, rect, rows, "mix test exited") == {:rgb, 255, 77, 79}
    end

    test "lanes degrade to their ASCII twins" do
      rows = rows(:swarm, 170, 34, caps: [ascii?: true])

      assert Enum.at(rows, 4) =~ ~r/^o lead {6}planning {10}##----  stop$/
      assert Enum.at(rows, 8) =~ ~r/^j judge {5}waiting for you {3}------  stop$/
      refute Enum.any?(rows, &String.contains?(&1, "⬢"))
    end

    test "a run with no agents draws the assistant itself as one lane, and no zero" do
      rows = rows(:chat, 170, 34)

      assert Enum.at(rows, 1) == "HIVE  Streaming conversation"
      assert Enum.at(rows, 2) == "1 agent · 05:00 · 4.0k tokens"
      # The assistant cannot be stopped as an agent, so its tokens have the room.
      assert Enum.at(rows, 4) =~ ~r/^⬢ assistant writing +▬▬▬▭▭▭  4\.0k$/
      refute Enum.any?(rows, &String.contains?(&1, "Kind ·"))
      refute Enum.any?(rows, &String.contains?(&1, "WAITING FOR YOU"))
      refute Enum.any?(rows, &String.contains?(&1, "CHANGES"))
      refute Enum.any?(rows, &(&1 =~ ~r/· 0\b/))
    end

    test "a wider dock gives the tokens column back beside stop" do
      state = state(:swarm, 170, 34)
      state = %{state | preferences: %{state.preferences | inspector_width: 56}}
      {rows, _, _, rect} = painted(state)

      assert rect.width == 56
      assert Enum.at(rows, 4) =~ ~r/^⬢ lead {6}planning {18}▬▬▭▭▭▭  7\.6k  stop$/
      assert Enum.at(rows, 8) =~ ~r/^⚖ judge {5}waiting for you {11}▭▭▭▭▭▭  1\.2k  stop$/
    end

    test "a child of a superseded turn keeps the catalogue's exact words on the row beneath" do
      state = state(:swarm, 170, 34)
      state = put_in(state.read_model.agents["agent-3"].launched_by_superseded, true)
      {rows, _, _, _} = painted(state)

      lane = Enum.find_index(rows, &String.starts_with?(&1, "⬢ scout-2"))
      assert Enum.at(rows, lane + 1) == "LAUNCHED BY SUPERSEDED TURN"
    end

    test "the agents tab shows the hive alone, and the lanes stay one line each at wide" do
      rows = rows(:swarm, 150, 30, tab: :agents)

      assert Enum.at(rows, 1) =~ ~r/^HIVE  Swarm/
      assert Enum.count(rows, &(&1 =~ ~r/^[⬢⬡⚖] /u)) == 5
      refute Enum.any?(rows, &String.contains?(&1, "VERDICT"))
    end

    test "a stopped lane says so in words, never STOPPED alone" do
      state = state(:swarm, 170, 34)
      state = put_in(state.read_model.agents["agent-2"].state, :stopped)
      state = put_in(state.read_model.agents["agent-2"].step, "")
      {rows, _, _, _} = painted(state)

      assert Enum.any?(rows, &(&1 =~ ~r/^⬢ scout-1 {3}stopped by you/))
      refute Enum.any?(rows, &String.contains?(&1, "STOPPED"))
      assert Words.state(:stopped) == "stopped by you"
    end
  end

  describe "verdict card" do
    test "the thread tab of a consensus run shows the newest verdict above the hive" do
      rows = rows(:consensus, 170, 34)

      assert Enum.at(rows, 1) == "VERDICT · round 1 · done"
      assert Enum.at(rows, 2) =~ ~r/^✓ tests_pass {6}142 tests, 0 failures$/
      assert Enum.at(rows, 3) =~ ~r/^✓ no_regressions  auth paths unchanged$/
      # The panel is 42 cells wide, so the longest note is elided.
      assert Enum.at(rows, 4) =~ ~r/^✕ docs_updated {4}architecture.md still d…$/
      assert Enum.at(rows, 5) =~ ~r/^— style {11}not evaluated$/
      assert Enum.at(rows, 6) =~ ~r/^Two of three proposals meet the bar/
      assert Enum.find_index(rows, &String.starts_with?(&1, "HIVE  ")) > 6
    end

    test "the newest round wins" do
      state = state(:consensus, 170, 34)
      older = state.read_model.verdicts["judge-1"]

      newer = %{
        older
        | id: "judge-2",
          round: 2,
          summary: "All three proposals meet the bar.",
          checks: [%DTO.VerdictCheck{key: "docs_updated", ok: true, note: "docs landed"}]
      }

      state = put_in(state.read_model.verdicts, %{"judge-1" => older, "judge-2" => newer})
      {rows, _, _, _} = painted(state)

      assert Enum.at(rows, 1) == "VERDICT · round 2 · done"
      assert Enum.at(rows, 2) =~ ~r/^✓ docs_updated  docs landed$/
      refute Enum.any?(rows, &String.contains?(&1, "142 tests"))
    end

    test "with no verdict yet the card says so and what the judge is doing" do
      state = state(:consensus, 170, 34)

      judge = %DTO.AgentSummary{
        id: "judge-agent",
        run_id: @run,
        revision: 1,
        state: :running,
        name: "judge",
        role: :judge,
        step: "reading proposal B"
      }

      state = put_in(state.read_model.verdicts, %{})
      state = put_in(state.read_model.agents, %{"judge-agent" => judge})
      {rows, _, _, _} = painted(state)

      assert Enum.at(rows, 1) == "VERDICT"
      assert Enum.at(rows, 2) == "No verdict yet · judge running"
      assert Enum.any?(rows, &(&1 =~ ~r/^⚖ judge reading proposal B/))
    end

    test "the agents tab of a consensus run carries no verdict card" do
      rows = rows(:consensus, 170, 34, tab: :agents)
      refute Enum.any?(rows, &String.contains?(&1, "VERDICT"))
      assert Enum.at(rows, 1) =~ ~r/^HIVE  Consensus/
    end
  end

  describe "changes tab" do
    test "lists the run's files with the agent chip, the restorable mark and the time" do
      {rows, table, _plan, _rect} = :swarm |> state(170, 34, tab: :changes) |> painted()

      assert Enum.at(rows, 1) == "CHANGES · 3 files · 2 agents"
      assert Enum.at(rows, 2) == ""
      # Newest first; a change nobody can restore has a blank where the mark goes.
      assert Enum.at(rows, 3) =~ ~r/^docs\/architecture\.md +lead {8}\d\d:\d\d$/
      # A path longer than its column is elided in the middle, keeping the file name.
      assert Enum.at(rows, 4) =~ ~r/^test\/swarm_…epo_test\.exs builder-4 ✓ \d\d:\d\d$/
      assert Enum.at(rows, 5) =~ ~r/^lib\/swarm_code\/repo\.ex +builder-4 ✓ \d\d:\d\d$/

      assert length(targets(table, {:local, {:open_layer, {:library, :checkpoints}}})) == 3
    end

    test "a path two agents touched gets a blast-radius line in the warning colour" do
      state = state(:swarm, 170, 34, tab: :changes, caps: [color_mode: :truecolor])

      overlap = %DTO.Change{
        id: "change-4",
        run_id: @run,
        agent_id: "agent-2",
        path: "lib/swarm_code/repo.ex",
        restorable: true,
        at: @now - 100_000,
        revision: 1
      }

      state = put_in(state.read_model.changes["change-4"], overlap)
      {rows, _table, plan, rect} = painted(state, :truecolor)

      assert Enum.at(rows, 1) == "CHANGES · 3 files · 3 agents"
      # The full line — the path and both names — does not fit 42 cells, so the
      # counts stand in and the overlapping rows carry the warning colour.
      assert Enum.at(rows, 2) == "Blast radius · 1 file · 2 agents"
      assert foreground(plan, rect, rows, "Blast radius") == @warning
      assert Enum.at(rows, 4) =~ ~r/^lib\/swarm_code\/repo\.ex +scout-1 +✓ \d\d:\d\d$/
      assert Enum.at(rows, 7) =~ ~r/^lib\/swarm_code\/repo\.ex +builder-4 ✓ \d\d:\d\d$/
      assert foreground(plan, rect, rows, "lib/swarm_code/repo.ex") == @warning
      assert foreground(plan, rect, rows, "docs/architecture.md") == {:rgb, 243, 242, 240}
    end

    test "with nothing changed the tab says so" do
      state = state(:chat, 170, 34, tab: :changes)
      {rows, _, _, _} = painted(state)

      assert Enum.at(rows, 1) == "CHANGES"
      assert "No files changed yet" in rows
      refute Enum.any?(rows, &String.contains?(&1, "0 files"))
    end
  end

  describe "timeline tab" do
    test "lists the run's events oldest first with time, agent, kind and text" do
      rows = rows(:swarm, 170, 34, tab: :timeline)

      assert Enum.at(rows, 1) == "TIMELINE · 7 events"
      # 42 cells: the time, the widest name, the widest kind word, then the text.
      assert Enum.at(rows, 2) =~ ~r/^\d\d:\d\d you {7}text {4}Review this synth…$/
      assert Enum.at(rows, 3) =~ ~r/^\d\d:\d\d scout-1 {3}tool {4}grep "Repo\\."$/
      assert Enum.at(rows, 5) =~ ~r/^\d\d:\d\d lead {6}thought The refresh path/
      assert Enum.at(rows, 7) =~ ~r/^\d\d:\d\d builder-4 error {3}run_command faile…$/
      # The lead's streaming summary is the newest turn, so it is last.
      assert Enum.at(rows, 8) =~ ~r/^\d\d:\d\d lead {6}text {4}/
      assert Enum.at(rows, 9) == ""
    end

    test "only the newest events fit a short region, and the newest stays at the bottom" do
      state = state(:swarm, 150, 30, tab: :timeline)
      {rows, _, _, rect} = painted(state)

      last = rows |> Enum.reject(&(&1 == "")) |> List.last()
      assert last =~ ~r/^\d\d:\d\d lead {6}text/
      assert length(rows) == rect.height
    end
  end
end
