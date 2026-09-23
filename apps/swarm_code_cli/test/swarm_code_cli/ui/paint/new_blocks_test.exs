defmodule SwarmCodeCLI.UI.Paint.NewBlocksTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{SafeText, Scene}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias Scene.Block
  @base %{foreground: nil, background: nil, modifiers: []}
  defp safe(text), do: elem(SafeText.external(text, Limits.content()), 1)
  defp text(value), do: %Block.Text{text: safe(value)}

  defp layout(blocks, width, rows \\ 100, options \\ %Options{}) do
    assert {:ok, lines} = Blocks.lines(blocks, width, options, @base, rows)
    lines
  end

  defp strings(lines), do: Enum.map(lines, &Enum.map_join(&1.units, fn unit -> unit.text end))

  # ────────────────── Gauge: ticks ──────────────────

  describe "Gauge :ticks" do
    test "50% over 20 cells lights exactly 10 cells" do
      gauge = %Block.Gauge{tone: :accent, value: 5, maximum: 10, style: :ticks}
      lines = layout([gauge], 20)
      texts = strings(lines)

      assert length(texts) == 1
      joined = hd(texts)
      assert String.length(joined) == 20

      [line] = lines
      lit_count = Enum.count(line.units, fn u -> u.text == "▐" end)
      assert lit_count == 20

      all_styles = Enum.map(line.units, & &1.style)
      lit_styles = Enum.take(all_styles, 10)
      unlit_styles = Enum.drop(all_styles, 10)

      assert length(lit_styles) == 10
      assert length(unlit_styles) == 10

      first_lit = hd(lit_styles)
      first_unlit = hd(unlit_styles)
      assert first_lit != first_unlit

      assert Enum.all?(lit_styles, &(&1 == first_lit))
      assert Enum.all?(unlit_styles, &(&1 == first_unlit))
    end

    test "maximum == 0 renders track and does not crash" do
      gauge = %Block.Gauge{tone: :accent, value: 0, maximum: 0, style: :ticks}
      lines = layout([gauge], 10)
      assert length(lines) == 1

      [line] = lines
      assert Enum.all?(line.units, fn u -> u.text == "▐" end)
    end

    test "never emits more cells than ctx.width" do
      for width <- [1, 5, 20, 40, 80] do
        gauge = %Block.Gauge{tone: :accent, value: 3, maximum: 7, style: :ticks}
        [line] = layout([gauge], width)
        assert line.cells <= width, "gauge at width #{width} emitted #{line.cells} cells"
      end
    end

    test "100% fills all cells" do
      gauge = %Block.Gauge{tone: :accent, value: 10, maximum: 10, style: :ticks}
      [line] = layout([gauge], 20)

      all_styles = Enum.map(line.units, & &1.style)
      first = hd(all_styles)
      assert Enum.all?(all_styles, &(&1 == first))
    end

    test "0% fills no cells (all track)" do
      gauge = %Block.Gauge{tone: :accent, value: 0, maximum: 10, style: :ticks}
      [line] = layout([gauge], 20)

      all_styles = Enum.map(line.units, & &1.style)
      first = hd(all_styles)
      assert Enum.all?(all_styles, &(&1 == first))
    end
  end

  # ────────────────── Gauge: segments ──────────────────

  describe "Gauge :segments" do
    test "uses seg_on and seg_off glyphs" do
      gauge = %Block.Gauge{tone: :accent, value: 5, maximum: 10, style: :segments}
      [line] = layout([gauge], 20)

      texts = Enum.map(line.units, & &1.text)
      lit_texts = Enum.take(texts, 10)
      unlit_texts = Enum.drop(texts, 10)

      assert Enum.all?(lit_texts, &(&1 == "▰"))
      assert Enum.all?(unlit_texts, &(&1 == "▱"))
    end
  end

  # ────────────────── Gauge: bar ──────────────────

  describe "Gauge :bar" do
    test "uses stripe glyph for both lit and unlit" do
      gauge = %Block.Gauge{tone: :accent, value: 5, maximum: 10, style: :bar}
      [line] = layout([gauge], 20)

      texts = Enum.map(line.units, & &1.text)
      assert Enum.all?(texts, &(&1 == "▐"))
    end
  end

  # ────────────────── Gauge: ASCII ──────────────────

  describe "Gauge ASCII" do
    test "ticks gauge in ASCII uses # for lit and - for unlit" do
      gauge = %Block.Gauge{tone: :accent, value: 5, maximum: 10, style: :ticks}
      lines = layout([gauge], 20, 100, %Options{ascii?: true})
      [text] = strings(lines)

      assert text == String.duplicate("#", 10) <> String.duplicate("-", 10)
    end

    test "segments gauge in ASCII uses # and -" do
      gauge = %Block.Gauge{tone: :accent, value: 5, maximum: 10, style: :segments}
      lines = layout([gauge], 20, 100, %Options{ascii?: true})
      [text] = strings(lines)

      assert String.length(text) == 20
      assert text == String.duplicate("#", 10) <> String.duplicate("-", 10)
    end
  end

  # ────────────────── Chart: braille ──────────────────

  describe "Chart braille" do
    test "plots known series to exact braille codepoints" do
      # Series [4, 4] at height 1:
      # max_val = 4, total_rows = 4
      # Both columns are fully lit (4 dots each)
      # col 0 bits: 0x01 | 0x02 | 0x04 | 0x40 = 0x47
      # col 1 bits: 0x08 | 0x10 | 0x20 | 0x80 = 0xB8
      # combined: 0x47 | 0xB8 = 0xFF
      # codepoint: 0x2800 + 0xFF = 0x28FF = ⣿
      chart = %Block.Chart{series: [4, 4], tone: :accent, height: 1}
      lines = layout([chart], 80)
      [text] = strings(lines)
      assert text == <<0x28FF::utf8>>

      # Series [4, 0] at height 1:
      # left fully lit, right empty
      # bits = 0x47
      # codepoint: 0x2800 + 0x47 = 0x2847 = ⡇
      chart2 = %Block.Chart{series: [4, 0], tone: :accent, height: 1}
      lines2 = layout([chart2], 80)
      [text2] = strings(lines2)
      assert text2 == <<0x2847::utf8>>

      # Series [0, 4] at height 1:
      # left empty, right fully lit
      # bits = 0xB8
      # codepoint: 0x2800 + 0xB8 = 0x28B8
      chart3 = %Block.Chart{series: [0, 4], tone: :accent, height: 1}
      lines3 = layout([chart3], 80)
      [text3] = strings(lines3)
      assert text3 == <<0x28B8::utf8>>

      # Series [2, 2] at height 1:
      # max_val = 2, total_rows = 4
      # left_dots = div(2*4, 2) = 4... wait, that means full. Let me recalculate.
      # Actually, div(2*4, 2) = 4, so all 4 rows lit for both sides.
      # That gives 0xFF = ⣿ again.
      # Let me use [1, 2] instead:
      # left_dots = div(1*4, 2) = 2
      # right_dots = div(2*4, 2) = 4
      # row 0: abs_row=0
      #   dot 0: screen_row=3, left 3<2=F, right 3<4=T → 0x08
      #   dot 1: screen_row=2, left 2<2=F, right 2<4=T → 0x10
      #   dot 2: screen_row=1, left 1<2=T → 0x04, right 1<4=T → 0x20
      #   dot 3: screen_row=0, left 0<2=T → 0x40, right 0<4=T → 0x80
      #   bits = 0x08 | 0x10 | 0x04 | 0x20 | 0x40 | 0x80 = 0xFC
      #   codepoint: 0x2800 + 0xFC = 0x28FC
      chart4 = %Block.Chart{series: [1, 2], tone: :accent, height: 1}
      lines4 = layout([chart4], 80)
      [text4] = strings(lines4)
      assert text4 == <<0x28FC::utf8>>
    end

    test "empty series does not crash" do
      chart = %Block.Chart{series: [], tone: :accent, height: 1}
      lines = layout([chart], 80)
      assert length(lines) >= 1
    end

    test "all-zero series does not crash" do
      chart = %Block.Chart{series: [0, 0, 0, 0], tone: :accent, height: 1}
      lines = layout([chart], 80)
      assert length(lines) >= 1

      [text] = strings(lines)

      for <<cp::utf8 <- text>> do
        assert cp == 0x2800
      end
    end

    test "odd-length series is padded and does not crash" do
      chart = %Block.Chart{series: [3, 1, 2], tone: :accent, height: 1}
      lines = layout([chart], 80)
      assert length(lines) >= 1
    end
  end

  # ────────────────── Chart: ASCII ──────────────────

  describe "Chart ASCII" do
    test "emits no braille codepoint (U+2800..U+28FF)" do
      chart = %Block.Chart{series: [1, 2, 3, 4], tone: :accent, height: 2, label: safe("CPU")}
      lines = layout([chart], 80, 100, %Options{ascii?: true})

      all_text =
        Enum.map_join(lines, fn line ->
          Enum.map_join(line.units, & &1.text)
        end)

      for <<cp::utf8 <- all_text>> do
        refute cp in 0x2800..0x28FF,
               "Found braille codepoint U+#{Integer.to_string(cp, 16)} in ASCII chart"
      end
    end

    test "ASCII chart with empty series does not crash" do
      chart = %Block.Chart{series: [], tone: :accent, height: 1, label: safe("Empty")}
      lines = layout([chart], 80, 100, %Options{ascii?: true})
      assert length(lines) >= 1
    end
  end

  # ────────────────── Surface ──────────────────

  describe "Surface" do
    test "one-row rounded surface does not collide corners" do
      surface = %Block.Surface{
        blocks: [text("x")],
        tone: :card,
        rounded: true
      }

      lines = layout([surface], 20)
      texts = strings(lines)

      assert length(texts) >= 3

      top_text = Enum.at(texts, 0)
      bottom_text = List.last(texts)

      assert String.starts_with?(top_text, "▗")
      assert String.ends_with?(top_text, "▖")
      assert String.starts_with?(bottom_text, "▝")
      assert String.ends_with?(bottom_text, "▘")
    end

    test "zero-body rounded surface renders top and bottom corner rows" do
      surface = %Block.Surface{
        blocks: [],
        tone: :card,
        rounded: true
      }

      lines = layout([surface], 20)
      texts = strings(lines)

      assert length(texts) == 2
      [top, bottom] = texts
      assert String.starts_with?(top, "▗")
      assert String.ends_with?(top, "▖")
      assert String.starts_with?(bottom, "▝")
      assert String.ends_with?(bottom, "▘")
    end

    test "surface with accent renders the accent column" do
      surface = %Block.Surface{
        blocks: [text("hello")],
        tone: :card,
        accent: :accent,
        rounded: false
      }

      lines = layout([surface], 40)
      texts = strings(lines)

      assert length(texts) == 1
      [line_text] = texts
      # pass71 V1 (R3): a thin rail; at the measured tier a one-cell gap.
      assert String.starts_with?(line_text, "  hello")
    end

    test "the accent rail is thin: ▏ at the rich tier, ▐ only in monochrome, | in ASCII" do
      surface = %Block.Surface{blocks: [text("hello")], tone: :card, accent: :accent}

      for {options, rail} <- [
            {%Options{glyph_tier: :rich}, "▏"},
            {%Options{color_mode: :monochrome}, "▐"},
            {%Options{ascii?: true}, "|"}
          ] do
        [line] = layout([surface], 40, 100, options)
        assert hd(line.units).text == rail, inspect(options)
      end
    end

    test "surface with accent has different style on leftmost column" do
      surface = %Block.Surface{
        blocks: [text("hello")],
        tone: :card,
        accent: :accent,
        rounded: false
      }

      lines = layout([surface], 40)
      [line] = lines
      first_unit = hd(line.units)
      assert first_unit.text == " "
    end

    test "non-rounded surface without accent indents by one space" do
      surface = %Block.Surface{
        blocks: [text("hi")],
        tone: :card,
        rounded: false
      }

      lines = layout([surface], 40)
      texts = strings(lines)
      [line_text] = texts
      assert String.starts_with?(line_text, " hi")
    end
  end
end
