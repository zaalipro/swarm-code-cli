defmodule SwarmCodeCLI.UI.Projector.Pass73CardTest do
  @moduledoc """
  pass73 T7 (owner V1): the approval card, redrawn in the D2 language. The
  owner's screenshots: a 4-line `cd … && echo … | head -5; …` wall of text,
  "in the project · dangerous", the keys "y once Y this run d deny D deny &
  stop" directly on top of the draft ("super ugly"). Now a framed card: the
  header with the agent, the verb and the risk word; the reason on its own
  line; the command in a code block of at most six lines until Enter shows
  all; key chips with even spacing; one blank row, then the composer.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Layout, Paint, Projector, Theme, Width}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.ApprovalCard

  @draft "/plan tighten the angular client appyyy"

  defp paint(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?,
        glyph_tier: state.capabilities.glyph_tier
      })

    assert plan.diagnostics == []
    plan
  end

  defp rows(plan) do
    for y <- 0..(plan.size.rows - 1) do
      for x <- 0..(plan.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp main_rows(state, rows) do
    rect = Layout.for_state(state).rects.main
    policy = state.capabilities.ambiguous_width

    rows
    |> Enum.slice(rect.y, rect.height)
    |> Enum.map(fn row ->
      {_, rest, _} = Width.take_cells(row, rect.x, policy)
      {kept, _, _} = Width.take_cells(rest, rect.width, policy)
      String.trim_trailing(kept)
    end)
  end

  defp card(main, top, bottom) do
    first = Enum.find_index(main, &String.starts_with?(&1, "  " <> top))

    last =
      first &&
        main
        |> Enum.drop(first + 1)
        |> Enum.find_index(&String.starts_with?(&1, "  " <> bottom))
        |> then(&(&1 && &1 + first + 1))

    assert first && last && last > first, Enum.join(main, "\n")
    {first, last, Enum.slice(main, first..last)}
  end

  defp style(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, _, _, index} -> elem(plan.palette, index)
      _ -> nil
    end
  end

  for {c, r} <- [{160, 45}, {120, 36}, {80, 24}] do
    test "a framed card at #{c}x#{r}: header, reason, ≤ 6 command lines, chips, a blank row" do
      state = Pass73Scenes.screenshot_11(unquote(c), unquote(r), draft: @draft)
      plan = paint(state)
      all = rows(plan)
      main = main_rows(state, all)
      {first, last, card} = card(main, "╭─ ! angular-plan wants to run a command", "╰─")

      # Every row of the frame closes at the same column.
      widths = Enum.map(card, &Width.cells(&1, :narrow))
      assert Enum.uniq(widths) |> length() == 1, Enum.join(card, "\n")
      assert hd(card) =~ ~r/dangerous +─╮$/
      assert Enum.all?(Enum.slice(card, 1..-2//1), &(&1 =~ ~r/^  │.*│$/u))

      body = Enum.join(card, "\n")
      assert body =~ "check the plan payload's shape"
      assert body =~ "$ cd apps/ailogic_web && curl -s"
      assert body =~ "import json,sys"
      refute body =~ "print(d['owner'])"
      assert body =~ ~r/… \d+ more lines · Enter shows all/

      # At most six command lines: the prompt line and what follows it, up to
      # the "more" line.
      code =
        card
        |> Enum.drop_while(&(not (&1 =~ "$ cd")))
        |> Enum.take_while(&(not (&1 =~ "more lines")))

      assert length(code) in 1..6, Enum.join(card, "\n")

      # The keys: chips in key order, one row when it fits.
      keys = Enum.find(card, &(&1 =~ "deny & stop"))
      assert keys =~ ~r/y +once +Y +this run +A +always “curl” +d +deny +D +deny & stop/

      # The card ends one blank row above the composer: never on it.
      assert last == length(main) - 2, Enum.join(main, "\n")
      assert Enum.at(main, last + 1) == ""
      composer = Layout.for_state(state).rects.composer
      assert Enum.at(all, composer.y) =~ "/plan tighten the angular client appyyy"
      refute Enum.at(all, composer.y - 1) =~ ~r/once|deny|│/u

      # The transcript keeps a blank row above the card when there is room.
      if unquote(r) >= 36, do: assert(Enum.at(main, first - 1) == "")
    end
  end

  test "the keycaps and the risk word carry their chip colours; the frame is amber" do
    state = Pass73Scenes.screenshot_11(160, 45, draft: @draft)
    plan = paint(state)
    all = rows(plan)
    caps = state.capabilities

    y = Enum.find_index(all, &(&1 =~ "deny & stop"))
    row = Enum.at(all, y)
    x = Width.cells(hd(String.split(row, " Y ", parts: 2)), :narrow) + 1
    assert style(plan, x, y).background == Theme.style(:chip_warn, caps).background.value
    # The words beside a keycap sit on the canvas.
    x = Width.cells(hd(String.split(row, "this run", parts: 2)), :narrow)
    assert style(plan, x, y).background == nil

    y = Enum.find_index(all, &(&1 =~ "dangerous"))
    row = Enum.at(all, y)
    x = Width.cells(hd(String.split(row, "dangerous", parts: 2)), :narrow)
    assert style(plan, x, y).background == Theme.style(:chip_err, caps).background.value

    assert style(plan, 2 + Layout.for_state(state).rects.main.x, y).foreground ==
             Theme.style(:warning, caps).foreground.value

    # The command sits on the code block's surface.
    y = Enum.find_index(all, &(&1 =~ "$ cd apps"))
    x = Width.cells(hd(String.split(Enum.at(all, y), "$ cd", parts: 2)), :narrow)
    assert style(plan, x, y).background == Theme.style(:card, caps).background.value
  end

  test "Enter shows all: every command line, the card still above the composer" do
    state = Pass73Scenes.screenshot_11(160, 45, draft: @draft)
    item = state.read_model.interactions["demo-approval-80"]
    state = %{state | selection: Map.put(state.selection, "approval_all", item.id)}

    assert ApprovalCard.expanded?(state, item)
    main = main_rows(state, rows(paint(state)))
    {_first, last, card} = card(main, "╭─ ! angular-plan", "╰─")
    body = Enum.join(card, "\n")

    for line <- ["import json,sys", "print(len(d['steps']), 'steps')", "print(d['owner'])"] do
      assert body =~ line
    end

    refute body =~ "Enter shows all"
    assert last == length(main) - 2
    assert ApprovalCard.hidden_lines(state, Layout.for_state(state).rects.main.width) == 0
  end

  test "PgDn pages a long command while the card is the open layer" do
    state = Pass73Scenes.screenshot_11(160, 45)
    id = "demo-approval-80"

    state = %{
      state
      | layers: [{:approval, id}],
        focus: "cancel",
        selection: Map.put(state.selection, ApprovalCard.scroll_key(), 3)
    }

    width = Layout.for_state(state).rects.main.width
    assert %{window: {3, shown, total}} = ApprovalCard.layout(state, width)
    assert shown <= 6 and total > shown
    body = state |> paint() |> rows() |> Enum.join("\n")
    assert body =~ ~r/lines 4–\d+ of \d+ · PgUp PgDn · Enter shows all/
  end

  test "NO_COLOR and ASCII: an ASCII frame, bracketed keys, the words kept" do
    state = Pass73Scenes.screenshot_11(120, 36, draft: @draft, ascii?: true, mode: :monochrome)
    main = main_rows(state, rows(paint(state)))
    {_first, _last, card} = card(main, "+- ! angular-plan wants to run a command", "+-")
    body = Enum.join(card, "\n")

    assert body =~ "dangerous"
    assert body =~ ~r/\[y\] once +\[Y\] this run +\[A\] always "curl"/
    assert body =~ "... "
    assert Enum.all?(Enum.slice(card, 1..-2//1), &(&1 =~ ~r/^  \|.*\|$/))
    refute body =~ ~r/[╭╮╰╯─│]/u
  end

  test "under the wide ambiguous-width policy the frame is one cell a glyph" do
    state = Pass73Scenes.screenshot_11(160, 45, draft: @draft, policy: :wide, tier: :measured)
    main = main_rows(state, rows(paint(state)))
    {_first, _last, card} = card(main, "⎡⎯ ! angular-plan", "⎣⎯")
    widths = Enum.map(card, &Width.cells(&1, :wide))
    assert length(Enum.uniq(widths)) == 1, Enum.join(card, "\n")
  end

  test "a long command breaks between shell words; a closed quote stays whole" do
    line = "curl -s http://x/y -H 'accept: application/json' | jq ."

    assert ApprovalCard.shell_wrap(line, 24, 30, :narrow) ==
             ["curl -s http://x/y -H", "'accept: application/json' |", "jq ."]

    # A quoted word longer than its row is cut by cells.
    assert ApprovalCard.shell_wrap(line, 24, 20, :narrow) ==
             ["curl -s http://x/y -H", "'accept: application", "/json' | jq ."]

    # A quote with no partner on its line does not hold the rest together.
    assert ApprovalCard.shell_wrap(~s(python3 -c "import sys, json and more), 16, 16, :narrow) ==
             ["python3 -c", ~s("import sys,), "json and more"]

    assert ApprovalCard.shell_wrap(String.duplicate("a", 15), 10, 10, :narrow) ==
             ["aaaaaaaaaa", "aaaaa"]
  end
end
