defmodule SwarmCodeCLI.UI.Projector.C75PanelTest do
  @moduledoc """
  pass 75 lane P: the V2 side panel the owner picked (SA2 "One line each"),
  row by row from `:panel_owner19` at 176x45 (the panel is 46 wide), and the
  rules behind it: the attention sort, figures, AI names cut at their end,
  the ASCII twins, compact mode, the status lines with summaries on and off,
  and SA S3's band from `:panel_owner19_band`.

  The mockup draws the consensus mark as `C`; the CLI's mark is
  `Theme.run_mark(:consensus_judge)` (`⚖` at the rich tier, `C` in ASCII), so
  the expected rows take the mark the state draws. V2's `2 of 4 in` reads
  `1 of 4 in` (D-L12: a turn-limit stop no longer counts).
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Panel, as: Scenes
  alias SwarmCodeCLI.UI.{Capabilities, Layout, Paint, Projector, SafeText, Size, Theme, Width}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Panel
  alias SwarmCodeCLI.UI.Projector.Panel.Draw

  defp caps(size, opts) do
    %Capabilities{
      size: size,
      color_mode: Keyword.get(opts, :mode, :truecolor),
      ascii?: Keyword.get(opts, :ascii?, false),
      glyph_tier: Keyword.get(opts, :tier, :rich),
      ambiguous_width: Keyword.get(opts, :policy, :narrow)
    }
  end

  defp state(scene, columns, rows, opts \\ []) do
    size = %Size{columns: columns, rows: rows}
    state = Scenes.state(scene, size, caps(size, opts))
    state = Map.put(state, :panel_mode, Keyword.get(opts, :panel, :full))

    case Keyword.get(opts, :hint) do
      nil -> state
      labels -> Map.put(state, :hint, %{labels: labels, typed: ""})
    end
  end

  defp screen(state) do
    {scene, _} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    {:ok, plan} = Paint.build(scene, options)
    assert plan.diagnostics == []

    for y <- 0..(state.size.rows - 1) do
      for x <- 0..(state.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp panel_text(state) do
    rect = Layout.for_state(state).rects.inspector
    policy = state.capabilities.ambiguous_width

    state
    |> screen()
    |> Enum.slice(rect.y, rect.height)
    |> Enum.map(fn row ->
      {_, rest, _} = Width.take_cells(row, rect.x, policy)
      rest
    end)
  end

  defp rows(state), do: state |> panel_text() |> Enum.map(&String.trim_trailing/1)

  # The panel's spans (what `Panel.plan/3` draws), for their styles.
  defp spans(state) do
    rect = Layout.for_state(state).rects.inspector

    state
    |> Panel.plan(rect.width, rect.height)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(& &1.spans)
  end

  # The span whose text, trimmed, is `text` (the first one).
  defp span(state, text) do
    Enum.find(spans(state), &(String.trim(SafeText.value(&1.text)) == text)) ||
      flunk("no span #{inspect(text)}")
  end

  defp fg(state, role), do: Theme.style(role, state.capabilities).foreground

  defp assert_role(state, text, role, bold? \\ false) do
    style = span(state, text).style
    assert style.foreground == fg(state, role), "#{inspect(text)} is not #{role}"
    if bold?, do: assert(:bold in style.modifiers, "#{inspect(text)} is not bold")
  end

  defp mark(state), do: Draw.mark(:consensus_judge, state)

  # SA2 V2 (SA2.html 45-67), `2 of 4 in` read as `1 of 4 in` (D-L12).
  defp v2(c) do
    [
      "▌#{c} lets plan how to make this app better",
      "   consensus · in chat · 65k · $0.01    00:49",
      " ⋔ swarm review changes  1 of 4 in      16:15",
      "",
      " found           1 of 4 in · no files changed",
      " ⋔ ▄▄▄▄▄▄▄▄▄ ▁▁▁▁▁▁▁▁▁ ▁▁▁▁▁▁▁▁▁ ▁▁▁▁▁▁▁▁▁",
      "   1 came back empty · the Lead waits for 2",
      "",
      "   ✓ TS removal                   8:34 · 840k",
      "     Deleting ailogic_typescript/ is safe:",
      "     nothing in lib/ or assets/ imports it.",
      "     mix.exs:12 · README.md:21",
      "",
      " agents                    3 live · 1 stopped",
      " #{c} ◒ Consensus      reading the repo     3/30",
      " ⋔ ✗ Build check    build never ran   ✗ 30/30",
      "   ◒ Strategy fit   weighing 2 plans quiet 1m",
      "   ◒ Docs accuracy  checking app data   21/30",
      "   ◌ Lead           waiting for 2        4/30",
      "",
      " spent $0.82 · 4.1M tokens · 2 runs",
      " earlier  3 stopped runs in this chat  Ctrl-R",
      " ^F agents  ^N needs you  ^B panel"
    ]
  end

  # ------------------------------------------------------------ the frame

  test "V2 at 176x45: every row of the picked frame, then blank rows" do
    st = state(:panel_owner19, 176, 45)
    assert Layout.for_state(st).rects.inspector.width == 46
    rows = rows(st)

    assert Enum.take(rows, 23) == v2(mark(st))
    assert rows |> Enum.drop(23) |> Enum.all?(&(&1 == ""))
  end

  test "V2's roles: the accent bar, stops, quiet, lane hues, status words, the tail" do
    st = state(:panel_owner19, 176, 45)

    assert_role(st, "▌", :accent)
    assert_role(st, "✗", :error)
    assert_role(st, "✗ 30/30", :error)
    assert_role(st, "quiet 1m", :warning)
    assert_role(st, "TS removal", :agent_lane_1)
    assert_role(st, "Docs accuracy", :agent_lane_2)
    assert_role(st, "Build check", :agent_lane_3)
    assert_role(st, "Strategy fit", :agent_lane_4)
    assert_role(st, "Consensus", :text_primary)
    assert_role(st, "Lead", :text_primary)
    assert_role(st, "reading the repo", :text_muted)
    assert_role(st, "build never ran", :text_muted)
    assert_role(st, "waiting for 2", :text_muted)
    assert_role(st, "3/30", :text_muted)
    assert_role(st, "21/30", :text_muted)
    assert_role(st, "spent", :text_faint)
    assert_role(st, "$0.82", :text_primary)
    assert_role(st, "Ctrl-R", :text_muted, true)
    assert_role(st, "^F", :text_muted, true)
    assert_role(st, "✓", :success)
  end

  # 410 (sandbox, frame SA2 O): the overlay counted the Lead as a lane, so
  # its header drew a worker in its neighbour's hue.
  test "the ^F overlay names an agent in the hue the panel gives it" do
    st = state(:panel_owner19, 176, 45)

    build =
      st.read_model.agents
      |> Map.values()
      |> Enum.find(&(Panel.Name.of(st, &1) == "Build check"))

    {st, _} = SwarmCodeCLI.UI.Reducer.update(st, {:overlay_open, build.run_id, build.id})
    {scene, _} = Projector.project(st)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor, ascii?: false})

    cells =
      for x <- 0..(st.size.columns - 1) do
        case Plan.cell(plan, x, 0) do
          {:glyph, glyph, _, index} -> {x, glyph, index}
          _ -> {x, "", nil}
        end
      end

    text = Enum.map_join(cells, &elem(&1, 1))
    assert text =~ "Build check"
    [before | _] = String.split(text, "Build check", parts: 2)
    {_, "B", index} = Enum.at(Enum.reject(cells, &(elem(&1, 1) == "")), String.length(before))

    assert elem(plan.palette, index).foreground ==
             Theme.style(:agent_lane_3, st.capabilities).foreground.value
  end

  # ------------------------------------------------------------ the band

  test "SA S3's band: two requests oldest first, AI names, the ask's words" do
    st = state(:panel_owner19_band, 176, 45)
    rows = rows(st)
    c = mark(st)
    at = Enum.find_index(rows, &String.starts_with?(&1, " ! 2 need you"))

    assert Enum.at(rows, at) == " ! 2 need you · oldest first        ^N answer"
    assert Enum.at(rows, at + 1) =~ ~r/^ │ ⋔ Docs accuracy wants to run +0:41$/
    assert Enum.at(rows, at + 2) == " │   rm -rf /tmp/appexchange && curl -sL"
    assert Enum.at(rows, at + 3) == " │   https://appexchange.salesforce.com/…"
    assert Enum.at(rows, at + 4) == " │   dangerous: asks even in full access"
    assert Enum.at(rows, at + 5) == " │ #{c} Consensus asks                      0:12"
    assert Enum.at(rows, at + 6) == " │   1 question: Focus"
    assert Enum.at(rows, at + 7) == " │   4 options, or your own words"
    assert Enum.at(rows, at + 8) == ""
    # The band sits after the header rows and one blank row.
    assert at == 4

    assert_role(st, "│", :warning)
    assert_role(st, "!", :warning, true)
    assert_role(st, "dangerous: asks even in full access", :text_faint)
    refute Enum.any?(rows, &(&1 =~ "answer it in the chat"))
  end

  test "rows are sorted by attention; the in-chat run comes first" do
    rows = rows(state(:panel_owner19_band, 176, 45))
    at = Enum.find_index(rows, &String.starts_with?(&1, " agents"))

    assert Enum.at(rows, at) == " agents                    3 live · 1 stopped"

    names =
      rows
      |> Enum.slice((at + 1)..(at + 5))
      |> Enum.map(&(Regex.run(~r/^ .  ?(. \S+(?: \S+)?)/u, &1) |> List.last()))

    assert names == [
             "! Consensus",
             "! Docs accuracy",
             "✗ Build check",
             "◒ Strategy fit",
             "◌ Lead"
           ]

    assert Enum.at(rows, at + 1) =~ ~r/! Consensus +asks you +3\/30$/
    assert Enum.at(rows, at + 2) =~ ~r/^ ⋔ ! Docs accuracy +wants to run +21\/30$/
  end

  # ------------------------------------------------------------- the rules

  test "a name wider than the column ends in …" do
    st = state(:panel_owner19, 176, 45)
    long = "Strategy fit across both plans"
    assert Width.cells(long, :narrow) == 30
    st = put_in(st.read_model.agents["agent-91-5"].title, long)
    rows = rows(st)

    row = Enum.find(rows, &(&1 =~ "Strategy fit"))
    assert row =~ "◒ Strategy fit across bo… weighi… quiet 1m"
    refute Enum.any?(rows, &(&1 =~ "across both plans"))
    # The figure keeps its place at the row's end.
    assert row =~ ~r/quiet 1m$/
  end

  test "a done agent has no agents row; it is in found" do
    rows = rows(state(:panel_owner19, 176, 45))

    assert [only] = Enum.filter(rows, &(&1 =~ "TS removal"))
    assert only =~ ~r/^   ✓ TS removal/
    refute Enum.any?(rows, &(&1 =~ ~r/[◒◌✗!] TS removal/))
  end

  test "no row uses text_ghost, border, border_soft, card or surface, and none is filled" do
    for scene <- [:panel_owner19, :panel_owner19_band], panel <- [:full, :compact] do
      st = state(scene, 176, 45, panel: panel)
      plain = Theme.style(:plain, st.capabilities).background
      forbidden = Enum.map([:text_ghost, :border, :border_soft], &fg(st, &1))

      fills =
        [:card, :surface]
        |> Enum.map(&Theme.style(&1, st.capabilities).background)
        |> Enum.reject(&(&1 == plain))

      for s <- spans(st) do
        text = SafeText.value(s.text)

        if String.trim(text) != "" do
          refute s.style.foreground in forbidden, "#{scene} #{panel}: #{inspect(text)}"
        end

        refute s.style.background in fills, "#{scene} #{panel}: #{inspect(text)} is filled"
        assert s.style.background == plain, "#{scene} #{panel}: #{inspect(text)} is filled"
      end
    end
  end

  test "the ASCII tier draws o . v x # - S |" do
    st = state(:panel_owner19_band, 176, 45, ascii?: true, tier: :measured)
    rows = rows(st)
    text = Enum.join(rows, "\n")

    assert hd(rows) == "|C lets plan how to make this app better"
    assert text =~ "\n S ######### xxxxxxxxx --------- ---------\n"
    assert text =~ "\n   v TS removal                   8:34 · 840k\n"
    assert text =~ "\n | S Docs accuracy wants to run"
    assert text =~ "\n   x Build check    build never ran   x 30/30\n"
    assert text =~ "\n   o Strategy fit   weighing 2 plans quiet 1m\n"
    assert text =~ "\n   . Lead           waiting for 2        4/30\n"

    for row <- rows do
      assert String.replace(row, ["·", "…"], "") =~ ~r/^[\x20-\x7e]*$/, inspect(row)
    end
  end

  test "compact mode: mark · glyph · name · figure per agent, one earlier row" do
    st = state(:panel_owner19, 176, 45, panel: :compact)
    rows = rows(st)
    c = mark(st)

    assert Enum.take(rows, 12) == [
             "▌#{c} lets plan how to make this app better",
             " #{c} ◒ Consensus                           3/30",
             " ⋔ swarm review changes",
             " found           1 of 4 in · no files changed",
             " ⋔ ✗ Build check                      ✗ 30/30",
             "   ◒ Strategy fit                    quiet 1m",
             "   ◒ Docs accuracy                      21/30",
             "   ◌ Lead                                4/30",
             "",
             " spent $0.82 · 4.1M tokens · 2 runs",
             " earlier  3 stopped runs in this chat  Ctrl-R",
             " ^F agents  ^N needs you  ^B panel"
           ]

    assert Enum.count(rows, &(&1 =~ "earlier")) == 1
  end

  test "summaries off draws the rule sentence in text_faint" do
    st = state(:panel_owner19, 176, 45)
    st = put_in(st.read_model.agents["agent-91-3"].now, "running a command")

    on = rows(st)
    assert Enum.find(on, &(&1 =~ "Docs accuracy")) =~ "checking app data"

    off = Map.put(st, :agent_summaries?, false)
    rows = rows(off)
    row = Enum.find(rows, &(&1 =~ "Docs accuracy"))
    assert row =~ ~r/Docs accuracy  running a command +21\/30$/
    refute Enum.any?(rows, &(&1 =~ ~r/checking app data|reading the repo|weighing 2 plans/))
    assert_role(off, "running a command", :text_faint)
    # A harness fact stays muted: the Lead's waiting words.
    assert_role(off, "waiting for 2", :text_muted)
  end

  test "a held summary is drawn whatever the revision" do
    st = state(:panel_owner19, 176, 45)
    docs = st.read_model.agents["agent-91-3"]
    assert docs.summary_rev == 4 and docs.revision == 1

    assert Enum.find(rows(st), &(&1 =~ "Docs accuracy")) =~ "checking app data"
    assert_role(st, "checking app data", :text_muted)
  end

  # The rules behind the rows, value by value (tasks 141, 142, 147b): the
  # demo scene exercises only its own values.
  describe "Model and Shapes rules" do
    alias SwarmCodeCLI.UI.Projector.Panel.{Model, Shapes}

    test "figures: a turn count warns from 80 %, a working agent is quiet after a minute" do
      st = state(:panel_owner19, 176, 45)
      now = st.now

      assert Model.figure(%{max_turns: 30, turn: 24}, :working, now, st) == {"24/30", :warning}
      assert Model.figure(%{max_turns: 30, turn: 23}, :working, now, st) == {"23/30", :text_muted}
      assert Model.figure(%{lane_at: now - 120_000}, :working, now, st) == {"quiet 2m", :warning}
      assert Model.figure(%{lane_at: now - 59_000}, :working, now, st) == nil
    end

    test "money is two decimals whatever it is, and nil when unpriced" do
      assert Model.money(0.005) == "$0.01"
      assert Model.money(0.0) == "$0.00"
      assert Model.money(0.816) == "$0.82"
      assert Model.money(nil) == nil
      assert Model.money("0.12") == nil
    end

    test "a waiting Lead names the agent it waits on by its AI name" do
      sub = %{id: "s", name: "docs-accuracy-review", display: "Docs accuracy"}

      lead = %{
        id: "l",
        name: "lead",
        role: :lead,
        state: :waiting,
        asks: [],
        summary: nil,
        now: "waiting on docs-accuracy-review"
      }

      st = %{agent_summaries?: true}
      views = [lead, sub]

      assert Model.status_text(lead, views, st) == {"waiting on Docs accuracy", :text_muted}

      assert Model.status_text(%{lead | now: "waiting on 2 agents"}, views, st) ==
               {"waiting for 2", :text_muted}

      assert Model.status_text(%{lead | now: "waiting on other-review"}, views, st) ==
               {"waiting on other-review", :text_muted}
    end

    test "the why-line: who came back empty and what the Lead waits for" do
      st = state(:panel_owner19, 176, 45)
      run = %{state: :running}

      assert Shapes.why_line(run, [%{state: :turn_limit}, %{state: :done}], st) ==
               "1 came back empty · the Lead is writing the report"

      assert Shapes.why_line(
               run,
               [%{state: :failed}, %{state: :working, display: "Strategy fit"}],
               st
             ) == "1 came back empty · the Lead waits for Strategy fit"

      assert Shapes.why_line(
               run,
               [%{state: :turn_limit}, %{state: :working}, %{state: :waiting}],
               st
             ) ==
               "1 came back empty · the Lead waits for 2"

      assert Shapes.why_line(run, [%{state: :done}, %{state: :working}], st) ==
               "the Lead reports once all 2 are in"

      assert Shapes.why_line(%{state: :done}, [%{state: :turn_limit}], st) == nil
    end

    test "the gauge: one cell per agent and no spaces when cells run short" do
      st = state(:panel_owner19, 176, 45)
      on = Draw.g(:report_on, st)

      six =
        Enum.map([:l1, :l2, :l3, :l4, :l5, :l1], &%{state: :done, name_role: &1, finished_at: 1})

      segments = Shapes.report_gauge(six, 12, st)
      assert length(segments) == 6
      assert Enum.all?(segments, fn {text, _role} -> text == on end)
      assert Draw.cells(on, st) == 1
      refute {" ", :text_faint} in segments
    end

    test "the gauge: ended agents by finished_at, a tie keeps the wire order, the rest after" do
      st = state(:panel_owner19, 176, 45)

      views = [
        %{state: :done, name_role: :l1, finished_at: 500},
        %{state: :working, name_role: :l2},
        %{state: :turn_limit, name_role: :l3, finished_at: 500},
        %{state: :done, name_role: :l4, finished_at: 100}
      ]

      segments = Shapes.report_gauge(views, 46, st)
      drawn = Enum.reject(segments, &(&1 == {" ", :text_faint}))

      assert Enum.map(drawn, &elem(&1, 1)) == [:l4, :l1, :error, :text_faint]
      assert Enum.all?(drawn, fn {text, _role} -> Draw.cells(text, st) == 9 end)
      assert length(segments) == 7
    end

    test "one earlier run reads in the singular" do
      st = state(:panel_owner19, 176, 45)
      gone = ["demo-panel-run-88", "demo-panel-run-89"]
      st = put_in(st.read_model.runs, Map.drop(st.read_model.runs, gone))

      assert Enum.any?(rows(st), &(&1 =~ ~r/^ earlier  1 stopped run in this chat +Ctrl-R$/))
    end
  end
end
