defmodule SwarmCodeCLI.UI.InspectorCardsTest do
  @moduledoc """
  Cell-level assertions for the docked inspector: the tab strip, the hive
  lanes, the changes ledger, the verdict card and the timeline, painted at
  170x34 (xl) and 150x30 (wide), in colour, monochrome and ASCII.
  """
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, Reducer, Scene, Size}
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

  defp dock?(state) do
    {scene, _table} = Projector.project(state)
    Enum.any?(scene.regions, &(&1.role == :inspector))
  end

  # The background of the first cell of `text` on the row that contains it.
  defp background(plan, rect, rows, text) do
    y = Enum.find_index(rows, &String.contains?(&1, text))
    assert y, "no row contains #{inspect(text)}"
    x = rows |> Enum.at(y) |> String.split(text) |> hd() |> String.length()
    {:glyph, _, _, style} = Plan.cell(plan, rect.x + x, rect.y + y)
    elem(plan.palette, style).background
  end

  # The foreground of the first cell of `text` on the row that contains it.
  defp foreground(plan, rect, rows, text) do
    y = Enum.find_index(rows, &String.contains?(&1, text))
    assert y, "no row contains #{inspect(text)}"
    x = rows |> Enum.at(y) |> String.split(text) |> hd() |> String.length()
    {:glyph, _, _, style} = Plan.cell(plan, rect.x + x, rect.y + y)
    elem(plan.palette, style).foreground
  end

  describe "tab strip" do
    test "timeline and changes carry the strip: three clickable names and the waiting count" do
      {rows, table, _plan, _rect} = :swarm |> state(170, 34, tab: :timeline) |> painted()

      # The swarm fixture has one agent waiting on you.
      assert hd(rows) == "agents   1   timeline  changes"
      assert length(targets(table, {:local, {:set_tab, :agents}})) == 1
      assert length(targets(table, {:local, {:set_tab, :timeline}})) == 1
      assert length(targets(table, {:local, {:set_tab, :changes}})) == 1
    end

    test "the current tab is lit on the hover surface and the count is amber" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor], tab: :timeline)
      {rows, _table, plan, rect} = painted(state, :truecolor)

      assert foreground(plan, rect, rows, "timeline") == {:rgb, 255, 106, 26}
      assert background(plan, rect, rows, "timeline") == {:rgb, 38, 38, 38}
      assert background(plan, rect, rows, " 1 ") == @warning
    end

    test "pass72: the agents tab is the side panel, with no strip; older spellings land on it" do
      for tab <- [nil, :agents, :thread, :overview, :nonsense] do
        rows = rows(:swarm, 170, 34, tab: tab)
        assert hd(rows) =~ ~r/^ .⋔ Swarm · independent agen… · in chat 05:00$/u
        refute Enum.any?(rows, &(&1 =~ "timeline  changes"))
      end
    end
  end

  # pass72: the agents tab is the D side panel (`Projector.Panel`; its frames
  # are pinned in `projector/panel_test.exs`). These keep the pass-70 card
  # behaviours that still apply, on the representative fixtures.
  describe "the side panel on the representative fixtures" do
    test "the lead first, then its agents as a two-level tree, and no operations" do
      rows = rows(:swarm, 170, 34)

      assert Enum.any?(rows, &(&1 =~ ~r/^ ⦁ Lead +working +4:45 · 8k$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^ ⊢ ⦁ scout-1 +working +4:40 · 4k$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^ ⎣ ! judge +needs you +4:25 · 1k$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^ reported  ▱▱▱▱  0 of 4 +1 needs you$/))
      refute Enum.any?(rows, &(&1 =~ ~r/Operations|Current task|active/))
    end

    test "a waiting agent is painted in the warning colour" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor])
      {rows, _table, plan, rect} = painted(state, :truecolor)

      assert foreground(plan, rect, rows, "needs you") == @warning
      assert foreground(plan, rect, rows, "waiting for your answer") == @warning
      refute Enum.any?(rows, &String.contains?(&1, "NEEDS ANSWER"))
    end

    test "a failed agent carries its error in the error colour and a cross" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor])

      state =
        put_in(state.read_model.agents["agent-4"], %{
          state.read_model.agents["agent-4"]
          | state: :failed,
            error: "mix test exited with status 1"
        })

      {rows, _table, plan, rect} = painted(state, :truecolor)
      assert Enum.any?(rows, &(&1 =~ ~r/^ ⊢ ✗ builder-4 +failed/))
      assert foreground(plan, rect, rows, "mix test exited") == {:rgb, 255, 77, 79}
    end

    test "a child of a superseded turn keeps the catalogue's exact words" do
      state = state(:swarm, 170, 34)
      state = put_in(state.read_model.agents["agent-3"].launched_by_superseded, true)
      rows = painted(state) |> elem(0)

      lane = Enum.find_index(rows, &(&1 =~ "scout-2"))
      assert Enum.at(rows, lane + 1) =~ "Launched by a superseded turn"
    end

    test "a stopped agent says so in words, never STOPPED alone" do
      state = state(:swarm, 170, 34)
      state = put_in(state.read_model.agents["agent-2"].state, :stopped)
      state = put_in(state.read_model.agents["agent-2"].step, "")
      rows = painted(state) |> elem(0)

      assert Enum.any?(rows, &(&1 =~ ~r/^ ⊢ ✗ scout-1 +stopped/))
      refute Enum.any?(rows, &String.contains?(&1, "STOPPED"))
      assert Words.state(:stopped) == "stopped by you"
    end

    test "the cards degrade to their ASCII twins" do
      rows = rows(:swarm, 170, 34, caps: [ascii?: true])

      assert Enum.any?(rows, &(&1 =~ ~r/^ \* Lead +working/))
      assert Enum.any?(rows, &(&1 =~ ~r/^ \| \* scout-1 +working/))
      assert Enum.any?(rows, &(&1 =~ ~r/^ ` ! judge +needs you/))

      for row <- rows do
        assert String.replace(row, ["·", "…"], "") =~ ~r/^[\x20-\x7e]*$/, inspect(row)
      end
    end

    test "a short region cuts whole rows and says how many agents are left out" do
      for {cols, lines} <- [{150, 16}, {170, 14}] do
        rows = rows(:swarm, cols, lines)
        assert length(rows) == lines - 2

        assert Enum.any?(rows, &(&1 =~ ~r/more · Ctrl-G all runs/)) or
                 Enum.any?(rows, &(&1 =~ "judge"))
      end
    end
  end

  describe "the verdict of a judged run" do
    test "a consensus run shows the newest verdict's checks as criteria and the judge's words" do
      rows = rows(:consensus, 170, 34)

      v = Enum.find_index(rows, &(&1 =~ ~r/^ criteria +2 of 4 met$/))
      assert v, "no criteria row"
      assert Enum.at(rows, v + 2) =~ ~r/^   ✓ tests_pass +142 tests, 0 failures$/
      assert Enum.at(rows, v + 3) =~ ~r/^   ✓ no_regressions +auth paths unchanged$/
      assert Enum.at(rows, v + 4) =~ ~r/^   ✗ docs_updated +architecture.md still draft$/
      assert Enum.at(rows, v + 5) =~ ~r/^   ⚬ style +not evaluated$/
      assert Enum.any?(rows, &(&1 =~ "Two of three proposals meet the bar"))
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

      assert Enum.any?(rows, &(&1 =~ ~r/^   ✓ docs_updated +docs landed$/))
      assert Enum.any?(rows, &(&1 =~ "All three proposals meet the bar."))
      refute Enum.any?(rows, &String.contains?(&1, "142 tests"))
    end

    test "only the agents tab carries it" do
      for tab <- [:timeline, :changes] do
        refute Enum.any?(rows(:consensus, 170, 34, tab: tab), &String.contains?(&1, "criteria"))
      end
    end
  end

  describe "changes tab" do
    test "lists the run's files with the agent chip, the restorable mark and the time" do
      {rows, table, _plan, _rect} = :swarm |> state(170, 34, tab: :changes) |> painted()

      assert Enum.at(rows, 1) == "Changes · 3 files · 2 agents"
      assert Enum.at(rows, 2) == ""
      # Newest first; a change nobody can restore has a blank where the mark goes.
      assert Enum.at(rows, 3) =~ ~r/^docs\/architecture\.md +lead {8}\d\d:\d\d$/
      # A path longer than its column loses whole directories, keeping the file name.
      assert Enum.at(rows, 4) =~ ~r/^test\/…\/repo_test\.exs +builder-4 ✓ \d\d:\d\d$/
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

      assert Enum.at(rows, 1) == "Changes · 3 files · 3 agents"
      # The full line — the path and both names — does not fit 42 cells, so the
      # counts stand in and the overlapping rows carry the warning colour.
      assert Enum.at(rows, 2) == "Blast radius · 1 file · 2 agents"
      assert foreground(plan, rect, rows, "Blast radius") == @warning
      assert Enum.at(rows, 4) =~ ~r/^lib\/swarm_code\/repo\.ex +scout-1 +✓ \d\d:\d\d$/
      assert Enum.at(rows, 7) =~ ~r/^lib\/swarm_code\/repo\.ex +builder-4 ✓ \d\d:\d\d$/
      assert foreground(plan, rect, rows, "lib/swarm_code/repo.ex") == @warning
      assert foreground(plan, rect, rows, "docs/architecture.md") == {:rgb, 243, 242, 240}
    end

    test "file states and line counts: a letter, +N −M, and the row opens the diff" do
      state = state(:swarm, 170, 34, tab: :changes)

      state =
        state
        |> update_in([Access.key!(:read_model), Access.key!(:changes), "change-1"], fn change ->
          %{
            change
            | file_state: :modified,
              added: 12,
              removed: 3,
              diff_ref: %DTO.DetailRef{id: "cp-1:diff", total_bytes: 900}
          }
        end)
        |> update_in([Access.key!(:read_model), Access.key!(:changes), "change-2"], fn change ->
          %{change | file_state: :created, added: 40, removed: 0}
        end)

      {rows, table, _plan, _rect} = painted(state)

      assert Enum.at(rows, 1) == "Changes · 3 files · +52 −3 · 2 agents"

      assert Enum.at(rows, 4) =~
               ~r/^A …\/repo_test\.exs +\+40 −0 builder-4 ✓ \d\d:\d\d$/

      assert Enum.at(rows, 5) =~ ~r/^M lib\/…\/repo\.ex +\+12 −3 builder-4 ✓ \d\d:\d\d$/
      assert length(targets(table, {:local, {:open_detail, @run, "cp-1:diff"}})) == 1
      assert length(targets(table, {:local, {:open_layer, {:library, :checkpoints}}})) == 2
    end

    test "with nothing changed the tab says so" do
      state = state(:chat, 170, 34, tab: :changes)
      {rows, _, _, _} = painted(state)

      assert Enum.at(rows, 1) == "Changes"
      assert "No files changed yet" in rows
      refute Enum.any?(rows, &String.contains?(&1, "0 files"))
    end
  end

  describe "timeline tab" do
    test "lists the run's events oldest first with time, agent, kind and text" do
      rows = rows(:swarm, 170, 34, tab: :timeline)

      assert Enum.at(rows, 1) == "Timeline · 7 events"
      # 46 cells: the time, the widest name, the widest kind word, then the text.
      assert Enum.at(rows, 2) =~ ~r/^\d\d:\d\d you {7}text {4}Review this synthetic…$/
      assert Enum.at(rows, 3) =~ ~r/^\d\d:\d\d scout-1 {3}tool {4}grep "Repo\\."$/
      assert Enum.at(rows, 5) =~ ~r/^\d\d:\d\d lead {6}thought The refresh path/
      assert Enum.at(rows, 7) =~ ~r/^\d\d:\d\d builder-4 error {3}run_command failed: m…$/
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
