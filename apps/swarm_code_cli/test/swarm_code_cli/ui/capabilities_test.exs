defmodule SwarmCodeCLI.UI.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Size}
  alias SwarmCodeCLI.UI.Capabilities.Probe

  defp probe(options \\ []) do
    struct!(
      Probe,
      [
        size: %Size{columns: 80, rows: 24},
        stdin_tty?: true,
        stdout_tty?: true,
        controlling_tty?: true,
        term: "xterm-256color",
        enhanced_keys: :supported,
        focus: :best_effort,
        paste: :best_effort,
        alternate_screen: :supported
      ] ++ options
    )
  end

  test "full screen fails closed for each missing terminal observation" do
    assert Capabilities.from_probe(probe()).full_screen?

    for option <- [:stdin_tty?, :stdout_tty?, :controlling_tty?] do
      caps = Capabilities.from_probe(probe([{option, false}]))
      refute caps.full_screen?
      assert caps.enhanced_keys == :unavailable
      assert caps.focus == :unavailable
      assert caps.paste == :unavailable
      assert caps.alternate_screen == :unavailable
    end

    for options <- [[plain?: true], [term: "dumb"], [term: nil], [term: ""]] do
      refute Capabilities.from_probe(probe(options)).full_screen?
    end
  end

  test "color precedence is no-color then monochrome then truecolor then 256 then 16" do
    for {options, expected} <- [
          {[no_color?: true, colorterm: "truecolor"], :monochrome},
          {[monochrome?: true, colorterm: "truecolor"], :monochrome},
          {[colorterm: "truecolor"], :truecolor},
          {[colorterm: "24bit"], :truecolor},
          {[], :ansi256},
          {[term: "xterm"], :ansi16},
          {[term: "dumb"], :monochrome},
          {[stdout_tty?: false, colorterm: "truecolor"], :monochrome}
        ] do
      assert Capabilities.from_probe(probe(options)).color_mode == expected
    end
  end

  test "truecolor terminal families are recognised without COLORTERM" do
    # Bare terminal names are recognised
    for term <- ~w[iterm iterm2 kitty wezterm alacritty ghostty foot contour rio] do
      caps = Capabilities.from_probe(probe(term: term, colorterm: nil))

      assert caps.color_mode == :truecolor,
             "expected #{term} to be recognised as truecolor"
    end

    # Real-world composite TERM values are recognised by component
    for term <- ~w[xterm-ghostty xterm-kitty xterm-wezterm foot-extra] do
      caps = Capabilities.from_probe(probe(term: term, colorterm: nil))

      assert caps.color_mode == :truecolor,
             "expected #{term} to be recognised as truecolor"
    end

    # Any *-direct suffix also gets :truecolor
    caps = Capabilities.from_probe(probe(term: "xterm-direct", colorterm: nil))
    assert caps.color_mode == :truecolor

    # COLORTERM still wins over the terminal family
    caps = Capabilities.from_probe(probe(term: "iterm", colorterm: "truecolor"))
    assert caps.color_mode == :truecolor

    # Suppression flags still force monochrome even for known terminals
    caps = Capabilities.from_probe(probe(term: "wezterm", no_color?: true))
    assert caps.color_mode == :monochrome

    caps = Capabilities.from_probe(probe(term: "alacritty", monochrome?: true))
    assert caps.color_mode == :monochrome

    # Unknown TERM still degrades
    caps = Capabilities.from_probe(probe(term: "obscure-term", colorterm: nil))
    assert caps.color_mode == :ansi16

    # xterm alone (no truecolor component) still degrades to ansi16
    caps = Capabilities.from_probe(probe(term: "xterm", colorterm: nil))
    assert caps.color_mode == :ansi16

    # *-256color still wins for unknown families
    caps = Capabilities.from_probe(probe(term: "obscure-256color", colorterm: nil))
    assert caps.color_mode == :ansi256
  end

  test "width overrides and explicit accessibility observations survive pure selection" do
    assert Capabilities.from_probe(probe()).ambiguous_width == :narrow

    for width <- [:narrow, :wide, "narrow", "wide"] do
      caps =
        Capabilities.from_probe(
          probe(ambiguous_width: width, ascii?: true, reduced_motion?: true)
        )

      assert Atom.to_string(caps.ambiguous_width) == to_string(width)
      assert caps.ascii? and caps.reduced_motion?
    end

    for width <- [:auto, "auto", "WIDE", false] do
      assert_raise ArgumentError, fn -> Capabilities.from_probe(probe(ambiguous_width: width)) end
    end
  end

  test "native limitations cannot be promoted by probe claims" do
    caps = Capabilities.from_probe(probe(paste_preallocation_bound?: true))
    assert caps.enhanced_keys == :supported
    assert caps.focus == :best_effort
    assert caps.paste == :best_effort
    assert caps.mouse == :unavailable
    refute caps.paste_preallocation_bound?
    refute Map.has_key?(caps, :clipboard)
    refute Map.has_key?(caps, :composition)

    for options <- [[stdin_tty?: :yes], [focus: :invented], [no_color?: "1"], [term: :xterm]] do
      assert_raise ArgumentError, fn -> Capabilities.from_probe(probe(options)) end
    end
  end

  describe "glyph_tier" do
    test "defaults to :measured" do
      caps = Capabilities.explicit(%Size{columns: 80, rows: 24}, [])
      assert caps.glyph_tier == :measured
    end

    test "ghostty with truecolor and the narrow policy is :rich" do
      probe = probe(term: "xterm-ghostty", colorterm: "truecolor")
      assert Capabilities.from_probe(probe).glyph_tier == :rich

      for term <- ["xterm-kitty", "wezterm", "iterm2", "xterm-iterm"] do
        assert Capabilities.from_probe(probe(term: term)).glyph_tier == :rich, term
      end
    end

    test "the wide policy, ASCII, a 256-colour terminal, or an unknown terminal stay :measured" do
      base = [term: "xterm-ghostty", colorterm: "truecolor"]

      assert Capabilities.from_probe(probe(base ++ [ambiguous_width: :wide])).glyph_tier ==
               :measured

      assert Capabilities.from_probe(probe(base ++ [ascii?: true])).glyph_tier == :measured
      assert Capabilities.from_probe(probe(base ++ [no_color?: true])).glyph_tier == :measured
      assert Capabilities.from_probe(probe(term: "xterm-256color")).glyph_tier == :measured
      assert Capabilities.from_probe(probe(term: "alacritty")).glyph_tier == :measured
    end

    test "explicit rejects an unknown tier" do
      assert_raise ArgumentError, fn ->
        Capabilities.explicit(%Size{columns: 80, rows: 24}, glyph_tier: :pixels)
      end
    end
  end
end
