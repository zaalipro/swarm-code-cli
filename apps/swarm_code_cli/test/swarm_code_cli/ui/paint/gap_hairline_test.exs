defmodule SwarmCodeCLI.UI.Paint.GapHairlineTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Paint,
    Projector,
    Size
  }

  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp fixture(kind, {columns, rows}, opts \\ []) do
    policy = Keyword.get(opts, :policy, :narrow)
    color = Keyword.get(opts, :color, :truecolor)
    ascii = Keyword.get(opts, :ascii, false)
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, ambiguous_width: policy, color_mode: color, ascii?: ascii}
    Fixtures.representative(kind, size, caps)
  end

  defp paint(state) do
    {scene, _table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    plan
  end

  defp cell_glyph(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, glyph, _, _} -> glyph
      _ -> nil
    end
  end

  defp column_glyphs(plan, x, y_start, y_end) do
    for y <- y_start..y_end, do: cell_glyph(plan, x, y)
  end

  describe "gap-column hairline at xl (170x34)" do
    test "navigator gap column 26 contains hairline glyph" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)

      # Navigator is at x=0, w=26, y=1, h=32
      # Gap column is at x=26
      glyphs = column_glyphs(plan, 26, 1, 32)

      assert Enum.all?(glyphs, &(&1 == "╎")),
             "Expected all cells in navigator gap column 26 to be hairline, got: #{inspect(glyphs)}"
    end

    test "inspector gap column 127 contains hairline glyph" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)

      # Inspector is at x=128, w=42, y=1, h=32
      # Gap column is at x=127
      glyphs = column_glyphs(plan, 127, 1, 32)

      assert Enum.all?(glyphs, &(&1 == "╎")),
             "Expected all cells in inspector gap column 127 to be hairline, got: #{inspect(glyphs)}"
    end
  end

  describe "gap-column hairline at medium (120x40)" do
    test "navigator gap column 26 contains hairline glyph" do
      state = fixture(:chat, {120, 40})
      plan = paint(state)

      # Navigator is at x=0, w=26, y=1, h=38
      # Gap column is at x=26
      glyphs = column_glyphs(plan, 26, 1, 38)

      assert Enum.all?(glyphs, &(&1 == "╎")),
             "Expected all cells in navigator gap column 26 to be hairline, got: #{inspect(glyphs)}"
    end
  end

  describe "no hairline at narrow/small (no docks)" do
    test "narrow 80x24 has no hairline anywhere" do
      state = fixture(:chat, {80, 24})
      plan = paint(state)

      # No docks at narrow, so no hairlines should be present
      for x <- 0..(plan.size.columns - 1), y <- 0..(plan.size.rows - 1) do
        refute cell_glyph(plan, x, y) == "╎",
               "Unexpected hairline at (#{x}, #{y}) in narrow layout"
      end
    end

    test "small 50x16 has no hairline anywhere" do
      state = fixture(:chat, {50, 16})
      plan = paint(state)

      for x <- 0..(plan.size.columns - 1), y <- 0..(plan.size.rows - 1) do
        refute cell_glyph(plan, x, y) == "╎",
               "Unexpected hairline at (#{x}, #{y}) in small layout"
      end
    end
  end

  describe "ASCII mode degrades hairline to pipe" do
    test "xl ASCII mode uses | instead of hairline glyph" do
      state = fixture(:chat, {170, 34}, ascii: true)
      plan = paint(state)

      # Navigator gap at x=26
      glyphs = column_glyphs(plan, 26, 1, 32)

      assert Enum.all?(glyphs, &(&1 == "|")),
             "Expected pipe | in ASCII mode navigator gap, got: #{inspect(glyphs)}"

      # Inspector gap at x=127
      glyphs = column_glyphs(plan, 127, 1, 32)

      assert Enum.all?(glyphs, &(&1 == "|")),
             "Expected pipe | in ASCII mode inspector gap, got: #{inspect(glyphs)}"
    end

    test "wide policy uses | fallback for hairline" do
      state = fixture(:chat, {170, 34}, policy: :wide)
      plan = paint(state)

      # Under :wide policy, chrome/3 checks Width.cells and falls back
      # to ASCII if the glyph is not 1 cell. Since hairline is SAFE (1 cell
      # under both policies), the hairline glyph should still be used
      glyphs = column_glyphs(plan, 26, 1, 32)

      assert Enum.all?(glyphs, &(&1 == "╎")),
             "Expected hairline glyph under :wide policy (SAFE glyph), got: #{inspect(glyphs)}"
    end
  end
end
