defmodule SwarmCodeCLI.UI.Paint.RichBlocksTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{SafeText, Scene, Size}
  alias SwarmCodeCLI.UI.Paint.{Blocks, Budget, Options}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.{Block, Rect, Region}

  defp safe(text), do: elem(SafeText.external(text, Limits.content()), 1)

  @base %{foreground: {:rgb, 243, 242, 240}, background: {:rgb, 20, 20, 20}, modifiers: []}

  defp paint(blocks, width, tier, rows \\ 10, ascii? \\ false) do
    options = %Options{color_mode: :truecolor, glyph_tier: tier, ascii?: ascii?}
    Blocks.lines(blocks, width, options, @base, rows, :narrow)
  end

  defp lines(blocks, width, tier, rows \\ 10, ascii? \\ false) do
    {:ok, lines} = paint(blocks, width, tier, rows, ascii?)

    Enum.map(lines, fn line ->
      Enum.map(line.units, &{&1.text, &1.style.foreground, &1.style.background})
    end)
  end

  defp text(line), do: line |> Enum.map(&elem(&1, 0)) |> Enum.join()
  defp t(token), do: SafeText.value(SafeText.chrome(token))

  defp scene(blocks) do
    %Scene{
      size: %Size{columns: 80, rows: 24},
      regions: [
        %Region{
          id: "main",
          role: :main,
          rect: %Rect{x: 0, y: 0, width: 80, height: 24},
          label: SafeText.chrome(:empty),
          blocks: blocks
        }
      ]
    }
  end

  describe "Surface edges: :half" do
    test "rich paints half-block top and bottom rows in the surface colour over the outside" do
      [top, body, bottom] =
        lines(
          [%Block.Surface{blocks: [%Block.Text{text: safe("hi")}], tone: :card, edges: :half}],
          6,
          :rich
        )

      assert text(top) == t(:corner_tl) <> String.duplicate(t(:half_lower), 4) <> t(:corner_tr)

      assert text(bottom) ==
               t(:corner_bl) <> String.duplicate(t(:half_upper), 4) <> t(:corner_br)

      {_, fg, bg} = Enum.at(top, 1)
      assert fg == {:rgb, 30, 30, 30} and bg == {:rgb, 20, 20, 20}
      {_, corner_fg, corner_bg} = List.first(bottom)
      assert corner_fg == {:rgb, 30, 30, 30} and corner_bg == {:rgb, 20, 20, 20}
      assert String.starts_with?(text(body), " hi")
      assert Enum.all?(body, fn {_, _, bg} -> bg == {:rgb, 30, 30, 30} end)
    end

    test "measured falls back to the quadrant corners" do
      [top | _] = lines([%Block.Surface{blocks: [], tone: :card, edges: :half}], 6, :measured)
      assert text(top) == t(:corner_tl) <> "    " <> t(:corner_tr)
    end

    test "half edges reserve two rows exactly as rounded corners do" do
      blocks = [%Block.Text{text: safe("a")}, %Block.Text{text: safe("b")}]
      rows = lines([%Block.Surface{blocks: blocks, tone: :card, edges: :half}], 6, :rich, 3)
      assert length(rows) == 3
      assert text(Enum.at(rows, 1)) == " a    "

      assert text(Enum.at(rows, 2)) ==
               t(:corner_bl) <> String.duplicate(t(:half_upper), 4) <> t(:corner_br)
    end

    test "edges: :corners keeps today's rounded and square surfaces" do
      rounded = lines([%Block.Surface{blocks: [], tone: :card, rounded: true}], 6, :rich)

      assert Enum.map(rounded, &text/1) == [
               t(:corner_tl) <> "    " <> t(:corner_tr),
               t(:corner_bl) <> "    " <> t(:corner_br)
             ]

      square =
        lines([%Block.Surface{blocks: [%Block.Text{text: safe("x")}], tone: :card}], 6, :rich)

      assert Enum.map(square, &text/1) == [" x    "]
    end
  end

  describe "Gauge :smooth" do
    test "rich fills whole cells with the full block and the boundary cell with an eighth" do
      [line] =
        lines([%Block.Gauge{tone: :accent, value: 30, maximum: 100, style: :smooth}], 10, :rich)

      # 30% of 10 cells = 3.0 cells: three full blocks, then track.
      assert text(line) == String.duplicate(t(:block_full), 3) <> String.duplicate(" ", 7)

      [line] =
        lines([%Block.Gauge{tone: :accent, value: 35, maximum: 100, style: :smooth}], 10, :rich)

      # 3.5 cells: three full, then the left-half block (eighth_4).
      assert text(line) ==
               String.duplicate(t(:block_full), 3) <> t(:eighth_4) <> String.duplicate(" ", 6)
    end

    test "the unfilled cells are spaces on the track colour and the boundary cell sits on it" do
      [line] =
        lines([%Block.Gauge{tone: :accent, value: 35, maximum: 100, style: :smooth}], 10, :rich)

      {_, fg, bg} = Enum.at(line, 0)
      assert fg == {:rgb, 255, 106, 26} and bg == {:rgb, 20, 20, 20}
      {_, fg, bg} = Enum.at(line, 3)
      assert fg == {:rgb, 255, 106, 26} and bg == {:rgb, 60, 60, 59}
      {_, _, bg} = List.last(line)
      assert bg == {:rgb, 60, 60, 59}
    end

    test "a gradient mixes the first and last lit cell between the two roles" do
      [line] =
        lines(
          [
            %Block.Gauge{
              tone: :agent_lane_1,
              value: 100,
              maximum: 100,
              style: :smooth,
              gradient_to: :accent
            }
          ],
          10,
          :rich
        )

      {_, first, _} = List.first(line)
      {_, last, _} = List.last(line)
      assert first == {:rgb, 45, 212, 191}
      assert last == {:rgb, 255, 106, 26}
      {_, middle, _} = Enum.at(line, 5)
      assert middle != first and middle != last
    end

    test "a zero maximum paints the smooth track" do
      [line] =
        lines([%Block.Gauge{tone: :accent, value: 0, maximum: 0, style: :smooth}], 5, :rich)

      assert text(line) == "     "
      assert Enum.all?(line, fn {_, _, bg} -> bg == {:rgb, 60, 60, 59} end)
    end

    test "measured paints :smooth as ticks and ignores the gradient" do
      [line] =
        lines(
          [%Block.Gauge{tone: :accent, value: 30, maximum: 100, style: :smooth}],
          10,
          :measured
        )

      assert text(line) == String.duplicate(t(:stripe), 3) <> String.duplicate(t(:stripe_off), 7)

      [line] =
        lines(
          [
            %Block.Gauge{
              tone: :agent_lane_1,
              value: 100,
              maximum: 100,
              style: :smooth,
              gradient_to: :accent
            }
          ],
          10,
          :measured
        )

      assert Enum.all?(line, fn {_, fg, _} -> fg == {:rgb, 45, 212, 191} end)
    end

    test "ascii paints :smooth as ascii ticks even when the tier says rich" do
      [line] =
        lines(
          [%Block.Gauge{tone: :accent, value: 30, maximum: 100, style: :smooth}],
          10,
          :rich,
          10,
          true
        )

      assert text(line) == "###-------"
    end
  end

  describe "Chart :sparkline" do
    test "rich draws one vertical eighth per value, normalised to the peak" do
      [line] =
        lines([%Block.Chart{series: [0, 4, 8], tone: :accent, style: :sparkline}], 3, :rich)

      assert text(line) == " " <> t(:vert_4) <> t(:block_full)
      assert Enum.all?(line, fn {_, fg, _} -> fg == {:rgb, 255, 106, 26} end)
    end

    test "a flat series is all spaces, a label follows on its own row, width clips the series" do
      [line] =
        lines([%Block.Chart{series: [0, 0, 0], tone: :accent, style: :sparkline}], 3, :rich)

      assert text(line) == "   "

      [line, label] =
        lines(
          [%Block.Chart{series: [1, 8], tone: :accent, style: :sparkline, label: safe("cpu")}],
          4,
          :rich
        )

      assert text(line) == t(:vert_1) <> t(:block_full)
      assert text(label) == "cpu"

      [line] =
        lines([%Block.Chart{series: [8, 8, 8, 8], tone: :accent, style: :sparkline}], 2, :rich)

      assert text(line) == String.duplicate(t(:block_full), 2)
    end

    test "measured falls back to braille" do
      [line] =
        lines([%Block.Chart{series: [0, 4, 8], tone: :accent, style: :sparkline}], 3, :measured)

      assert String.match?(text(line), ~r/^[\x{2800}-\x{28FF}]+$/u)
    end
  end

  describe "Columns" do
    test "zips two columns side by side, padding the shorter one" do
      left = [%Block.Text{text: safe("a")}, %Block.Text{text: safe("b")}]
      right = [%Block.Text{text: safe("c")}]

      rows =
        lines(
          [
            %Block.Columns{
              columns: [%{width: 3, blocks: left}, %{width: 3, blocks: right}],
              gap: 1
            }
          ],
          7,
          :rich
        )

      assert Enum.map(rows, &text/1) == ["a   c  ", "b      "]
    end

    test "a gap of zero butts the columns together and the padding wears the inherited style" do
      left = [%Block.Text{text: safe("a")}]
      right = [%Block.Text{text: safe("b")}, %Block.Text{text: safe("c")}]

      rows =
        lines(
          [
            %Block.Columns{
              columns: [%{width: 2, blocks: left}, %{width: 2, blocks: right}],
              gap: 0
            }
          ],
          4,
          :measured
        )

      assert Enum.map(rows, &text/1) == ["a b ", "  c "]
      assert Enum.all?(List.flatten(rows), fn {_, _, bg} -> bg == {:rgb, 20, 20, 20} end)
    end

    test "each column lays its blocks out at its own width" do
      left = [
        %Block.Surface{blocks: [%Block.Text{text: safe("hi")}], tone: :card, edges: :half}
      ]

      right = [%Block.Text{text: safe("wide words wrap")}]

      rows =
        lines(
          [
            %Block.Columns{
              columns: [%{width: 4, blocks: left}, %{width: 5, blocks: right}],
              gap: 1
            }
          ],
          10,
          :rich
        )

      # The right column wraps at five cells: "wide ", "words", " wrap" (the
      # wrapper keeps the leading space), each row then joined by the one-cell gap.
      assert Enum.map(rows, &text/1) == [
               t(:corner_tl) <> t(:half_lower) <> t(:half_lower) <> t(:corner_tr) <> " wide ",
               " hi  " <> "words",
               t(:corner_bl) <> t(:half_upper) <> t(:half_upper) <> t(:corner_br) <> "  wrap"
             ]
    end

    test "empty columns paint nothing and the row budget still applies" do
      empty = %Block.Columns{columns: [%{width: 3, blocks: []}, %{width: 3, blocks: []}]}
      assert lines([empty], 7, :rich) == []

      left = [
        %Block.Text{text: safe("a")},
        %Block.Text{text: safe("b")},
        %Block.Text{text: safe("c")}
      ]

      rows = lines([%Block.Columns{columns: [%{width: 3, blocks: left}]}], 3, :rich, 2)
      assert Enum.map(rows, &text/1) == ["a  ", "b  "]
    end

    test "columns wider than the region are rejected, as are malformed columns" do
      too_wide = %Block.Columns{
        columns: [%{width: 4, blocks: []}, %{width: 4, blocks: []}],
        gap: 1
      }

      assert paint([too_wide], 8, :rich) == {:error, :invalid_scene}

      assert paint([%Block.Columns{columns: [%{width: 0, blocks: []}]}], 8, :rich) ==
               {:error, :invalid_scene}

      assert paint([%Block.Columns{columns: []}], 8, :rich) == {:error, :invalid_scene}

      assert paint([%Block.Columns{columns: [%{width: 2, blocks: []}], gap: -1}], 8, :rich) ==
               {:error, :invalid_scene}

      assert paint([%Block.Columns{columns: [%{width: 2, blocks: [], extra: 1}]}], 8, :rich) ==
               {:error, :invalid_scene}
    end
  end

  describe "scene admission" do
    test "the new blocks and fields pass the budget and the scene contract" do
      blocks = [
        %Block.Surface{blocks: [%Block.Text{text: safe("hi")}], tone: :card, edges: :half},
        %Block.Gauge{
          tone: :agent_lane_1,
          value: 3,
          maximum: 9,
          style: :smooth,
          gradient_to: :accent
        },
        %Block.Chart{series: [1, 2, 3], tone: :accent, style: :sparkline},
        %Block.Columns{
          columns: [
            %{
              width: 10,
              blocks: [%Block.Gauge{tone: :accent, value: 1, maximum: 2, style: :smooth}]
            },
            %{width: 10, blocks: [%Block.Text{text: safe("x")}]}
          ],
          gap: 2
        }
      ]

      assert :ok = Budget.validate_scene(scene(blocks))
    end

    test "unknown edges, styles, gradient roles and malformed columns are rejected" do
      assert {:error, :invalid_scene} =
               Budget.validate_scene(
                 scene([%Block.Surface{blocks: [], tone: :card, edges: :dotted}])
               )

      assert {:error, :invalid_scene} =
               Budget.validate_scene(scene([%Block.Gauge{tone: :accent, style: :wavy}]))

      assert {:error, :invalid_scene} =
               Budget.validate_scene(
                 scene([%Block.Gauge{tone: :accent, style: :smooth, gradient_to: :nope}])
               )

      assert {:error, :invalid_scene} =
               Budget.validate_scene(
                 scene([%Block.Chart{series: [1], tone: :accent, style: :pie}])
               )

      assert {:error, :invalid_scene} =
               Budget.validate_scene(scene([%Block.Columns{columns: [%{width: 0, blocks: []}]}]))

      assert {:error, :invalid_scene} =
               Budget.validate_scene(
                 scene([%Block.Columns{columns: [%{width: 2, blocks: [], extra: 1}]}])
               )

      assert {:error, :invalid_scene} =
               Budget.validate_scene(
                 scene([%Block.Columns{columns: [%{width: 2, blocks: [:not_a_block]}]}])
               )
    end
  end
end
