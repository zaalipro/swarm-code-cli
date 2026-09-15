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
    test "no navigator gap column 26: main runs flush from column 0" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)

      # The navigator dock is gone, so column 26 is main's own text, never the
      # hairline that used to separate the dock from main.
      glyphs = column_glyphs(plan, 26, 2, 32)

      refute Enum.any?(glyphs, &(&1 == "╎")),
             "Column 26 still carries a navigator gap hairline: #{inspect(glyphs)}"

      {scene, _} = SwarmCodeCLI.UI.Projector.project(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      assert main.rect.x == 0
    end

    test "inspector gap column 127 contains hairline glyph" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)

      # Inspector is at x=128, w=42, y=2, h=31 (row 1 is now the tab row)
      # Gap column is at x=127
      glyphs = column_glyphs(plan, 127, 2, 32)

      assert Enum.all?(glyphs, &(&1 == "╎")),
             "Expected all cells in inspector gap column 127 to be hairline, got: #{inspect(glyphs)}"
    end

    test "the tab row on row 1 is never split by a gap column" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)

      for x <- 0..169 do
        refute cell_glyph(plan, x, 1) == "╎",
               "A hairline crossed the tab row at column #{x}"
      end
    end
  end

  describe "gap-column hairline at medium (120x40)" do
    test "medium docks nothing on the left, so no hairline is drawn" do
      state = fixture(:chat, {120, 40})
      plan = paint(state)

      # `medium_dock` defaults to `:none` now that the navigator is gone, so a
      # stock medium terminal paints no dock and therefore no gap column at all.
      # Ctrl-B docks the inspector, and then there is one (see LayoutTest).
      for x <- 0..(plan.size.columns - 1), y <- 0..(plan.size.rows - 1) do
        refute cell_glyph(plan, x, y) == "╎",
               "Unexpected hairline at (#{x}, #{y}) in medium layout"
      end
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

      # Inspector gap at x=127, rows 2..32 (row 1 is the tab row)
      glyphs = column_glyphs(plan, 127, 2, 32)

      assert Enum.all?(glyphs, &(&1 == "|")),
             "Expected pipe | in ASCII mode inspector gap, got: #{inspect(glyphs)}"

      # The navigator gap is gone, so column 26 carries no separator at all.
      refute Enum.any?(column_glyphs(plan, 26, 2, 32), &(&1 == "|")),
             "A navigator gap survived into ASCII mode at column 26"
    end

    test "wide policy uses | fallback for hairline" do
      state = fixture(:chat, {170, 34}, policy: :wide)
      plan = paint(state)

      # Under :wide policy, chrome/3 checks Width.cells and falls back
      # to ASCII if the glyph is not 1 cell. Since hairline is SAFE (1 cell
      # under both policies), the hairline glyph should still be used. The only
      # dock left is the inspector, whose gap column is 127.
      glyphs = column_glyphs(plan, 127, 2, 32)

      assert Enum.all?(glyphs, &(&1 == "╎")),
             "Expected hairline glyph under :wide policy (SAFE glyph), got: #{inspect(glyphs)}"
    end
  end
end
