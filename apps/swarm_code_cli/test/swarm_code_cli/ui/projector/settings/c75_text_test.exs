defmodule SwarmCodeCLI.UI.Projector.Settings.C75TextTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Size, Theme}
  alias SwarmCodeCLI.UI.Projector.Settings.Text

  @modes [:truecolor, :ansi256, :ansi16, :monochrome]

  defp st(mode),
    do: %{capabilities: %Capabilities{size: %Size{columns: 120, rows: 40}, color_mode: mode}}

  test "select keeps a segment's modifiers (C19): the focused label stays bold" do
    assert [{"x", {{:text_primary, [:bold]}, :on, :selection} = role}] =
             Text.select([{"x", {:text_primary, [:bold]}}])

    assert :bold in Text.style(st(:truecolor), role).modifiers
  end

  test "band keeps a segment's modifiers too" do
    assert [{"x", {{:text_primary, [:bold]}, :on, :band} = role}] =
             Text.band([{"x", {:text_primary, [:bold]}}])

    assert :bold in Text.style(st(:truecolor), role).modifiers
  end

  test "the band is the accent chip's background in truecolor and 256 colours" do
    for mode <- [:truecolor, :ansi256] do
      state = st(mode)

      assert Text.style(state, {:text_primary, :on, :band}).background ==
               Theme.style(:chip_accent, state.capabilities).background
    end
  end

  test "the band is reverse video in 16 colours and NO_COLOR" do
    for mode <- [:ansi16, :monochrome] do
      style = Text.style(st(mode), {:text_primary, :on, :band})
      assert :reversed in style.modifiers
      assert style.background == Text.style(st(mode), :text_primary).background
    end
  end

  test "ghost, border, border_soft and ticks_track draw as text_faint in every mode" do
    for mode <- @modes, role <- [:text_ghost, :border, :border_soft, :ticks_track] do
      assert Text.style(st(mode), role) == Text.style(st(mode), :text_faint), "#{mode} #{role}"
    end
  end

  test "hover, surface and popover fills are dropped in 16 colours, kept in truecolor" do
    assert Text.style(st(:ansi16), {:text_muted, :on, :hover}).background ==
             Text.style(st(:ansi16), :text_muted).background

    for bg <- [:hover, :surface, :popover], mode <- [:ansi16, :monochrome] do
      assert Text.style(st(mode), {:text_muted, :on, bg}) == Text.style(st(mode), :text_muted)
    end

    state = st(:truecolor)

    assert Text.style(state, {:text_muted, :on, :hover}).background ==
             Theme.style(:hover, state.capabilities).background
  end

  describe "wrap_segments/3" do
    test "wraps across segment boundaries and keeps each word's role" do
      state = st(:truecolor)

      # Greedy: "alpha beta" is exactly 10 cells, so it fits on the first line.
      assert Text.wrap_segments(
               state,
               [{"alpha ", :text_primary}, {"beta gamma", :text_muted}],
               10
             ) ==
               [[{"alpha ", :text_primary}, {"beta", :text_muted}], [{"gamma", :text_muted}]]

      assert Text.wrap_segments(
               state,
               [{"alphabet ", :text_primary}, {"beta gamma", :text_muted}],
               10
             ) == [[{"alphabet", :text_primary}], [{"beta gamma", :text_muted}]]
    end

    test "a word wider than the line is split at the width, never cut with an ellipsis" do
      state = st(:truecolor)
      word = String.duplicate("x", 25)
      lines = Text.wrap_segments(state, [{"a " <> word, :text_primary}], 10)

      assert [[{"a", :text_primary}] | split] = lines
      assert Enum.map(split, fn [{text, _}] -> String.length(text) end) == [10, 10, 5]
      refute Enum.any?(lines, fn line -> Enum.any?(line, fn {t, _} -> t =~ "…" end) end)
    end

    test "wide graphemes wrap by cells" do
      state = st(:truecolor)

      assert Text.wrap_segments(state, [{"日本 語語 本日", :text_primary}], 5) ==
               [[{"日本", :text_primary}], [{"語語", :text_primary}], [{"本日", :text_primary}]]

      assert Text.wrap_segments(state, [{"日本語", :text_primary}], 5) ==
               [[{"日本", :text_primary}], [{"語", :text_primary}]]
    end

    test "no text is one empty line; wrap/3 keeps its string contract" do
      state = st(:truecolor)
      assert Text.wrap_segments(state, [], 10) == [[]]
      assert Text.wrap_segments(state, [{"", :text_primary}, {"", :text_muted}], 10) == [[]]
      assert Text.wrap(state, "", 10) == [""]
    end
  end

  test "scrim draws every segment faint and keeps a background wrapper" do
    assert Text.scrim([{"a", :accent}, {"b", {:text_primary, :on, :popover}}]) ==
             [{"a", :text_faint}, {"b", {:text_faint, :on, :popover}}]
  end
end
