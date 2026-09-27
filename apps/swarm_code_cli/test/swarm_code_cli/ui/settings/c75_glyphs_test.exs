defmodule SwarmCodeCLI.UI.Settings.C75GlyphsTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Size}
  alias SwarmCodeCLI.UI.Settings.Glyphs

  @size %Size{columns: 160, rows: 45}

  test "every glyph id has a rich, a measured and an ASCII twin" do
    for id <- Glyphs.ids(), tier <- [:rich, :measured, :ascii] do
      assert is_binary(Glyphs.get(id, tier)), "#{id} #{tier}"
    end
  end

  test "every ASCII twin is ASCII" do
    for id <- Glyphs.ids() do
      assert id |> Glyphs.get(:ascii) |> String.to_charlist() |> Enum.all?(&(&1 < 0x80)),
             "#{id}"
    end
  end

  test "the measured twin keeps the rich glyph's character count (the ladder has none)" do
    for id <- Glyphs.ids(), id != :ladder do
      assert String.length(Glyphs.get(id, :measured)) == String.length(Glyphs.get(id, :rich)),
             "#{id}"
    end

    assert Glyphs.get(:ladder, :measured) == ""
  end

  test "the E glyphs and their words" do
    assert Glyphs.get(:action, :ascii) == "+"
    assert Glyphs.get(:running, :rich) == "◐"
    assert Glyphs.get(:corner_tl, :rich) == "╭"
    assert Glyphs.asciify("←→ choose") == "Left/Right choose"
    assert Glyphs.asciify("↑↓ move") == "Up/Down move"
    assert Glyphs.asciify("▸ open") == "+ open"
  end

  test "twin?/1: the ASCII tier and NO_COLOR draw the twin" do
    assert Glyphs.twin?(%Capabilities{size: @size, color_mode: :truecolor, ascii?: true})
    assert Glyphs.twin?(%Capabilities{size: @size, color_mode: :monochrome, glyph_tier: :rich})

    refute Glyphs.twin?(%Capabilities{size: @size, color_mode: :truecolor, glyph_tier: :rich})

    refute Glyphs.twin?(%Capabilities{
             size: @size,
             color_mode: :truecolor,
             ambiguous_width: :wide
           })
  end
end
