defmodule SwarmCodeCLI.UI.Settings.C75GridTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Settings.Grid

  test "160 × 45: rail, page and note (R20.1)" do
    grid = Grid.for(160, 45)

    assert grid.class == :wide
    assert grid.margin == 2
    assert grid.rail == %{left: 2, width: 24}
    assert grid.page == %{left: 30, width: 82}
    assert grid.note == %{spine: 116, left: 118, width: 40}
    assert grid.body_top == 3
    assert grid.body_rows == 38
    assert grid.message_row == 42
    assert grid.status_row == 44
    assert grid.strip_row == nil
    assert grid.label_width == 29
    assert grid.value_offset == 33
    assert grid.drawer_lines == 0
    assert grid.well_width == 80
    assert Grid.tag_right(grid) == 111
    assert Grid.mark_col(grid) == 31
    assert Grid.label_col(grid) == 33
    assert Grid.value_col(grid) == 63
    assert Grid.page_height(grid) == 38
  end

  test "140 × 40: rail and a flexible page, a 3-line drawer (R20.3)" do
    grid = Grid.for(140, 40)

    assert grid.class == :rail
    assert grid.page == %{left: 30, width: 108}
    assert grid.note == nil
    assert grid.drawer_lines == 3
    assert grid.rail == %{left: 2, width: 24}
  end

  test "90 × 30: the section strip, no rail (R20.4)" do
    grid = Grid.for(90, 30)

    assert grid.class == :strip
    assert grid.rail == nil
    assert grid.strip_row == 2
    assert grid.body_top == 4
    assert grid.body_rows == 22
    assert grid.page == %{left: 2, width: 86}
    assert grid.well_width == 40
    assert Grid.page_height(grid) == 22
  end

  test "80 × 24: the small page (R20.5)" do
    grid = Grid.for(80, 24)

    assert grid.class == :small
    assert grid.body_top == 2
    assert grid.body_rows == 18
    assert grid.page == %{left: 1, width: 78}
    assert grid.label_width == 19
    assert grid.value_offset == 23
    assert grid.drawer_lines == 2
    assert grid.well_width == 34
    assert grid.message_row == 21
    assert grid.status_row == 23
  end

  test "below 80 × 20 the grid is too small; the page step is never under 3 (R20.8, R20.9)" do
    assert Grid.for(79, 24).class == :too_small
    assert Grid.for(100, 19).class == :too_small
    assert %Grid{columns: 79, rows: 24, page: nil} = Grid.for(79, 24)

    assert Grid.page_height(Grid.for(79, 24)) == 3
    assert Grid.page_height(Grid.for(80, 20)) == 14
  end

  test "class/1 thresholds" do
    assert Grid.class(160) == :wide
    assert Grid.class(159) == :rail
    assert Grid.class(120) == :rail
    assert Grid.class(119) == :strip
    assert Grid.class(90) == :strip
    assert Grid.class(89) == :small
    assert Grid.class(80) == :small
    assert Grid.class(79) == :too_small
  end
end
