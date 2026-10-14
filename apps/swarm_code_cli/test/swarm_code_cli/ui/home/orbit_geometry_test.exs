defmodule SwarmCodeCLI.UI.Home.OrbitGeometryTest do
  @moduledoc """
  orbit U4: the size classes, the orbit columns, the arcs, the beads and the age
  scale. The 120x36, 160x44 and 110x32 arcs and beads were checked cell for cell
  against the designer's `gen_D.py` when this was written.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Home.{Grid, Mark, Orbits}

  defp orbits(columns, rows, cols \\ nil) do
    grid = Grid.for(columns, rows)
    cols = cols || Grid.orbit_columns(grid, 4)
    {grid, Orbits.new(grid.mark, grid.mark_origin, cols)}
  end

  describe "Grid.for/2" do
    test "the classes at the sizes the frames show" do
      assert Grid.for(160, 44).class == :orbit_l
      assert Grid.for(120, 36).class == :orbit_m
      assert Grid.for(110, 32).class == :orbit_s
      assert Grid.for(80, 24).class == :compact
      assert Grid.for(60, 16).class == :minimal
      assert Grid.for(120, 28).class == :compact
    end

    test "the edges of every class" do
      assert Grid.class(150, 40) == :orbit_l
      assert Grid.class(149, 40) == :orbit_m
      assert Grid.class(150, 39) == :orbit_m
      assert Grid.class(120, 34) == :orbit_m
      assert Grid.class(119, 34) == :orbit_s
      assert Grid.class(120, 33) == :orbit_s
      assert Grid.class(100, 30) == :orbit_s
      assert Grid.class(99, 30) == :compact
      assert Grid.class(100, 29) == :compact
      assert Grid.class(72, 20) == :compact
      assert Grid.class(71, 20) == :minimal
      assert Grid.class(72, 19) == :minimal
      assert Grid.class(50, 14) == :minimal
      assert Grid.class(49, 14) == :too_small
      assert Grid.class(50, 13) == :too_small
    end

    test "too_small is the layout's own too_small size" do
      for {columns, rows} <- [{49, 14}, {50, 13}, {80, 13}, {40, 40}] do
        size = %SwarmCodeCLI.UI.Size{columns: columns, rows: rows}
        assert SwarmCodeCLI.UI.Layout.classify(size) == :too_small
        assert Grid.class(columns, rows) == :too_small
      end

      for {columns, rows} <- [{50, 14}, {72, 20}, {300, 80}] do
        size = %SwarmCodeCLI.UI.Size{columns: columns, rows: rows}
        refute SwarmCodeCLI.UI.Layout.classify(size) == :too_small
        refute Grid.class(columns, rows) == :too_small
      end
    end

    test "the ASCII tier draws no braille, so every orbit class is compact" do
      for {columns, rows} <- [{160, 44}, {120, 36}, {110, 32}] do
        assert Grid.class(columns, rows, :ascii) == :compact
        assert Grid.class(columns, rows, :measured) == Grid.class(columns, rows, :rich)
      end

      assert Grid.class(60, 16, :ascii) == :minimal
      assert Grid.for(120, 36, :ascii).mark == nil
    end

    test "the marks and the preview per class" do
      assert %{mark: {40, 20}, mark_origin: {2, 4}, preview?: true, wide_extras?: true} =
               Grid.for(160, 44)

      assert %{mark: {32, 16}, mark_origin: {2, 4}, preview?: true, wide_extras?: false} =
               Grid.for(120, 36)

      assert %{mark: {24, 12}, mark_origin: {2, 4}, preview?: false, wide_extras?: false} =
               Grid.for(110, 32)

      assert %{mark: nil, mark_origin: {2, 2}, preview?: false} = Grid.for(80, 24)
      assert %{mark: nil, preview?: false} = Grid.for(60, 16)
    end

    test "rows follow the frames: counts under the mark, legend, header, list, composer, hint, status" do
      assert %{r_top: 2, r_bot: 17, count_row: 18, legend_row: 19, header_row: 23, list_first: 24} =
               Grid.for(120, 36)

      assert %{composer_row: 33, hint_row: 34, status_row: 35, list_rows: 9} = Grid.for(120, 36)

      assert %{r_bot: 21, count_row: 22, legend_row: 23, header_row: 27, list_first: 28} =
               Grid.for(160, 44)

      assert %{composer_row: 41, hint_row: 42, status_row: 43, list_rows: 9} = Grid.for(160, 44)
      assert %{r_bot: 13, list_first: 20, list_rows: 9} = Grid.for(110, 32)
    end

    test "the list shrinks with the terminal and keeps at least three rows" do
      assert Grid.for(120, 34).list_rows == 7
      assert Grid.for(120, 60).list_rows == 9
      assert Grid.for(160, 40).list_rows == 5
      assert Grid.for(100, 30).list_rows == 7
      assert Grid.for(80, 20).list_rows == 9
      assert Grid.for(60, 14).list_rows == 5

      for rows <- 14..80, columns <- [50, 72, 100, 120, 150] do
        grid = Grid.for(columns, rows)

        if grid.class != :too_small do
          assert grid.list_rows in 1..9
          assert grid.composer_row > grid.list_first
        end
      end
    end

    test "compact: line orbits come off first, then list rows" do
      assert %{orbit_slots: 4, r_top: 5, r_bot: 8, header_row: 10, list_first: 11, list_rows: 9} =
               Grid.for(80, 24)

      assert %{orbit_slots: 2, header_row: 8, list_first: 9} = Grid.for(80, 22)
      assert %{orbit_slots: 0, header_row: 5, list_first: 6} = Grid.for(80, 20)
      assert %{orbit_slots: 2} = Grid.for(80, 24, :rich, 2)
      assert %{orbit_slots: 4} = Grid.for(80, 40, :rich, 6)
    end
  end

  describe "orbit columns" do
    test "four projects at 120 and 160 columns" do
      assert Grid.orbit_columns(Grid.for(120, 36), 4) == [52, 68, 84, 100]
      assert Grid.orbit_columns(Grid.for(160, 44), 4) == [64, 86, 108, 130]
    end

    test "the last column follows the width" do
      assert Grid.orbit_columns(Grid.for(130, 36), 4) == [52, 71, 91, 110]
      assert Grid.orbit_columns(Grid.for(200, 44), 4) |> List.last() == 170
      assert Grid.orbit_columns(Grid.for(150, 40), 4) |> List.last() == 120
      assert Grid.orbit_columns(Grid.for(110, 32), 3) == [44, 67, 90]
    end

    test "fewer projects use the first slots, more are capped at the class's" do
      assert Grid.orbit_columns(Grid.for(120, 36), 2) == [52, 68]
      assert Grid.orbit_columns(Grid.for(120, 36), 6) == [52, 68, 84, 100]
      assert Grid.orbit_columns(Grid.for(160, 44), 6) == [64, 77, 90, 104, 117, 130]
      assert Grid.orbit_columns(Grid.for(160, 44), 5) == [64, 81, 97, 114, 130]
      assert Grid.orbit_columns(Grid.for(110, 32), 8) |> length() == 3
      assert Grid.orbit_columns(Grid.for(80, 24), 4) == []
    end
  end

  describe "the age scale" do
    test "row_for at 120x36" do
      {_grid, o} = orbits(120, 36)
      assert Orbits.row_for(o, 0) == 2
      assert Orbits.row_for(o, 60) == 8
      assert Orbits.row_for(o, 1_440) == 12
      assert Orbits.row_for(o, 10_080) == 15
      assert Orbits.row_for(o, 43_200) == 17
      assert Orbits.row_for(o, 1_000_000) == 17
      assert Orbits.row_for(o, -5) == 2
    end

    test "the tick labels land on rows 2, 8, 12, 15, 17 at 120x36" do
      {_grid, o} = orbits(120, 36)
      assert Orbits.ticks(o) == [{2, "now"}, {8, "1 h"}, {12, "1 d"}, {15, "7 d"}, {17, "30 d"}]
    end

    test "the ticks of the other two classes" do
      {_grid, o} = orbits(160, 44)
      assert Orbits.ticks(o) == [{2, "now"}, {9, "1 h"}, {15, "1 d"}, {18, "7 d"}, {21, "30 d"}]
      {_grid, o} = orbits(110, 32)
      assert Orbits.ticks(o) == [{2, "now"}, {6, "1 h"}, {9, "1 d"}, {12, "7 d"}, {13, "30 d"}]
    end

    test "frac_age runs from 0 to 1 and never beyond" do
      assert Orbits.frac_age(0) == 0.0
      assert Orbits.frac_age(43_200) == 1.0
      assert Orbits.frac_age(10_000_000) == 1.0
      assert Orbits.frac_age(-3) == 0.0
      assert Orbits.frac_age(60) < Orbits.frac_age(61)
    end
  end

  describe "arcs" do
    test "the centre is the mark's ring centre" do
      {_grid, o} = orbits(120, 36)
      {cx, cy, _radius} = Mark.centre({32, 16})
      assert_in_delta o.cxd, 8 + cx, 1.0e-9
      assert_in_delta o.cyd, 8 + cy, 1.0e-9
    end

    defp locked_cells(grid) do
      {row, col} = grid.mark_origin
      MapSet.new(Mark.cell_set(grid.mark), fn {r, c} -> {r + row, c + col} end)
    end

    test "an arc never writes a mark cell, in any class" do
      for {columns, rows} <- [{120, 36}, {160, 44}, {110, 32}] do
        {grid, o} = orbits(columns, rows)
        locked = locked_cells(grid)

        for k <- 0..(length(o.cols) - 1), step <- [1, 2] do
          assert Orbits.arc_cells(o, k, step) |> Map.keys() |> Enum.all?(&(&1 not in locked))
          assert Orbits.arc_cells(o, k, step, locked) == Orbits.arc_cells(o, k, step)
        end
      end
    end

    test "an orbit narrow enough to cross the mark is cut at the mark's cells" do
      {grid, o} = orbits(120, 36, [30])
      locked = locked_cells(grid)
      unlocked = Orbits.arc_cells(o, 0, 1)
      assert Enum.any?(Map.keys(unlocked), &(&1 in locked)), "the arc must cross the mark here"
      cut = Orbits.arc_cells(o, 0, 1, locked)
      assert Enum.all?(Map.keys(cut), &(&1 not in locked))
      assert map_size(cut) < map_size(unlocked)
    end

    test "an arc sets only braille bits, stays on the mark's rows and reaches its column" do
      {grid, o} = orbits(120, 36)

      for {k, col} <- Enum.with_index(o.cols) |> Enum.map(fn {c, k} -> {k, c} end) do
        arc = Orbits.arc_cells(o, k)

        assert Enum.all?(arc, fn {{r, _c}, bits} ->
                 r in grid.r_top..grid.r_bot and bits in 1..255
               end)

        {_row, widest} = arc |> Map.keys() |> Enum.max_by(&elem(&1, 1))
        assert widest in (col - 1)..(col + 1)
      end
    end

    test "step 2 is a dotted arc: fewer bits than step 1" do
      {_grid, o} = orbits(120, 36)

      count = fn arc ->
        arc |> Map.values() |> Enum.map(&(Integer.digits(&1, 2) |> Enum.sum())) |> Enum.sum()
      end

      assert count.(Orbits.arc_cells(o, 1, 2)) < count.(Orbits.arc_cells(o, 1, 1))
    end

    test "outer orbits lie to the right of inner ones on every row" do
      {grid, o} = orbits(120, 36)

      for row <- grid.r_top..grid.r_bot do
        cols = for k <- 0..3, do: Orbits.col_at(o, k, row)
        assert cols == Enum.sort(cols)
        assert Enum.uniq(cols) == cols
      end
    end
  end

  describe "beads" do
    test "two beads of equal age land on consecutive rows" do
      {_grid, o} = orbits(120, 36)
      assert [{r1, _}, {r2, _}, {r3, _}] = Orbits.bead_spots(o, 0, [90, 90, 90])
      assert [r2 - r1, r3 - r2] == [1, 1]
      assert r1 == Orbits.row_for(o, 90)
    end

    test "a pile at the bottom stops at the last row" do
      {_grid, o} = orbits(120, 36)
      spots = Orbits.bead_spots(o, 0, List.duplicate(43_200, 5))
      assert Enum.map(spots, &elem(&1, 0)) == [17, 17, 17, 17, 17]
    end

    test "the nine conversations of the designer's frame (swarm-code-cli at 120x36)" do
      {_grid, o} = orbits(120, 36)
      ages = [2, 6, 52, 180, 300, 1560, 2880, 5760, 8640]
      rows = Orbits.bead_spots(o, 0, ages) |> Enum.map(&elem(&1, 0))
      assert rows == [4, 5, 8, 9, 10, 12, 13, 14, 15]
    end

    test "a bead sits on its arc" do
      {_grid, o} = orbits(120, 36)

      for k <- 0..3, {row, col} <- Orbits.bead_spots(o, k, [5, 500, 9_000]) do
        x = Orbits.x_dot(o, k, row * 4 + 2.5)
        assert col == div(trunc(x), 2)
      end
    end

    test "glyph and role by state" do
      now = 1_792_000_000_000
      minute = 60_000

      assert Orbits.bead(%{waiting: 1, live: true, updated_at: now}, now, :rich) ==
               {"!", :warning, true}

      assert Orbits.bead(%{live: true, live_kind: :swarm, updated_at: now}, now, :rich) ==
               {"●", :run_swarm, true}

      assert Orbits.bead(%{live: true, live_kind: nil, updated_at: now}, now, :rich) ==
               {"●", :accent, true}

      assert Orbits.bead(%{unread: true, updated_at: now - 500 * minute}, now, :rich) ==
               {"●", :text_primary, false}

      assert Orbits.bead(%{updated_at: now - 1_440 * minute}, now, :rich) ==
               {"●", :text_muted, false}

      assert Orbits.bead(%{updated_at: now - 1_441 * minute}, now, :rich) ==
               {"○", :text_faint, false}
    end

    test "the glyphs follow the tier" do
      now = 1_792_000_000_000
      old = %{updated_at: now - 100_000 * 60_000}
      fresh = %{updated_at: now}
      assert Orbits.bead(fresh, now, :measured) == {"⦁", :text_muted, false}
      assert Orbits.bead(old, now, :measured) == {"⚬", :text_faint, false}
      assert Orbits.bead(fresh, now, :ascii) == {"*", :text_muted, false}
      assert Orbits.bead(old, now, :ascii) == {"o", :text_faint, false}
      assert Orbits.bead(%{waiting: 2}, now, :ascii) == {"!", :warning, true}
    end

    test "a conversation without a usable age is old" do
      assert Orbits.age_minutes(%{}, 5) == 43_200
      assert Orbits.age_minutes(%{updated_at: 100}, 50) == 0
      assert Orbits.age_minutes(%{updated_at: 0}, 600_000) == 10
    end
  end

  describe "line orbits (compact)" do
    test "bead x for ages 0, 60, 1440 and 10080 at 80 columns lands on the tick positions" do
      {t0, t1} = Grid.line_range(80)
      assert {t0, t1} == {18, 75}
      ticks = Orbits.line_ticks(t0, t1)

      for {age, label} <- [{0, "now"}, {60, "1 h"}, {1_440, "1 d"}, {10_080, "7 d"}] do
        assert {Orbits.line_x(t0, t1, age), label} in ticks
      end

      assert Orbits.line_x(t0, t1, 0) == 18
      assert Orbits.line_x(t0, t1, 43_200) == 75
      assert Orbits.line_x(t0, t1, 99_999) == 75
    end

    test "30 d ends at the rule's last column" do
      {t0, t1} = Grid.line_range(80)
      assert List.last(Orbits.line_ticks(t0, t1)) == {72, "30 d"}
      {start, text} = List.last(Orbits.line_ticks(t0, t1))
      assert start + String.length(text) - 1 == t1
    end

    test "the designer's compact frame" do
      {t0, t1} = Grid.line_range(80)
      assert Enum.map([0, 60, 1_440, 10_080], &Orbits.line_x(t0, t1, &1)) == [18, 40, 57, 67]
    end
  end
end
