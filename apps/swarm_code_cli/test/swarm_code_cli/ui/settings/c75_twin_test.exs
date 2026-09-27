defmodule SwarmCodeCLI.UI.Settings.C75TwinTest do
  @moduledoc """
  cli75 (pass 75, E) R28 and the rule that nothing is cut, for every
  section at three sizes and three tiers: exact line widths, no `…` on a
  page line but `+N more` and tables, no box glyph and no stray `?` in
  ASCII, the twin's spine column and titles; ambiguous-width terminals;
  chips, the band and backgrounds under ansi16; the ASCII switch and the
  enum footer.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, except: [screen: 1]

  alias SwarmCodeCLI.UI.{Pass73Helpers, Width}
  alias SwarmCodeCLI.UI.Projector.Settings.{Page, Text}
  alias SwarmCodeCLI.UI.Settings.{Editors, Grid, Nav, Row, Sections}

  @sizes [{160, 45}, {90, 30}, {80, 24}]
  @tiers [:rich, :ascii, :monochrome]
  @fills [:chip_warn, :chip_ok, :chip_info, :chip_accent, :on_accent]

  defp caps(state, :rich),
    do: %{state.capabilities | color_mode: :truecolor, glyph_tier: :rich}

  defp caps(state, :ascii),
    do: %{state.capabilities | color_mode: :truecolor, ascii?: true, glyph_tier: :ascii}

  defp caps(state, :monochrome),
    do: %{state.capabilities | color_mode: :monochrome, glyph_tier: :rich}

  defp caps(state, :ansi16),
    do: %{state.capabilities | color_mode: :ansi16, glyph_tier: :rich}

  defp open(section, {columns, rows}, tier) do
    state = Pass73Helpers.ready([], columns: columns, rows: rows)
    {state, _fake} = opened(section, state: %{state | capabilities: caps(state, tier)})
    state
  end

  defp body_page(state) do
    grid = Grid.for(state.size.columns, state.size.rows)

    state
    |> lines()
    |> Enum.slice(grid.body_top, grid.body_rows)
    |> Enum.map(&String.slice(&1, grid.page.left, grid.page.width))
  end

  # `…` stays only where the row data says `+N more`, on a table row, or
  # where the row's own words hold it (`Reset this section…`).
  defp cut?(line, words, tables?) do
    String.contains?(line, "…") and not tables? and
      not Regex.match?(~r/\+\d+ more/, line) and
      Enum.any?(String.split(line), fn token ->
        token = Regex.replace(~r/^[|│╭╰*!>▌▸+→]+/u, token, "")
        String.contains?(token, "…") and not String.contains?(words, token)
      end)
  end

  test "every section, size and tier: widths, nothing cut, ASCII and the twin (R28)" do
    problems =
      for section <- Sections.ids(), size <- @sizes, tier <- @tiers do
        section |> open(size, tier) |> problems(section, size, tier)
      end

    assert List.flatten(problems) == []

    # the twin's marks are there to be checked: titles, set and default rows
    page = :models_effort |> open({160, 45}, :monochrome) |> body_page()
    assert Enum.any?(page, &(&1 =~ ~r/^   \S.* -{3,}/))
    assert Enum.any?(page, &String.starts_with?(&1, "*  "))
    assert Enum.any?(page, &String.starts_with?(&1, "|  "))
    assert Enum.any?(page, &String.starts_with?(&1, ">  "))
  end

  defp problems(state, section, {columns, _rows} = size, tier) do
    at = "#{section} at #{inspect(size)} #{tier}"
    lines = lines(state)
    page = body_page(state)
    rows = Nav.rows(state)
    words = Enum.map_join(rows, "\n", &all_words/1)
    tables? = Enum.any?(rows, &(&1.columns != nil))
    twin? = tier in [:ascii, :monochrome]

    [
      for(line <- lines, Width.cells(line, :narrow) != columns, do: "#{at} width: #{line}"),
      for(line <- page, cut?(line, words, tables?), do: "#{at} cut: #{line}"),
      if(tier == :ascii,
        do: [
          for(
            line <- lines,
            Regex.match?(~r/[\x{2500}-\x{10FFFF}]/u, line),
            do: "#{at} glyph: #{line}"
          ),
          for(
            line <- page,
            token <- String.split(line),
            token =~ "?",
            not String.contains?(words, String.trim(token, ".,;:()")),
            do: "#{at} ?: #{line}"
          )
        ],
        else: []
      ),
      if(twin?,
        do: [
          for(
            line <- page,
            cell(line, 0) not in ["*", "|", "!", ">", " ", ""],
            do: "#{at} spine: #{line}"
          ),
          # a group title: nothing in the spine column, `   <title> ---`
          for(
            line <- page,
            cell(line, 0) == " ",
            line =~ ~r/ -{3,}/,
            not (line =~ ~r/^   \S.* -{3,}/),
            do: "#{at} title: #{line}"
          )
        ],
        else: []
      )
    ]
  end

  test "a token wider than its column wraps whole: no space is written into it (R22.4)" do
    for {columns, rows} = size <- [{160, 45}, {90, 30}] do
      state = open(:overview, size, :rich)
      grid = Grid.for(columns, rows)
      token = String.duplicate("x", 200)
      name = String.duplicate("A", 60)

      for {row, letter, count} <- [
            {%Row{id: "c75-info", kind: :info, value: [{token, :text_primary}]}, "x", 200},
            {%Row{id: "c75-env", label: name, value: [{"1", :text_primary}]}, "A", 60}
          ] do
        [group] = Page.groups([row])

        texts =
          state
          |> Page.row_lines(row, group, grid)
          |> Enum.map(fn line -> Enum.map_join(line, &elem(&1, 0)) end)

        assert Enum.all?(texts, &(Width.cells(&1, :narrow) == grid.page.width)), inspect(size)
        refute Enum.any?(texts, &(&1 =~ "#{letter} #{letter}")), inspect({size, texts})
        assert texts |> Enum.join() |> String.graphemes() |> Enum.count(&(&1 == letter)) == count
      end
    end
  end

  test "ambiguous-width terminals: every line fits, the label column is 33 (R28.4)" do
    for section <- [:models_effort, :appearance, :storage, :overview] do
      state = Pass73Helpers.ready([], columns: 160, rows: 45)

      caps = %{
        state.capabilities
        | color_mode: :truecolor,
          glyph_tier: :rich,
          ambiguous_width: :wide
      }

      {state, _fake} = opened(section, state: %{state | capabilities: caps})

      for line <- lines(state) do
        assert Width.cells(line, :wide) == 160, "#{section}: #{line}"
      end

      row = Nav.current(state)

      # the focused row's label: the nearest occurrence right of the rail
      # (its first 16 characters: a long label wraps)
      if row && row.label not in [nil, ""] do
        label = String.slice(row.label, 0, 16)

        starts =
          for line <- lines(state), String.contains?(line, label) do
            [before | _] = String.split(line, label, parts: 2)
            Width.cells(before, :wide)
          end

        assert starts |> Enum.filter(&(&1 >= 30)) |> Enum.min() == 33, "#{section}"
      end
    end
  end

  describe "ansi16 and the twin's chips (R28.2, R28.3)" do
    test "the band is reverse video with no background" do
      state = open(:models_effort, {160, 45}, :ansi16)
      banded = for span <- spans(state), banded?(span), do: span
      assert banded != []

      for {_text, style} <- banded do
        assert :reversed in style.modifiers
      end

      assert Enum.any?(banded, fn {text, style} ->
               text =~ "Chat model" and style.background == nil
             end)
    end

    test "no hover, surface or popover background under ansi16" do
      state = open(:models_effort, {160, 45}, :ansi16)

      for fill <- [:hover, :surface, :popover] do
        style = Text.style(state, {:text_primary, :on, fill})
        assert style.background == nil, "#{fill}"
        assert style.foreground == Text.style(state, :text_primary).foreground
      end

      # only fills that carry meaning survive: chips and the enum's candidate
      {help, _} = verb(state, :help)
      {search, _} = verb(state, :search)

      for scene <- [state, help, search, open(:storage, {160, 45}, :ansi16)],
          {text, style} <- spans(scene),
          style.background != nil do
        assert style.role in @fills, "#{inspect(text)} #{style.role}"
      end
    end

    test "chips in the twin are `[text]`" do
      state = open(:overview, {160, 45}, :monochrome)
      assert state |> lines() |> Enum.at(1) =~ ~r/\[! 3 need attention\]/

      # the search's chips: `[theme]` on labels and key lines, no fill
      state = Pass73Helpers.ready([], columns: 160, rows: 45)

      state =
        %{state | capabilities: caps(state, :monochrome)}
        |> act!({:settings_open, nil})
        |> Pass73Helpers.press!(Pass73Helpers.letter("/"))

      state =
        Enum.reduce(String.graphemes("theme"), state, fn letter, acc ->
          Pass73Helpers.press!(acc, Pass73Helpers.letter(letter))
        end)

      page = body_page(state)
      assert Enum.any?(page, &(&1 =~ ~r/^[|>*]  \[Theme\]/))
      assert Enum.any?(page, &(&1 =~ "terminal.[theme]"))
      refute Enum.any?(spans(state), fn {_, style} -> style.role in [:chip_info, :chip_ok] end)
    end
  end

  test "ASCII: a toggle is `[ ] off` / `[x] on`, the enum footer says Left/Right (R28.5)" do
    state = open(:layout, {160, 45}, :ascii)
    [{text, _}] = page_row(state, "Show diffs")
    assert text =~ "[x] on"

    state = open(:appearance, {160, 45}, :ascii)
    [{text, _}] = page_row(state, "Reduced motion")
    assert text =~ "[ ] off"

    state = open(:approvals, {160, 45}, :ascii)
    row = Enum.find(Nav.rows(state), &match?({Editors.Enum, _}, &1.editor))
    {state, _} = state |> Nav.put_cursor(row.id) |> verb(:enter)
    status = state |> lines() |> List.last()
    assert status =~ "Left/Right choose"
    refute status =~ "←"
  end

  defp page_row(state, label) do
    for {text, spans} <- Enum.zip(lines(state), line_spans(state)),
        text =~ ~r/[|>*! ]  #{label}\s{2,}/,
        do: {text, spans}
  end
end
