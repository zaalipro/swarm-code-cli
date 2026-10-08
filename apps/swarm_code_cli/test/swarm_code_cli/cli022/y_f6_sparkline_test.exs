defmodule SwarmCodeCLI.Cli022.YF6SparklineTest do
  # cli022 F6: one bar is one finished, measured call. A lone sample has no
  # trend to compare: it is drawn at half height at most (it read as a full
  # block, the loudest glyph of the panel), on the right where the newest goes.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Projector.Vitals

  test "a lone sample is half height, never a full block" do
    assert Vitals.spark([100], 100, 5, :rich) == "    ▄"
    assert Vitals.spark([100], 100, 5, :measured) == "    ⣤"
    assert Vitals.spark([100], 100, 5, :ascii) |> String.trim_leading() != "#"
    # Lower than half on the shared scale: drawn as it is.
    assert Vitals.spark([10], 100, 5, :rich) == "    ▂"
  end

  test "two samples or more keep the shared scale" do
    assert Vitals.spark([50, 100], 100, 5, :rich) == "   ▅█"
    assert Vitals.spark([0, 50, 100], 100, 5, :rich) == "  ▁▅█"
  end
end
