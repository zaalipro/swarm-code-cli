defmodule SwarmCodeCLI.Cli020.E27PalettesTest do
  # cli020 E27 (competitors-21): the desktop's eight themes as palettes, dark
  # and light, token by token from `assets/css/themes.css`; faint and ghost
  # at E23's floors in every one.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.{Paint, Projector, Theme}
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.Paint.Options

  @names ~w(carbon aurora dusk ember fjord graphite obsidian paper)a

  # Carbon's dark values the palettes are keyed by.
  @surface 0x191919
  @card 0x1E1E1E
  @faint 0x868583
  @ghost 0x6A6967
  @muted 0x8C8B88

  test "eight palettes, carbon first" do
    assert Theme.palettes() == @names
  end

  for name <- @names, mode <- [:dark, :light] do
    test "#{name} #{mode}: faint ≥ 4.5 and ghost ≥ 3.0 on its surface and card" do
      v = &Theme.palette_value(unquote(name), unquote(mode), &1)

      for surface <- [v.(@surface), v.(@card)] do
        assert Theme.contrast(v.(@faint), surface) >= 4.5
        assert Theme.contrast(v.(@ghost), surface) >= 3.0
        assert Theme.contrast(v.(@muted), surface) >= Theme.contrast(v.(@faint), surface) - 0.01
      end
    end
  end

  test "desktop values, token by token (dusk)" do
    assert Theme.palette_value(:dusk, :dark, @muted) == 0xA094B8
    assert Theme.palette_value(:dusk, :dark, 0xFF6A1A) == 0xF2604E
    assert Theme.palette_value(:dusk, :light, @card) == 0xFFFFFF
    assert Theme.palette_value(:dusk, :light, 0xF3F2F0) == 0x221B33
    # Carbon is today's values.
    assert Theme.palette_value(:carbon, :dark, @muted) == @muted
  end

  defp entries(state, palette, theme) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{color_mode: :truecolor, palette: palette, theme: theme})

    Tuple.to_list(plan.palette)
  end

  defp hex({:rgb, r, g, b}), do: r * 65_536 + g * 256 + b
  defp hex(_), do: nil

  test "painting with a palette exchanges every Carbon token" do
    state = fixture(:chat, {100, 30}, color_mode: :truecolor)
    carbon = entries(state, :carbon, :dark)
    dusk = entries(state, :dusk, :dark)
    assert length(carbon) == length(dusk)

    pairs = Enum.zip(carbon, dusk)

    assert Enum.any?(pairs, fn {c, d} ->
             hex(c.foreground) == @muted and hex(d.foreground) == 0xA094B8
           end)

    refute Enum.any?(dusk, &(hex(&1.foreground) == @muted))

    light = entries(state, :dusk, :light)
    assert Enum.any?(light, &(hex(&1.background) == 0xF3F0F8 or hex(&1.foreground) == 0x221B33))
  end

  test "options accept the eight and nothing else" do
    assert :ok = Options.validate(%Options{palette: :fjord})
    assert {:error, :invalid_options} = Options.validate(%Options{palette: :neon})
  end

  test "cli.json palette and the registry row" do
    assert Preferences.legacy(%{"palette" => "dusk"}).palette == :dusk
    assert Preferences.legacy(%{"palette" => "neon"}).palette == :carbon
    assert Preferences.defaults().palette == :carbon
    entry = Enum.find(Registry.all(), &(&1.key == "terminal.palette"))
    assert entry.default == "carbon"
    assert entry.storage == {:cli, "palette"}
    assert length(entry.choices) == 8
  end
end
