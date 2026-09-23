defmodule SwarmCodeCLI.UI.Paint.BlocksTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{SafeText, Scene, Width}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias Scene.{Block, Span, Style}
  @base %{foreground: nil, background: nil, modifiers: []}
  defp safe(text), do: elem(SafeText.external(text, Limits.content()), 1)
  defp text(value), do: %Block.Text{text: safe(value)}

  # A card surface paints as a rectangle: its text, then its own background to
  # the end of the row. `strings/1` reports every glyph on the row, so a card row
  # is the text followed by exactly enough spaces to reach the region width.
  defp filled(value, width \\ 80),
    do: value <> String.duplicate(" ", width - Width.cells(value, :narrow))

  defp layout(blocks, width \\ 80, rows \\ 100, options \\ %Options{}) do
    assert {:ok, lines} = Blocks.lines(blocks, width, options, @base, rows)
    lines
  end

  defp strings(lines), do: Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))

  test "text and rich spans share wrapping, styles and action IDs" do
    lines =
      layout(
        [
          %Block.RichText{
            action_id: "parent",
            spans: [
              %Span{text: safe("ab"), style: %Style{modifiers: [:bold]}},
              %Span{text: safe("界c"), action_id: "child"}
            ]
          }
        ],
        4
      )

    assert strings(lines) == ["ab界", "c"]
    assert hd(hd(lines).units).style.modifiers == [:bold]
    assert hd(hd(lines).units).action_id == "parent"
    assert List.last(hd(lines).units).action_id == "child"
    assert strings(layout([text("abcdef")], 3, 1)) == ["abc"]
  end

  test "every block has a readable deterministic presentation" do
    cases = [
      {text("hello"), ["hello"]},
      {%Block.RichText{spans: [%Span{text: safe("rich")}]}, ["rich"]},
      {%Block.Markdown{text: safe("# Title\n- item")}, ["Title", "• item"]},
      {%Block.Code{text: safe("a\nb"), language: safe("elixir")}, ["elixir", "a", "b"]},
      {%Block.VirtualList{total_count: 99, first_index: 20, items: [text("one"), text("two")]},
       ["one", "two"]},
      {%Block.RunCard{id: "run", title: safe("Build"), status: :done, body: [text("body")]},
       [filled("▐ Build — DONE"), filled("▐ body")]},
      {%Block.AgentList{agents: [safe("agent one"), text("agent two")]},
       ["agent one", "agent two"]},
      {%Block.ConsensusLedger{entries: [safe("vote")]}, ["Consensus", "vote"]},
      {%Block.ResearchDocument{title: safe("Sources"), sources: [safe("source")]},
       ["Sources", "source"]},
      {%Block.Progress{label: safe("Load"), value: 1, maximum: 2},
       ["Load [██████████░░░░░░░░░░] 50%"]},
      {%Block.Progress{label: safe("Load")}, ["Load …"]},
      {%Block.Tabs{tabs: [safe("A"), safe("B")], selected: 1}, ["A  B"]},
      {%Block.KeyValues{rows: [{safe("Name"), safe("Value")}]}, ["Name: Value"]},
      {%Block.Composer{text: safe(""), placeholder: safe("Type here")}, ["Type here"]},
      {%Block.Notice{text: safe("Ready"), severity: :info, action_id: "notice"}, ["Ready"]},
      {%Block.ActionDeck{actions: [safe("Yes"), safe("No")]}, ["Yes  No"]},
      {%Block.Diff{
         path: safe("lib/foo.ex"),
         added: 1,
         removed: 1,
         hunks: [
           {safe("@@ -1 +1 @@"),
            [{:ctx, safe(" keep")}, {:del, safe("-old")}, {:add, safe("+new")}]}
         ]
       }, ["lib/foo.ex  +1  -1", "@@ -1 +1 @@", " keep", "-old", "+new"]},
      {%Block.Gauge{tone: :accent, value: 1, maximum: 2, style: :ticks},
       [String.duplicate("▐", 80)]},
      {%Block.Chart{series: [4, 0], tone: :accent, height: 1}, [<<0x2847::utf8>>]},
      {%Block.Surface{blocks: [text("inner")], tone: :card}, [filled(" inner")]},
      {%Block.Columns{
         columns: [%{width: 3, blocks: [text("a")]}, %{width: 3, blocks: [text("b")]}],
         gap: 1
       }, ["a   b  "]}
    ]

    assert MapSet.new(Enum.map(cases, fn {block, _} -> block.__struct__ end)) ==
             MapSet.new(Block.modules())

    for {block, expected} <- cases,
        do: assert(strings(layout([block])) == expected, inspect(block.__struct__))

    # Monochrome spells what colour shows.
    notice = %Block.Notice{text: safe("Ready"), severity: :info}

    assert strings(layout([notice], 80, 100, %Options{color_mode: :monochrome})) == [
             "[INFO] Ready"
           ]
  end

  test "prefix is emitted once and ascii only affects trusted chrome" do
    span = %Span{
      text: safe("é界—"),
      style: %Style{role: :warning, prefix: safe("→")},
      action_id: "a"
    }

    assert strings(layout([span], 80, 100, %Options{ascii?: true})) == ["→ é界—"]

    assert strings(
             layout(
               [%Block.RunCard{id: "r", title: safe("界—"), status: :done}],
               80,
               100,
               %Options{ascii?: true}
             )
           ) == [filled("| 界— - DONE")]
  end

  test "action deck wraps between whole labels and preserves IDs" do
    deck = %Block.ActionDeck{
      actions: [
        %Span{text: safe("One"), action_id: "one"},
        %Span{text: safe("Two"), action_id: "two"},
        %Span{text: safe("Three"), action_id: "three"}
      ]
    }

    lines = layout([deck], 8, 2)
    assert strings(lines) == ["One  Two", "Three"]

    assert Enum.map(hd(lines).units, & &1.action_id) == [
             "one",
             "one",
             "one",
             nil,
             nil,
             "two",
             "two",
             "two"
           ]

    assert Enum.all?(List.last(lines).units, &(&1.action_id == "three"))
  end

  test "nested containers share a row bound and emit one header each" do
    nested = %Block.RunCard{
      id: "r",
      title: safe("Run"),
      status: :running,
      body: [%Block.ResearchDocument{title: safe("Sources"), sources: [text("one"), text("two")]}]
    }

    assert strings(layout([nested, text("last")], 80, 3)) ==
             [filled("▐ Run — RUNNING"), filled("▐ Sources"), filled("▐ one")]

    assert layout([nested], 80, 0) == []
  end

  test "a run card paints as a card: status edge, inset body, filled to the region" do
    card = %Block.RunCard{id: "r", title: safe("Build"), status: :failed, body: [text("body")]}
    [header, body] = layout([card], 20)

    # Both rows are the full region width, so the card is a rectangle rather than
    # a ragged run of text that stops wherever its content ends.
    assert header.cells == 20
    assert body.cells == 20
    assert strings([header, body]) == [filled("▐ Build — FAILED", 20), filled("▐ body", 20)]

    surface = List.last(header.units).style.background
    assert surface != nil

    for line <- [header, body] do
      [edge, gutter | rest] = line.units
      # A one-cell status edge, then the two-cell gutter that insets the body.
      assert edge.text == "▐"
      assert gutter.text == " "
      assert Enum.all?(rest, &(&1.style.background == surface))
      # The right pad keeps the last cell on the surface and off the text.
      assert List.last(line.units).text == " "
    end

    # The edge is coloured by the run's status, not by one fixed accent.
    edges =
      for status <- [:failed, :done, :running],
          do: hd(hd(layout([%{card | status: status}], 20)).units).style.foreground

    assert Enum.all?(edges, &(&1 != nil))
    assert Enum.uniq(edges) == edges

    # A card never overflows its region. Under four columns the frame costs more
    # cells than there are, so the run degrades to plain text instead.
    for width <- 1..8 do
      assert Enum.all?(layout([card], width), &(&1.cells <= width)),
             "a run card overflowed a #{width}-column region"
    end

    assert strings(layout([card], 3, 1)) == ["Bui"]
  end

  test "selected tabs preserve source newlines and emit a selected prefix only once" do
    # The prefix spells the selection only where colour cannot show it (ux M6).
    mono = %Options{color_mode: :monochrome}
    tabs = [%Block.Tabs{tabs: [text("a\nb")]}]
    assert strings(layout(tabs, 80, 100, mono)) == ["SELECTED > a", "b"]
    assert strings(layout(tabs)) == ["a", "b"]

    tab = %Span{text: safe("Name"), style: %Style{role: :selected}, action_id: "tab"}
    assert strings(layout([%Block.Tabs{tabs: [tab]}], 80, 100, mono)) == ["SELECTED > Name"]
    assert strings(layout([%Block.Tabs{tabs: [tab]}])) == ["Name"]
  end

  test "rejects structural floods even when every item is empty" do
    assert {:error, :capacity_exceeded} =
             Blocks.lines(List.duplicate(safe(""), 4097), 10, %Options{}, @base, 1)
  end

  test "rejects unknown shapes and invalid SafeText" do
    assert {:error, :invalid_scene} = Blocks.lines([%{text: safe("x")}], 10, %Options{}, @base, 1)

    assert {:error, :invalid_text} =
             Blocks.lines(
               [%Block.Text{text: %SafeText{token: {:external, <<27>>}}}],
               10,
               %Options{},
               @base,
               1
             )
  end
end
