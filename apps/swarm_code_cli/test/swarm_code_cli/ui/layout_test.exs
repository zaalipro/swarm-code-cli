defmodule SwarmCodeCLI.UI.LayoutTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Layout, Size}
  alias SwarmCodeCLI.UI.Layout.Preferences
  alias SwarmCodeCLI.UI.Scene.Rect

  test "classification uses the highest class meeting both dimensions" do
    for {c, r, expected} <- [
          {170, 34, :xl},
          {169, 34, :wide},
          {170, 33, :wide},
          {150, 30, :wide},
          {149, 30, :medium},
          {150, 29, :medium},
          {100, 24, :medium},
          {99, 24, :narrow},
          {100, 23, :narrow},
          {72, 20, :narrow},
          {71, 20, :small},
          {72, 19, :small},
          {50, 16, :small},
          {50, 15, :compressed_small},
          {50, 14, :compressed_small},
          {49, 14, :too_small},
          {50, 13, :too_small},
          {1, 1, :too_small},
          {300, 16, :small},
          {300, 14, :compressed_small}
        ] do
      assert Layout.classify(size(c, r)) == expected
    end
  end

  test "wide shell matches desktop navigation transcript and inspector hierarchy" do
    layout = Layout.calculate(size(150, 30), Preferences.new())
    # The navigator dock is gone; row 1 is the tab row and main starts at column 0.
    refute Map.has_key?(layout.rects, :navigator)
    assert layout.rects.title == %Rect{x: 0, y: 0, width: 150, height: 1}
    assert layout.rects.tabline == %Rect{x: 0, y: 1, width: 150, height: 1}
    assert layout.rects.inspector == %Rect{x: 108, y: 2, width: 42, height: 27}
    assert layout.rects.main == %Rect{x: 5, y: 2, width: 96, height: 23}
    assert layout.rects.activity == %Rect{x: 5, y: 25, width: 96, height: 1}
    assert layout.rects.composer == %Rect{x: 5, y: 26, width: 96, height: 3}
    assert layout.rects.status == %Rect{x: 0, y: 29, width: 150, height: 1}
    assert layout.mutations_visible?

    # Main's band is still exactly the old 80 columns plus the navigator's 26 and
    # its gap: it runs from column 0 to the inspector's gap column and no pane
    # claims any of it. Main sets a 96-cell reading measure inside that band and
    # centres it, so the columns reclaimed from the navigator show up as equal
    # gutters instead of as 107-column lines of prose.
    band = layout.rects.inspector.x - 1
    assert band == 80 + 26 + 1
    assert layout.rects.main.width == 96
    assert layout.rects.main.x == div(band - layout.rects.main.width, 2)
    assert band - layout.rects.main.x - layout.rects.main.width == 6
    # Rows in order: 0 title, 1 tabline, main, activity, composer, 29 status.
    assert layout.rects.main.y == layout.rects.tabline.y + 1

    assert layout.rects.activity.y == layout.rects.main.y + layout.rects.main.height
    assert layout.rects.composer.y == layout.rects.activity.y + layout.rects.activity.height

    assert layout.rects.status.y ==
             layout.rects.composer.y + layout.rects.composer.height
  end

  test "medium docks exactly one pane and shrinking never overwrites preferred widths" do
    preferences = Preferences.new(inspector_width: 56, medium_dock: :inspector)
    medium = Layout.calculate(size(100, 24), preferences)
    assert medium.rects.main.width == 50
    assert medium.rects.inspector.width == 49
    refute Map.has_key?(medium.rects, :navigator)
    assert medium.preferences == preferences
    wide = Layout.calculate(size(150, 30), medium.preferences)
    assert wide.rects.inspector.width == 56
    # No navigator at any class now, so main takes what the dock used to hold.
    refute Map.has_key?(wide.rects, :navigator)
    assert wide.rects.main == %Rect{x: 0, y: 2, width: 93, height: 23}

    # `:none` is the named absence of a dock — the value `:navigator` used to
    # hold, now that it no longer points at a deleted pane — and it is the
    # default, so a stock medium terminal gives main the whole width.
    assert Preferences.new().medium_dock == :none
    assert_raise ArgumentError, fn -> Preferences.new(medium_dock: :navigator) end

    none = Layout.calculate(size(100, 24), %{preferences | medium_dock: :none})
    refute Map.has_key?(none.rects, :navigator)
    refute Map.has_key?(none.rects, :inspector)
    assert none.rects.main.x == 0
    assert none.rects.main.width == 100
    assert none.rects.tabline == %Rect{x: 0, y: 1, width: 100, height: 1}
    assert Layout.calculate(size(100, 24), Preferences.new()).rects == none.rects

    # And Ctrl-B docks the inspector a medium terminal can still hold.
    assert Layout.calculate(size(100, 24), %{preferences | medium_dock: :inspector}).rects
           |> Map.has_key?(:inspector)
  end

  test "the reading measure centres main only when the band can spare a gutter" do
    # A band wider than the 96-cell reading measure plus four cells of gutter on
    # each side sets 96 columns and centres them. A narrower band is handed over
    # untouched: main keeps every column it owns and still starts at column 0,
    # or at the dock offset, so no terminal loses text to a cosmetic margin.
    for {columns, rows, preferences, expected} <- [
          # 104 is the first band that can spare the gutter: 4 + 96 + 4.
          {104, 24, Preferences.new(), %Rect{x: 4, y: 2, width: 96, height: 17}},
          {103, 24, Preferences.new(), %Rect{x: 0, y: 2, width: 103, height: 17}},
          {100, 24, Preferences.new(), %Rect{x: 0, y: 2, width: 100, height: 17}},
          {80, 24, Preferences.new(), %Rect{x: 0, y: 2, width: 80, height: 17}},
          {72, 20, Preferences.new(), %Rect{x: 0, y: 2, width: 72, height: 13}},
          {50, 16, Preferences.new(), %Rect{x: 0, y: 2, width: 50, height: 11}},
          # xl: a 42-cell inspector and its gap column leave a 127-cell band.
          {170, 34, Preferences.new(), %Rect{x: 15, y: 2, width: 96, height: 27}},
          # A 56-cell inspector at 150 columns leaves 93, under the measure.
          {150, 30, Preferences.new(inspector_width: 56),
           %Rect{x: 0, y: 2, width: 93, height: 23}}
        ] do
      rects = Layout.calculate(size(columns, rows), preferences).rects
      assert rects.main == expected, "main at #{columns}x#{rows}"

      # The band is everything from column 0 up to the inspector's gap column,
      # because nothing is docked on the left any more.
      band = if(rects[:inspector], do: rects.inspector.x - 1, else: columns)

      if band >= 104 do
        assert rects.main.width == 96
        assert rects.main.width < band
        assert rects.main.x == div(band - rects.main.width, 2)
        assert rects.main.x > 0
      else
        assert rects.main.x == 0
        assert rects.main.width == band
      end

      # Activity and the composer sit in the same reading column as main, so the
      # conversation, its strip and its input share one left edge.
      for pane <- [:activity, :composer], Map.has_key?(rects, pane) do
        assert rects[pane].x == rects.main.x, "#{pane} at #{columns}x#{rows}"
        assert rects[pane].width == rects.main.width, "#{pane} at #{columns}x#{rows}"
      end
    end
  end

  test "small terminals preserve content while survival sizes have no composer" do
    preferences = Preferences.new(composer_height: 8, activity_height: 2)
    small = Layout.calculate(size(50, 16), preferences)
    assert small.rects.composer.height == 1
    assert small.rects.activity.height == 1
    assert small.rects.main.width == 50
    assert small.preferences == preferences

    for dimensions <- [{50, 14}, {49, 13}, {1, 1}] do
      {c, r} = dimensions
      layout = Layout.calculate(size(c, r), preferences)
      refute layout.mutations_visible?
      refute Map.has_key?(layout.rects, :composer)
    end

    assert Layout.calculate(size(1, 1), preferences).rects ==
             %{main: %Rect{x: 0, y: 0, width: 1, height: 1}}
  end

  test "all pane rectangles are positive, disjoint and bounded at every breakpoint" do
    for c <- [1, 49, 50, 51, 71, 72, 73, 99, 100, 101, 149, 150, 151, 169, 170, 171],
        r <- [1, 13, 14, 15, 16, 19, 20, 23, 24, 29, 30, 33, 34, 35],
        dock <- [:none, :inspector] do
      layout =
        Layout.calculate(
          size(c, r),
          Preferences.new(
            navigator_width: 32,
            inspector_width: 56,
            composer_height: 8,
            activity_height: 2,
            medium_dock: dock
          )
        )

      rects = Map.values(layout.rects)

      for rect <- rects do
        assert rect.width > 0 and rect.height > 0
        assert rect.x >= 0 and rect.y >= 0
        assert rect.x + rect.width <= c and rect.y + rect.height <= r
        for other <- rects, rect != other, do: refute(overlap?(rect, other))
      end

      if Map.has_key?(layout.rects, :navigator) or Map.has_key?(layout.rects, :inspector),
        do: assert(layout.rects.main.width >= 50)
    end
  end

  test "nudge and presets update preferences without losing them to effective clamping" do
    preferences = Preferences.new()
    changed = preferences |> Preferences.nudge(:navigator, 8) |> Preferences.nudge(:inspector, -2)
    assert changed.navigator_width == 34
    assert changed.inspector_width == 40
    # The navigator preference is still carried and reset-able, but no pane reads
    # it any more, so the width it asks for is never drawn.
    refute Map.has_key?(Layout.calculate(size(150, 30), changed).rects, :navigator)

    # The 34 columns the navigator preference asks for are deducted from nothing:
    # main's band still runs from column 0 to the 40-cell inspector's gap, which
    # is 109 columns. Main reads 96 of them and centres inside the rest.
    nudged = Layout.calculate(size(150, 30), changed).rects
    assert nudged.inspector.width == 40
    assert nudged.inspector.x - 1 == 109
    assert nudged.main.width == 96
    assert nudged.main == %Rect{x: 6, y: 2, width: 96, height: 23}
    assert nudged.main.x == div(109 - nudged.main.width, 2)

    # Effective clamping still leaves the stored preference alone on the pane
    # that is drawn: 50 columns requested, 49 granted at 100 columns.
    docked = Preferences.new(inspector_width: 50, medium_dock: :inspector)
    assert Layout.calculate(size(100, 24), docked).rects.inspector.width == 49
    assert docked.inspector_width == 50
    assert Preferences.reset(changed, :navigator).navigator_width == 26
    assert Preferences.preset(changed, :inspector, :balanced).inspector_width == 46
    assert_raise FunctionClauseError, fn -> Preferences.nudge(changed, :inspector, 3) end
    assert_raise ArgumentError, fn -> Preferences.new(medium_dock: :both) end
  end

  defp size(c, r), do: %Size{columns: c, rows: r}

  defp overlap?(a, b),
    do:
      a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and
        b.y < a.y + a.height
end
