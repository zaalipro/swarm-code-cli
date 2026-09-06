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
    assert layout.rects.navigator == %Rect{x: 0, y: 1, width: 26, height: 28}
    assert layout.rects.inspector == %Rect{x: 108, y: 1, width: 42, height: 28}
    assert layout.rects.main == %Rect{x: 27, y: 1, width: 80, height: 24}
    assert layout.rects.composer == %Rect{x: 27, y: 26, width: 80, height: 3}
    assert layout.rects.status == %Rect{x: 0, y: 29, width: 150, height: 1}
    assert layout.mutations_visible?
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
    assert wide.rects.navigator.width == 26

    nav = Layout.calculate(size(100, 24), %{preferences | medium_dock: :navigator})
    assert nav.rects.navigator.width == 26
    refute Map.has_key?(nav.rects, :inspector)
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
        dock <- [:navigator, :inspector] do
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
    assert Layout.calculate(size(150, 30), changed).rects.navigator.width == 32
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
