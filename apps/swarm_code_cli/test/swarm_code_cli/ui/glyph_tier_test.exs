defmodule SwarmCodeCLI.UI.GlyphTierTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Size, Width}
  alias SwarmCodeCLI.UI.Projector.Support

  @rich [
    :eighth_1,
    :eighth_2,
    :eighth_3,
    :eighth_4,
    :eighth_5,
    :eighth_6,
    :eighth_7,
    :block_full,
    :half_lower,
    :half_upper,
    :vert_1,
    :vert_2,
    :vert_3,
    :vert_4,
    :vert_5,
    :vert_6,
    :vert_7,
    :dash_rule
  ]
  @measured [:copy_mark, :ops_mark, :command_mark]

  defp state(opts),
    do: %{capabilities: struct!(Capabilities, [size: %Size{columns: 80, rows: 24}] ++ opts)}

  defp value(token), do: SafeText.value(SafeText.chrome(token))

  test "every rich token is one cell under the narrow policy and has a measured twin" do
    assert Enum.sort(Map.keys(Support.measured_glyphs())) == Enum.sort(@rich)

    for token <- @rich do
      assert Width.cells(value(token), :narrow) == 1, "#{token} is not one cell under :narrow"

      twin = Map.fetch!(Support.measured_glyphs(), token)
      assert Width.cells(value(twin), :narrow) == 1, "#{twin} twin under :narrow"
      assert Width.cells(value(twin), :wide) == 1, "#{twin} twin under :wide"

      # The ASCII path goes through the twin, so every rich token has an ASCII form.
      ascii = SafeText.value(Support.glyph(token, state(ascii?: true, glyph_tier: :rich)))
      assert ascii =~ ~r/^[ -~]$/, "#{token} ASCII form #{inspect(ascii)}"
    end
  end

  test "every measured token is one cell under both policies with an ASCII twin" do
    for token <- @measured do
      assert Width.cells(value(token), :narrow) == 1
      assert Width.cells(value(token), :wide) == 1
      ascii = Map.fetch!(Support.glyphs(), token)
      assert value(ascii) =~ ~r/^[ -~]$/
    end
  end

  test "glyph/2 resolves a rich token by tier" do
    assert SafeText.value(Support.glyph(:block_full, state(glyph_tier: :rich))) == "█"
    assert SafeText.value(Support.glyph(:block_full, state(glyph_tier: :measured))) == "▐"

    assert SafeText.value(Support.glyph(:block_full, state(ascii?: true, glyph_tier: :rich))) ==
             "#"

    assert SafeText.value(Support.glyph(:eighth_4, state(glyph_tier: :rich))) == "▌"
    assert SafeText.value(Support.glyph(:dash_rule, state(glyph_tier: :measured))) == value(:rule)
    assert SafeText.value(Support.glyph(:half_lower, state(glyph_tier: :measured))) == "▗"
  end

  test "a measured token is the same at both tiers and only changes under ASCII" do
    assert SafeText.value(Support.glyph(:ops_mark, state(glyph_tier: :rich))) == "≣"
    assert SafeText.value(Support.glyph(:ops_mark, state(glyph_tier: :measured))) == "≣"
    assert SafeText.value(Support.glyph(:ops_mark, state(ascii?: true))) == "="
  end
end
