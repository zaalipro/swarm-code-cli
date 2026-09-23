defmodule SwarmCode.Domain.Research.LevelsTest do
  @moduledoc """
  Spec 39 §1.6: honest agent counts and one word for a round.
  Spec 47 §1: `low` is **Fastest** — a lead, four workers and one reporter.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Research.Levels

  test "agents/1 counts every agent a level starts, headline included" do
    assert Levels.agents("low") == 6
    assert Levels.agents("medium") == 12
    assert Levels.agents("high") == 20
    assert Levels.agents("ultra") == 50
  end

  test "agents/2 without headlines drops one per round" do
    # Spec 47 §1: Fastest never starts a headline agent, so the toggle cannot
    # move its count — and it never starts an HTML one either, so 1 + 4 + 1.
    assert Levels.agents("low", headlines: false) == 6
    assert Levels.agents("medium", headlines: false) == 10
    assert Levels.agents("high", headlines: false) == 17
    assert Levels.agents("ultra", headlines: false) == 46
  end

  test "fast?/1 is true for low alone" do
    assert Levels.fast?("low")
    refute Levels.fast?("medium")
    refute Levels.fast?("high")
    refute Levels.fast?("ultra")
    # An unknown name falls back to the default level, which is not fast.
    refute Levels.fast?(nil)
    refute Levels.fast?("nonsense")
  end

  test "the hints say round, never step" do
    for name <- Levels.names() do
      assert Levels.hint(name) =~ "round"
      refute Levels.hint(name) =~ "step"
    end

    assert Levels.hint("low") == "1 round · 4 agents · minutes, not hours"
    assert Levels.hint("ultra") == "4 rounds · 10 agents each"
  end

  test "options/1 keeps the four-tuple shape and recounts on the toggle" do
    assert [
             {"low", "Fastest", _, 6},
             {"medium", "Medium", _, 12},
             {"high", _, _, 20},
             {"ultra", _, _, 50}
           ] =
             Levels.options()

    assert Enum.map(Levels.options(headlines: false), &elem(&1, 3)) == [6, 10, 17, 46]
  end

  test "low is one round of four agents" do
    assert Levels.steps("low") == 1
    assert Levels.fanout("low") == 4
    assert Levels.label("low") == "Fastest"
  end
end
