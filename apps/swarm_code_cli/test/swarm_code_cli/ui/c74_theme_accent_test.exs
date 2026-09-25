defmodule SwarmCodeCLI.UI.C74ThemeAccentTest do
  # Not async: put_accent/1 writes a process-wide :persistent_term, and sync
  # modules run after every async one.
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Capabilities, Size, Theme}

  setup do
    Theme.put_accent(nil)
    on_exit(fn -> Theme.put_accent(nil) end)
  end

  defp caps(mode), do: %Capabilities{size: %Size{columns: 80, rows: 24}, color_mode: mode}

  test "without an accent the accent roles stay Carbon" do
    assert Theme.style(:accent, caps(:truecolor)).foreground.value == {:rgb, 255, 106, 26}
    assert Theme.style(:accent, caps(:ansi256)).foreground.value == {:indexed, 208}
    assert Theme.style(:accent, caps(:ansi16)).foreground.value == {:ansi, :bright_yellow}
  end

  test "an accent replaces every accent-derived role, with 256/16 twins" do
    Theme.put_accent({0x2D, 0xD4, 0xBF})

    for role <- [:accent, :focus, :assistant, :run_assistant, :chip_accent] do
      assert Theme.style(role, caps(:truecolor)).foreground.value == {:rgb, 0x2D, 0xD4, 0xBF}
    end

    assert Theme.style(:on_accent, caps(:truecolor)).background.value == {:rgb, 0x2D, 0xD4, 0xBF}
    assert Theme.style(:accent, caps(:ansi256)).foreground.value == {:indexed, 43}
    assert Theme.style(:accent, caps(:ansi16)).foreground.value == {:ansi, :cyan}
    # the chip tint is derived from the accent
    refute Theme.style(:chip_accent, caps(:truecolor)).background.value ==
             {:rgb, 0x3E, 0x29, 0x1D}

    # other roles are untouched
    assert Theme.style(:success, caps(:truecolor)).foreground.value == {:rgb, 0x3D, 0xDC, 0x5A}
  end

  test "accent twins are nearest colours" do
    assert %{ansi256: 196, ansi16: :bright_red} = Theme.accent_twins({255, 0, 0})
    assert %{ansi256: 21, ansi16: :blue} = Theme.accent_twins({0, 0, 255})
    assert %{ansi256: 231, ansi16: :bright_white} = Theme.accent_twins(0xFFFFFF)
    assert %{ansi256: 244} = Theme.accent_twins(0x808080)
  end

  test "contrast ratio" do
    assert Theme.contrast(0x000000, 0xFFFFFF) == 21.0
    assert Theme.contrast(0xFFFFFF, 0xFFFFFF) == 1.0
    assert Theme.contrast(0xFF6A1A, Theme.page_color(:dark)) > 4.5
    assert Theme.contrast(0xFF6A1A, Theme.page_color(:light)) < 4.5
  end
end
