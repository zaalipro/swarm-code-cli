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
end
