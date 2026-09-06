defmodule SwarmCodeCLI.UI.Paint.SVGTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Paint.{Plan, SVG}
  alias SwarmCodeCLI.UI.Scene.{Cursor, Rect}
  alias SwarmCodeCLI.UI.Size

  defp plan(overrides) do
    struct(
      Plan,
      Keyword.merge(
        [
          size: %Size{columns: 3, rows: 2},
          cells: {
            {:glyph, "界", 2, 0},
            {:continuation, 0},
            {:glyph, "x", 1, 0},
            {:glyph, "a", 1, 0},
            {:glyph, "b", 1, 0},
            {:glyph, "c", 1, 0}
          },
          palette: {%{foreground: nil, background: nil, modifiers: []}}
        ],
        overrides
      )
    )
  end

  test "fixed cell coordinates preserve the grid and draw only wide glyph leads" do
    input = plan(revision: 37)
    assert {:ok, svg} = SVG.encode(input)
    assert String.valid?(svg)
    assert svg =~ ~s(viewBox="0 0 30 40" width="30" height="40")
    assert svg =~ "<title>FAKE DEMO — NO USER DATA · cell preview</title>"
    assert svg =~ ~s(data-revision="37" data-ambiguous-width="narrow")
    assert length(Regex.scan(~r/<text\s/, svg)) == 5
    assert svg =~ ~r/<text x="0" y="15"[^>]*textLength="20"[^>]*>界<\/text>/
    assert svg =~ ~r/<text x="20" y="15"[^>]*>x<\/text>/
    assert svg =~ ~r/<text x="0" y="35"[^>]*>a<\/text>/
    assert svg =~ ~s(fill="#141414")
    assert svg =~ ~s(fill="#f3f2f0")
    assert input.palette == {%{foreground: nil, background: nil, modifiers: []}}
    assert {:ok, ^svg} = SVG.encode(input)
  end

  test "each continuation receives the lead background and glyphs keep combining text" do
    input =
      plan(palette: {%{foreground: {:rgb, 1, 2, 3}, background: {:rgb, 4, 5, 6}, modifiers: []}})

    assert {:ok, svg} = SVG.encode(input)
    assert svg =~ ~s(<rect x="10" y="0" width="10" height="20" fill="#040506"/>)
    assert svg =~ ~s(fill="#010203")

    assert {:ok, svg} =
             SVG.encode(plan(size: %Size{columns: 1, rows: 1}, cells: {{:glyph, "é", 1, 0}}))

    assert svg =~ ">é</text>"
    assert length(Regex.scan(~r/<text\s/, svg)) == 1
  end

  test "XML text and opaque metadata cannot introduce active markup" do
    glyphs = ["<", ">", "&", "\"", "'"]
    id = ~s|"/><script>alert('x')</script>&|

    input =
      plan(
        size: %Size{columns: 5, rows: 1},
        cells: glyphs |> Enum.map(&{:glyph, &1, 1, 0}) |> List.to_tuple(),
        focus: %{region_id: id, control_id: id, rect: %Rect{x: 0, y: 0, width: 5, height: 1}},
        actions: %{id => [%Rect{x: 2, y: 0, width: 2, height: 1}]}
      )

    assert {:ok, svg} = SVG.encode(input)
    for escaped <- ["&lt;", "&gt;", "&amp;", "&quot;", "&apos;"], do: assert(svg =~ escaped)

    assert svg =~
             ~s|data-action="&quot;/&gt;&lt;script&gt;alert(&apos;x&apos;)&lt;/script&gt;&amp;"|

    assert svg =~ ~s(<rect x="20" y="0" width="20" height="20" fill="none"/>)
    refute svg =~ ~r/<(?:script|foreignObject|image|a)(?:\s|>)/
    refute svg =~ ~r/\s(?:onclick|href|onload|style)=/
    refute svg =~ "url("
    refute svg =~ "<!DOCTYPE"
  end

  test "palette modes map ANSI colors, cube colors and grayscale explicitly" do
    for {mode, foreground, expected} <- [
          {:ansi16, {:ansi, :red}, "#800000"},
          {:ansi16, {:ansi, :bright_blue}, "#0000ff"},
          {:ansi256, {:indexed, 1}, "#800000"},
          {:ansi256, {:indexed, 16}, "#000000"},
          {:ansi256, {:indexed, 67}, "#5f87af"},
          {:ansi256, {:indexed, 231}, "#ffffff"},
          {:ansi256, {:indexed, 232}, "#080808"},
          {:ansi256, {:indexed, 255}, "#eeeeee"},
          {:monochrome, nil, "#f3f2f0"}
        ] do
      assert {:ok, svg} =
               SVG.encode(
                 plan(
                   color_mode: mode,
                   palette: {%{foreground: foreground, background: nil, modifiers: []}}
                 )
               )

      assert svg =~ ~s(fill="#{expected}")
    end
  end

  test "all text modifiers render and reversed swaps resolved colors" do
    input =
      plan(
        palette:
          {%{
             foreground: {:rgb, 1, 2, 3},
             background: {:rgb, 4, 5, 6},
             modifiers: [:bold, :dim, :italic, :underlined, :reversed]
           }}
      )

    assert {:ok, svg} = SVG.encode(input)
    assert svg =~ ~r/<rect[^>]*fill="#010203"/
    assert svg =~ ~r/<text[^>]*fill="#040506"/

    for attribute <- [
          ~s(font-weight="bold"),
          ~s(font-style="italic"),
          ~s(text-decoration="underline"),
          ~s(opacity="0.6")
        ],
        do: assert(svg =~ attribute)

    assert {:ok, svg} =
             SVG.encode(
               plan(palette: {%{foreground: nil, background: nil, modifiers: [:reversed]}})
             )

    assert svg =~ ~r/<rect[^>]*fill="#f3f2f0"/
    assert svg =~ ~r/<text[^>]*fill="#141414"/
  end

  test "visible cursor shapes occupy the authoritative cell coordinate" do
    for {shape, expected} <- [
          {:block, ~s(x="20" y="20" width="10" height="20")},
          {:bar, ~s(x="20" y="20" width="2" height="20")},
          {:underline, ~s(x="20" y="38" width="10" height="2")}
        ] do
      assert {:ok, svg} =
               SVG.encode(plan(cursor: %Cursor{x: 2, y: 1, shape: shape, visible?: true}))

      assert svg =~ ~s(<rect data-cursor="#{shape}" #{expected})
    end

    for cursor <- [nil, %Cursor{x: 2, y: 1, visible?: false}] do
      assert {:ok, svg} = SVG.encode(plan(cursor: cursor))
      refute svg =~ "data-cursor="
    end
  end

  test "focus uses supplied geometry without adding rows or guessing absent geometry" do
    assert {:ok, svg} =
             SVG.encode(
               plan(focus: %{region_id: "main", rect: %Rect{x: 1, y: 0, width: 2, height: 2}})
             )

    assert svg =~
             ~s(<rect data-focus="main" x="11" y="1" width="18" height="38" fill="none" stroke="#ff6a1a" stroke-width="2"/>)

    for focus <- [nil, %{region_id: "main"}] do
      assert {:ok, svg} = SVG.encode(plan(focus: focus))
      refute svg =~ "data-focus="
    end
  end

  test "invalid plans are rejected before SVG output is returned" do
    for input <- [
          nil,
          %{},
          plan(cells: {}),
          plan(cursor: %Cursor{x: 3, y: 0}),
          plan(palette: {%{foreground: "url(evil)", background: nil, modifiers: []}})
        ] do
      assert SVG.encode(input) == {:error, :invalid_plan}
    end
  end

  test "XML-forbidden noncharacters in emitted opaque IDs never produce malformed XML" do
    for codepoint <- [0xFFFE, 0xFFFF] do
      id = <<codepoint::utf8>>
      input = plan(actions: %{id => [%Rect{x: 2, y: 0, width: 1, height: 1}]})
      assert Plan.validate(input) == :ok
      assert SVG.encode(input) == {:error, :invalid_plan}
    end
  end
end
