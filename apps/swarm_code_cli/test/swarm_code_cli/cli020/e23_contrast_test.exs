defmodule SwarmCodeCLI.Cli020.E23ContrastTest do
  # cli020 E23 (tui-code-13): faint text reads at WCAG 4.5:1 and ghost text at
  # 3:1 on the surface and the card, dark and light; ANSI-16 faint is white;
  # high contrast makes faint and ghost muted and bold.
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Capabilities, Theme}

  defp caps(mode),
    do: %Capabilities{size: %SwarmCodeCLI.UI.Size{columns: 80, rows: 24}, color_mode: mode}

  defp hex(role, slot) do
    {:rgb, r, g, b} = Map.fetch!(Theme.style(role, caps(:truecolor)), slot).value
    r * 65_536 + g * 256 + b
  end

  defp light(hex) do
    {:rgb, r, g, b} =
      Theme.light(
        {:rgb, div(hex, 65_536), rem(div(hex, 256), 256), rem(hex, 256)},
        :text,
        :truecolor
      )

    r * 65_536 + g * 256 + b
  end

  test "the dark values" do
    assert hex(:text_faint, :foreground) == 0x868583
    assert hex(:text_ghost, :foreground) == 0x6A6967
  end

  for {mode, map} <- [dark: false, light: true] do
    test "#{mode}: faint ≥ 4.5 and ghost ≥ 3.0 on surface and card; muted above faint" do
      to = if unquote(map), do: &light/1, else: & &1
      surfaces = [to.(hex(:surface, :background)), to.(hex(:card, :background))]
      faint = to.(hex(:text_faint, :foreground))
      ghost = to.(hex(:text_ghost, :foreground))
      muted = to.(hex(:text_muted, :foreground))

      for surface <- surfaces do
        assert Theme.contrast(faint, surface) >= 4.5,
               "faint #{Integer.to_string(faint, 16)} on #{Integer.to_string(surface, 16)}"

        assert Theme.contrast(ghost, surface) >= 3.0,
               "ghost #{Integer.to_string(ghost, 16)} on #{Integer.to_string(surface, 16)}"

        assert Theme.contrast(muted, surface) >= Theme.contrast(faint, surface)
      end
    end
  end

  test "ANSI-16 faint is white" do
    assert Theme.style(:text_faint, caps(:ansi16)).foreground.value == {:ansi, :white}
  end

  test "256 colours: faint and ghost from the grey ramp, at the floors on 234" do
    assert Theme.style(:text_faint, caps(:ansi256)).foreground.value == {:indexed, 245}
    assert Theme.style(:text_ghost, caps(:ansi256)).foreground.value == {:indexed, 242}
  end

  test "high contrast: faint and ghost become muted and bold" do
    on_exit(fn -> Theme.put_high_contrast(false) end)
    :ok = Theme.put_high_contrast(true)
    muted = Theme.style(:text_muted, caps(:truecolor)).foreground

    for role <- [:text_faint, :text_ghost] do
      style = Theme.style(role, caps(:truecolor))
      assert style.foreground == muted
      assert :bold in style.modifiers
    end

    :ok = Theme.put_high_contrast(false)
    assert hex(:text_faint, :foreground) == 0x868583
  end
end
