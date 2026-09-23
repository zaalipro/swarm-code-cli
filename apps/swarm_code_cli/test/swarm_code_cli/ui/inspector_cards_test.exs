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
    test "the first row names the three tabs, each name is clickable, and the waiting count follows agents" do
      {rows, table, _plan, _rect} = :swarm |> state(170, 34) |> painted()

      # The swarm fixture has one interaction waiting on you.
      assert hd(rows) == "agents   1   timeline  changes"

      # The strip names every tab once; the lead card's foot offers the other two again.
      assert length(targets(table, {:local, {:set_tab, :agents}})) == 1
      assert length(targets(table, {:local, {:set_tab, :timeline}})) == 2
      assert length(targets(table, {:local, {:set_tab, :changes}})) == 2

      assert hd(rows(:chat, 170, 34)) == "agents  timeline  changes"
    end

    test "the current tab is lit on the hover surface and the count is amber" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor], tab: :timeline)
      {rows, _table, plan, rect} = painted(state, :truecolor)

      assert foreground(plan, rect, rows, "timeline") == {:rgb, 255, 106, 26}
      assert background(plan, rect, rows, "timeline") == {:rgb, 38, 38, 38}
      assert background(plan, rect, rows, " 1 ") == @warning
    end

    test "older tab spellings and unknown values fall back to the agents tab" do
      for tab <- [:thread, :overview, :nonsense] do
        assert :swarm |> state(170, 34, tab: tab) |> painted() |> elem(0) |> hd() ==
                 "agents   1   timeline  changes"
      end
    end
  end

  describe "agent cards" do
    test "the agents tab paints the lead card, the sub-agent rows and the operations drawer" do
      rows = rows(:swarm, 170, 34)

      # The lead card: corners, head, the avatar rows, chips, divider, task, gauge, foot.
      assert Enum.at(rows, 1) =~ ~r/^▗ +▖$/
      assert Enum.at(rows, 2) =~ ~r/^▐ AGENT +stop$/
      assert Enum.at(rows, 3) =~ ~r/^▐ {6}lead +⬤ ACTIVE$/
      assert Enum.at(rows, 4) =~ ~r/^▐ {2}⬡ {3}LEAD AGENT · kimi-k2-thinking$/
      assert Enum.at(rows, 5) =~ ~r/^▐ {6}4 sub-agents · \d\d:\d\d · 22k tok$/
      assert Enum.at(rows, 6) == "▐ no tools yet"
      assert Enum.at(rows, 7) == "▐ " <> String.duplicate("▬", 40)
      assert Enum.at(rows, 8) =~ ~r/^▐ CURRENT TASK +35%$/
      assert Enum.at(rows, 9) == "▐ " <> String.duplicate("▐", 40)
      assert Enum.at(rows, 10) =~ ~r/^▐ planning +LEAD 7\.6k · SUBS 15k$/
      assert Enum.at(rows, 11) == "▐ ◷ lanes  ⎇ diff"
      assert Enum.at(rows, 12) =~ ~r/^▝ +▘$/

      # The sub-agents, one row each at the default 42-cell dock.
      assert Enum.at(rows, 14) =~ ~r/^SUB-AGENTS +1 waiting$/
      assert Enum.at(rows, 15) =~ ~r/^› ✦ scout-1 {3}grep "Repo\\." {3}▐▐▐▐▐▐ {2}3\.9k$/
      assert Enum.at(rows, 16) =~ ~r/^› ✦ scout-2 {3}read test\/sess… {1}▐▐▐▐▐▐ {2}3\.5k$/
      assert Enum.at(rows, 17) =~ ~r/^› ✦ builder-4 edit lib\/swarm… {1}▐▐▐▐▐▐ {2}6\.7k$/
      assert Enum.at(rows, 18) =~ ~r/^› ⚖ judge {5}waiting for you {1}▐▐▐▐▐▐ {2}1\.2k$/

      # The drawer follows the newest running sub-agent.
      assert Enum.at(rows, 20) =~ ~r/^OPERATIONS · builder-4 +2 ops$/
      assert Enum.at(rows, 21) =~ ~r/^✎ edit_file +\+42 −7 +active$/
      assert Enum.at(rows, 22) =~ ~r/^✕ error {5}run_command failed: … {2}failed$/

      refute Enum.any?(rows, &String.contains?(&1, "HIVE"))
      refute Enum.any?(rows, &(&1 =~ ~r/· 0\b/))
    end

    test "every sub-agent row selects it, the lead offers stop, and the foot switches tabs" do
      state = state(:swarm, 170, 34)
      {_rows, table, _plan, _rect} = painted(state)

      for id <- ~w(agent-2 agent-3 agent-4 agent-5) do
        assert length(targets(table, {:local, {:select_agent, id}})) == 1, id
      end

      assert targets(table, {:local, {:select_agent, "agent-1"}}) == []
      assert length(targets(table, {:intent, {:stop_agent, @run, "agent-1", 1}})) == 1
      # One on the strip and one on the card's foot.
      assert length(targets(table, {:local, {:set_tab, :timeline}})) == 2
      assert length(targets(table, {:local, {:set_tab, :changes}})) == 2
    end

    test "selecting an agent moves the drawer to it" do
      state = state(:swarm, 170, 34)
      {state, []} = Reducer.update(state, {:select_agent, "agent-2"})
      assert state.tabs.agent == "agent-2"
      {rows, _, _, _} = painted(state)

      assert Enum.any?(rows, &(&1 =~ ~r/^OPERATIONS · scout-1 +1 op$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^⌕ grep lib\/ test\/ · 41 hits +done {2}400ms$/))
    end

    test "a waiting agent is painted in the warning colour and the lead's status is green" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor])
      {rows, _table, plan, rect} = painted(state, :truecolor)

      assert foreground(plan, rect, rows, "waiting for you") == @warning
      assert foreground(plan, rect, rows, "⚖ judge") == @warning
      assert foreground(plan, rect, rows, "ACTIVE") == {:rgb, 61, 220, 90}
      refute Enum.any?(rows, &String.contains?(&1, "NEEDS ANSWER"))
    end

    test "a failed sub-agent carries its error in the error colour and a cross in the heading" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor])

      state =
        put_in(state.read_model.agents["agent-4"], %{
          state.read_model.agents["agent-4"]
          | state: :failed,
            error: "mix test exited with status 1"
        })

      {rows, _table, plan, rect} = painted(state, :truecolor)
      assert Enum.any?(rows, &(&1 =~ ~r/^› ✦ builder-4 mix test exite…/))
      assert Enum.any?(rows, &(&1 =~ ~r/^› ⚖ judge {5}waiting for you /))
      assert foreground(plan, rect, rows, "mix test exite") == {:rgb, 255, 77, 79}
      assert Enum.any?(rows, &(&1 =~ ~r/^SUB-AGENTS +1 waiting · 1 failed$/))
    end

    test "the lead's chips name the tools it used, three at most and then a count" do
      state = state(:swarm, 170, 34)
      items = state.read_model.transcript
      base = Map.fetch!(items, "005")

      extra =
        for {name, n} <- [{"grep", 1}, {"read_file", 2}, {"run_command", 3}, {"web_search", 4}],
            into: %{} do
          id = "lead-tool-#{n}"

          {id,
           %{
             base
             | id: id,
               agent_id: "agent-1",
               at: base.at + n,
               tool: %{base.tool | name: name}
           }}
        end

      state = put_in(state.read_model.transcript, Map.merge(items, extra))
      {rows, _, _, _} = painted(state)
      assert Enum.at(rows, 6) == "▐  grep   read_file   run_command   +1"
    end

    test "the cards degrade to their ASCII twins" do
      rows = rows(:swarm, 170, 34, caps: [ascii?: true])

      assert Enum.at(rows, 3) =~ ~r/^# {6}lead +\* ACTIVE$/
      assert Enum.at(rows, 4) =~ ~r/^# {2}o {3}LEAD AGENT · kimi-k2-thinking$/
      assert Enum.at(rows, 9) == "# " <> String.duplicate("#", 14) <> String.duplicate("-", 26)
      assert Enum.at(rows, 15) =~ ~r/^> \+ scout-1 {3}grep "Repo\\." {3}####-- {2}3\.9k$/
      assert Enum.at(rows, 18) =~ ~r/^> j judge {5}waiting for you {1}------ {2}1\.2k$/
      refute Enum.any?(rows, &(&1 =~ ~r/[⬢⬡✦⚖⬤▐▬◷⎇›]/u))
    end

    test "a run with no agents draws the assistant as the lead card with no sub-agents" do
      rows = rows(:chat, 170, 34)

      assert Enum.at(rows, 3) =~ ~r/^▐ {6}assistant +⬤ ACTIVE$/
      assert Enum.at(rows, 4) =~ ~r/^▐ {2}✳ {3}ASSISTANT · deepseek-v4-pro$/
      assert Enum.at(rows, 5) =~ ~r/^▐ {6}\d\d:\d\d · 4\.0k tok$/
      assert Enum.at(rows, 10) =~ ~r/^▐ writing +4\.0k TOKENS$/
      refute Enum.any?(rows, &String.contains?(&1, "SUB-AGENTS"))
      refute Enum.any?(rows, &String.contains?(&1, "stop"))
      refute Enum.any?(rows, &(&1 =~ ~r/· 0\b/))
      assert Enum.any?(rows, &(&1 =~ ~r/^OPERATIONS · assistant$/))
      assert Enum.any?(rows, &(&1 == "nothing yet"))
    end

    test "a wider dock lays the sub-agents out as two columns of mini cards" do
      state = state(:swarm, 170, 34)
      state = %{state | preferences: %{state.preferences | inspector_width: 56}}
      {rows, table, _, rect} = painted(state)

      assert rect.width == 56
      assert Enum.any?(rows, &(&1 =~ ~r/^▗ +▖ ▗ +▖$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ ✦ scout-1 +⬤ ▐ ✦ scout-2 +⬤$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ SUB · D1 +▐ SUB · D1$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ 3\.9k TOK +1 op ▐ 3\.5k TOK +1 op$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ ✦ builder-4 +⬤ ▐ ⚖ judge +!$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ SUB · D1 +▐ JUDGE · D1 · QUESTION$/))

      for id <- ~w(agent-2 agent-3 agent-4 agent-5) do
        assert length(targets(table, {:local, {:select_agent, id}})) == 1, id
      end
    end

    test "a child of a superseded turn keeps the catalogue's exact words, as a row or on its card" do
      state = state(:swarm, 170, 34)
      state = put_in(state.read_model.agents["agent-3"].launched_by_superseded, true)
      {rows, _, _, _} = painted(state)

      lane = Enum.find_index(rows, &String.starts_with?(&1, "› ✦ scout-2"))
      assert Enum.at(rows, lane + 1) == "LAUNCHED BY SUPERSEDED TURN"

      wide = %{state | preferences: %{state.preferences | inspector_width: 56}}
      {rows, _, _, _} = painted(wide)
      # scout-2 sits in the right column, so the phrase is elided to the card's 25 cells.
      assert Enum.any?(rows, &(&1 =~ ~r/▐ 3\.9k TOK +1 op ▐ LAUNCHED BY SUPERSEDED T…$/))
    end

    test "a short region keeps the lead card whole and never cuts a card in the middle" do
      docked =
        for {cols, lines} <- [{150, 30}, {170, 30}, {170, 32}, {200, 30}, {130, 34}],
            state = state(:swarm, cols, lines),
            dock?(state),
            do: painted(state) |> elem(0)

      assert length(docked) >= 2

      for rows <- docked do
        assert Enum.at(rows, 2) =~ ~r/^▐ AGENT +stop$/
        tops = Enum.count(rows, &(&1 =~ ~r/^▗ +▖$/))
        bottoms = Enum.count(rows, &(&1 =~ ~r/^▝ +▘$/))
        assert tops == bottoms and tops >= 1
      end
    end

    test "a stopped sub-agent says so in words, never STOPPED alone" do
      state = state(:swarm, 170, 34)
      state = put_in(state.read_model.agents["agent-2"].state, :stopped)
      state = put_in(state.read_model.agents["agent-2"].step, "")
      {rows, _, _, _} = painted(state)

      assert Enum.any?(rows, &(&1 =~ ~r/^› ✦ scout-1 {3}stopped by you/))
      refute Enum.any?(rows, &String.contains?(&1, "STOPPED"))
      assert Words.state(:stopped) == "stopped by you"
    end

    test "a pending interaction draws the waiting card under the lead, and its head opens it" do
      state = state(:swarm, 170, 34)

      interaction = %SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction{
        id: "ask-1",
        run_id: @run,
        node_id: "agent-5",
        conversation_id: "fixture-conversation",
        kind: :approval,
        expected_revision: 5,
        state: :pending,
        approval: %SwarmCodeCLI.UI.DataSource.DTO.Approval{
          tool: "run_command",
          permission: :execute,
          arguments_preview: "mix ecto.migrate"
        },
        allowed_actions: [:approve, :deny],
        urgency: :high,
        created_at: @now - 1_000
      }

      state = put_in(state.read_model.interactions, %{"ask-1" => interaction})
      {rows, table, _, _} = painted(state)

      assert Enum.at(rows, 13) =~ ~r/^▗ +▖$/
      assert Enum.at(rows, 14) == "▐ ! judge wants to run a command"
      assert Enum.at(rows, 15) == "▐ $ mix ecto.migrate"
      assert Enum.at(rows, 16) == "▐ decide in the composer below"
      assert length(targets(table, {:local, {:open_interaction, "ask-1"}})) == 1
    end
  end

  describe "verdict card" do
    test "the thread tab of a consensus run shows the newest verdict below the hive" do
      rows = rows(:consensus, 170, 34)

      v = Enum.find_index(rows, &(&1 == "VERDICT · round 1 · done"))
      assert v, "no verdict row"
      assert Enum.at(rows, v + 1) =~ ~r/^✓ tests_pass {6}142 tests, 0 failures$/
      assert Enum.at(rows, v + 2) =~ ~r/^✓ no_regressions  auth paths unchanged$/
      # The panel is 42 cells wide, so the longest note is elided.
      assert Enum.at(rows, v + 3) =~ ~r/^✕ docs_updated {4}architecture.md still d…$/
      assert Enum.at(rows, v + 4) =~ ~r/^— style {11}not evaluated$/
      assert Enum.at(rows, v + 5) =~ ~r/^Two of three proposals meet the bar/
      assert Enum.find_index(rows, &String.starts_with?(&1, "▐ AGENT")) < v
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

      v = Enum.find_index(rows, &(&1 == "VERDICT · round 2 · done"))
      assert v, "no verdict row"
      assert Enum.at(rows, v + 1) =~ ~r/^✓ docs_updated  docs landed$/
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

      v = Enum.find_index(rows, &(&1 == "VERDICT"))
      assert v, "no verdict row"
      assert Enum.at(rows, v + 1) == "No verdict yet · judge running"
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ {6}judge +⬤ ACTIVE$/))
      assert Enum.any?(rows, &(&1 =~ ~r/^▐ reading proposal B/))
    end

    test "the agents tab of a consensus run carries the verdict card below the hive; the other tabs do not" do
      rows = rows(:consensus, 170, 34, tab: :agents)
      lead = Enum.find_index(rows, &(&1 =~ ~r/^▐ AGENT/))
      verdict = Enum.find_index(rows, &String.starts_with?(&1, "VERDICT"))
      assert lead && verdict && verdict > lead

      for tab <- [:timeline, :changes] do
        refute Enum.any?(rows(:consensus, 170, 34, tab: tab), &String.contains?(&1, "VERDICT"))
      end
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
