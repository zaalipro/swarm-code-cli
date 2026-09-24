defmodule SwarmCodeCLI.UI.Projector.PanelTest do
  @moduledoc """
  pass72 owner P: the D side panel (`Projector.Panel`), its strip and its
  order, on the `Demo.Panel` scenes that copy the D2 mockups, and the owner's
  pass-70 bugs as regressions.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Panel, as: Scenes
  alias SwarmCodeCLI.UI.{Capabilities, Layout, Paint, Projector, SafeText, Size, Width}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{Panel, PanelOrder}
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph

  defp caps(size, opts \\ []) do
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

  defp row_text(block), do: Enum.map_join(block.spans, &SafeText.value(&1.text))

  # ------------------------------------------------------------- glyphs

  test "every panel glyph is one cell: rich under narrow, measured under both, ASCII is ASCII" do
    for {token, {rich, measured, ascii}} <- Glyph.table() do
      assert Width.cells(rich, :narrow) == 1, "#{token} rich #{rich}"
      assert Width.cells(measured, :narrow) == 1, "#{token} measured #{measured}"
      assert Width.cells(measured, :wide) == 1, "#{token} measured #{measured} (wide)"
      assert byte_size(ascii) == 1 and ascii < <<128>>, "#{token} ascii #{ascii}"
    end
  end

  # -------------------------------------------------- the pane's edge

  test "every panel row is exactly the pane's width, for every scene, mode, size and policy" do
    for scene <- Scenes.scenes(),
        {c, r} <- [{160, 45}, {120, 36}, {130, 24}],
        policy <- [:narrow, :wide],
        panel <- [:full, :compact],
        tier <- [:rich, :measured] do
      st = state(scene, c, r, policy: policy, panel: panel, tier: tier)
      rect = Layout.for_state(st).rects.inspector
      rows = Panel.project(st, rect, :xl)

      assert length(rows) <= rect.height, "#{scene} #{c}x#{r} #{panel}: #{length(rows)} rows"

      for block <- rows do
        text = row_text(block)

        assert Width.cells(text, policy) == rect.width,
               "#{scene} #{c}x#{r} #{policy} #{panel} #{tier}: #{inspect(text)}"
      end
    end
  end

  test "regression: nothing is painted past the panel's last content column" do
    for scene <- Scenes.scenes(), policy <- [:narrow, :wide] do
      st = state(scene, 160, 45, policy: policy, tier: :measured)

      for row <- panel_text(st) do
        # The pane's last cell is its right margin.
        assert String.ends_with?(row, " "), "#{scene} #{policy}: #{inspect(row)}"
        assert Width.cells(row, policy) == 46
      end
    end
  end

  test "regression: no stray column of half blocks beside the agents" do
    for scene <- Scenes.scenes(), tier <- [:rich, :measured] do
      rows = panel_text(state(scene, 160, 45, tier: tier))
      grid = Enum.map(rows, &String.graphemes/1)

      for x <- 0..45 do
        column = Enum.map(grid, &Enum.at(&1, x))

        runs =
          column
          |> Enum.chunk_by(&(&1 == "▐"))
          |> Enum.filter(&(hd(&1) == "▐"))
          |> Enum.map(&length/1)

        assert Enum.all?(runs, &(&1 < 3)), "#{scene} #{tier}: a ▐ column at #{x}"
      end
    end
  end

  test "regression: no status pill, operation, tool name or isolation text in the panel" do
    for scene <- Scenes.scenes() do
      text = scene |> state(160, 45) |> panel_text() |> Enum.join("\n")

      refute text =~ " active "
      refute text =~ "isolated in"
      refute text =~ "read_file"
      refute text =~ "run_command"
      refute text =~ "Operations"
      refute text =~ ~r/swarm\/[0-9a-f]{6}/
    end
  end

  test "regression: names are whole while the row has room (R14), the shared suffix shown once" do
    text = :panel_swarm_2 |> state(160, 45) |> panel_text() |> Enum.join("\n")

    assert text =~ "engine-lifecycle working"
    assert text =~ "data-persistence thinking"
    assert text =~ "4 × *-review"
    refute text =~ "engine-lifec…"
  end

  # --------------------------------------------------------- the frames

  test "swarm frame 2: header, the band with the literal command and ^N, the tree, the gauge" do
    rows = :panel_swarm_2 |> state(160, 45) |> panel_text() |> Enum.map(&String.trim_trailing/1)
    text = Enum.join(rows, "\n")

    assert Enum.at(rows, 0) =~ ~r/^ ▌⋔ architecture review · in chat +02:14$/
    assert Enum.at(rows, 1) =~ "read-only · 4 × *-review · 65k · $0.15"
    assert text =~ "! NEEDS YOU · web-ui-desktop       1 waiting"
    assert text =~ "   mix test test/swarm_code_web/live"
    assert text =~ ~r/run a command · read-only asks +\^N answer/
    assert text =~ ~r/◌ Lead +waiting +2:14 · 9k/
    assert text =~ "├ ● engine-lifecycle working"
    assert text =~ "▅▅▅▅▂▅▅▅▅▅▂▂ tracing where stop is saved"
    assert text =~ ~r/╰ ! web-ui-desktop +needs you/
    assert text =~ "▅▅▂▅▅▅▅▅▒▒▒▒ wants to run a command"
    assert text =~ "» Fake provider never reaches the refusal"
    assert text =~ "fake.ex:88 +1"
    assert text =~ ~r/reported  ▰▱▱▱  1 of 4 +1 needs you/
    assert text =~ "last 60 s  ▂ think ▅ tools █ write ▒ you"
    assert List.last(rows) =~ ~r/\^F agents  \^N needs you  \^B panel +full$/
  end

  test "the band is absent when nothing waits (frame 3), and findings take the done rows" do
    text = :panel_swarm_3 |> state(160, 45) |> panel_text() |> Enum.join("\n")

    refute text =~ "NEEDS YOU"
    assert text =~ "» stop reason read before the flush"
    assert text =~ "run_server.ex:214 +1"
    assert text =~ "3 of 4"
  end

  test "compact: one row per agent with short names, an 8-cell lane and the action" do
    rows = :panel_swarm_2 |> state(160, 45, panel: :compact) |> panel_text()
    text = Enum.join(rows, "\n")

    assert text =~ "! 1 NEEDS YOU"
    assert text =~ ~r/▌⋔ architecture review · in chat 1\/4 · 02:14/
    assert text =~ ~r/● engine +▂▅▅▅▅▅▂▂ tracing/
    assert text =~ ~r/! web +▅▅▅▅▒▒▒▒ approve: mix test/
    assert text =~ ~r/✓ llm +» Fake provider/
    assert List.last(rows) =~ "compact"
  end

  test "heavy full: the load row, two requests oldest first, the others folded to orbit lines" do
    text = :panel_heavy |> state(160, 45) |> panel_text() |> Enum.join("\n")

    assert text =~ "5 runs · 17 agents"
    assert text =~ "! 2 NEED YOU · oldest first"
    assert text =~ ~r/plug +edit lib\/api\/plug.ex/
    assert text =~ ~r/⋔ api hardening  .*0\/3 · 05:02/
    assert text =~ "! plug wants to edit a file"
    assert text =~ "✗ retry-tests failed · retry in 8 s"
  end

  test "heavy compact fits 160x45 and 120x36 and keeps every run" do
    for {c, r} <- [{160, 45}, {120, 36}] do
      text = :panel_heavy |> state(c, r, panel: :compact) |> panel_text() |> Enum.join("\n")

      for title <- ["architecture review", "api hardening", "suite green", "ship retry"] do
        assert text =~ title, "#{c}x#{r}: #{title}"
      end

      assert text =~ "NEED YOU"
    end
  end

  test "hint mode: a badge before each glyph, the glyph stays, the band keeps its badge" do
    st = state(:panel_swarm_2, 160, 45)
    entries = PanelOrder.entries(st)
    web = Enum.find(entries, &match?({:agent, _, "agent-80-5", true}, &1))
    lead = Enum.find(entries, &match?({:agent, _, "agent-80-1", _}, &1))
    run = Enum.find(entries, &match?({:run, _}, &1))
    assert web && lead && run

    text =
      :panel_swarm_2
      |> state(160, 45, hint: %{"s" => web, "d" => lead, "1" => run})
      |> panel_text()
      |> Enum.join("\n")

    assert text =~ " 1  ▌⋔ architecture review · in chat"
    assert text =~ " d  ◌ Lead"
    assert text =~ " s  ! web-ui-desktop"
    assert text =~ " s  mix test test/swarm_code_web/live"
    assert text =~ "^F again"
    assert text =~ "Esc"
  end

  test "PanelOrder: runs and agents in display order; a folded run keeps its needs-you agent" do
    entries = PanelOrder.entries(state(:panel_swarm_2, 160, 45))

    assert [{:run, "demo-panel-run-80"}, {:agent, _, "agent-80-1", false} | _] = entries
    assert {:agent, "demo-panel-run-80", "agent-80-5", true} in entries

    heavy = PanelOrder.entries(state(:panel_heavy, 160, 45))
    assert {:agent, "demo-panel-run-70", "agent-70-4", true} in heavy
    assert Enum.count(heavy, &match?({:run, _}, &1)) == 5
  end

  test "under 120 columns the panel is one strip ending in ! N needs you ^N (R17)" do
    st = state(:panel_swarm_2, 100, 28)
    rects = Layout.for_state(st).rects
    refute Map.has_key?(rects, :inspector)
    assert rects.tabline.y == 1 and rects.tabline.height == 1

    strip = st |> screen() |> Enum.at(1) |> String.trim_trailing()
    assert strip =~ "▌⋔ architecture review 1/4 · Lead◌ engine● data◐ llm✓ web!"
    assert strip =~ ~r/! 1 needs you \^N$/

    assert [{:run, _} | agents] = PanelOrder.entries(st)
    assert length(agents) == 5
  end

  test "hidden: no dock, no strip, main takes the width" do
    for c <- [160, 100] do
      st = state(:panel_swarm_2, c, 30, panel: :hidden)
      rects = Layout.for_state(st).rects
      refute Map.has_key?(rects, :inspector)
      refute Map.has_key?(rects, :tabline)
      assert rects.main.width == c
      assert PanelOrder.entries(st) == []
    end
  end

  test "NO_COLOR and ASCII: every state keeps its word and its ASCII glyph" do
    st = state(:panel_heavy, 160, 45, mode: :monochrome, ascii?: true, tier: :measured)
    text = st |> panel_text() |> Enum.join("\n")

    for word <- ["working", "thinking", "waiting", "needs you", "done"] do
      assert text =~ word
    end

    compact = state(:panel_heavy, 160, 45, mode: :monochrome, ascii?: true, panel: :compact)
    ctext = compact |> panel_text() |> Enum.join("\n")
    assert ctext =~ "! web"
    assert ctext =~ "x retry"
    assert ctext =~ "v llm"

    for row <- panel_text(st) do
      assert String.replace(row, ["·", "…"], "") =~ ~r/^[\x20-\x7e]*$/, inspect(row)
    end
  end
end
