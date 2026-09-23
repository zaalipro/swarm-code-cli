defmodule SwarmCode.Domain.PricingTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Pricing

  test "cost/4" do
    assert Pricing.cost(%{}, "m", 1, 1) == nil
    assert Pricing.cost(%{"m" => %{"input" => 1, "output" => 2}}, "m", 500_000, 250_000) == 1.0
  end

  # Spec 53b §5: a cached prefix is not billed at the input rate. `tokens_in` is
  # the whole prompt however it was billed, so the fresh part is what is left
  # after the read and the write.
  describe "cost/5 — prompt caching" do
    @opus %{"claude-opus-5" => %{"input" => 5.0, "output" => 25.0}}
    @fable %{"claude-fable-5-1" => %{"input" => 10.0, "output" => 50.0}}

    test "a cache read is a tenth of the input rate on an Opus-tier row" do
      # 1 M prompt: 100 k fresh, 800 k read, 100 k written.
      cost =
        Pricing.cost(@opus, "claude-opus-5", 1_000_000, 0, %{read: 800_000, write: 100_000})

      # 0.1×5 + 0.8×0.5 + 0.1×6.25
      assert cost == Float.round(0.5 + 0.4 + 0.625, 6)

      # The same prompt priced as if it were all fresh is 5.0 — eight times more.
      assert Pricing.cost(@opus, "claude-opus-5", 1_000_000, 0) == 5.0
    end

    test "Claude Fable 5.1 reads a cached prefix at a fortieth of its input rate" do
      assert Pricing.cache_read_multiplier("claude-fable-5-1") == 0.025
      assert Pricing.cache_read_multiplier("claude-mythos-5-1") == 0.025
      assert Pricing.cache_read_multiplier("claude-fable-5") == 0.1
      assert Pricing.cache_read_multiplier("claude-opus-5") == 0.1
      assert Pricing.cache_read_multiplier(nil) == 0.1

      # 1 M read: $0.25, not $10.
      assert Pricing.cost(@fable, "claude-fable-5-1", 1_000_000, 0, %{read: 1_000_000}) == 0.25
    end

    test "a row that names the two rates outright wins over the multipliers" do
      pricing = %{
        "m" => %{"input" => 10.0, "output" => 50.0, "cache_read" => 0.5, "cache_write" => 30.0}
      }

      assert Pricing.cost(pricing, "m", 1_000_000, 0, %{read: 1_000_000}) == 0.5
      assert Pricing.cost(pricing, "m", 1_000_000, 0, %{write: 1_000_000}) == 30.0
    end

    test "cost/4 and an empty cache map agree, and nonsense counts are ignored" do
      assert Pricing.cost(@opus, "claude-opus-5", 1_000, 100) ==
               Pricing.cost(@opus, "claude-opus-5", 1_000, 100, %{})

      assert Pricing.cost(@opus, "claude-opus-5", 1_000, 100, %{read: nil, write: -5}) ==
               Pricing.cost(@opus, "claude-opus-5", 1_000, 100)

      # A read bigger than the prompt cannot make the fresh part negative.
      assert Pricing.cost(@opus, "claude-opus-5", 10, 0, %{read: 1_000}) > 0.0
      assert Pricing.cost(%{}, "claude-opus-5", 10, 0, %{read: 1}) == nil
    end
  end

  test "add/2" do
    assert Pricing.add(nil, nil) == nil
    assert Pricing.add(0.5, nil) == 0.5
    assert Pricing.add(nil, 0.25) == 0.25
    assert Pricing.add(0.5, 0.25) == 0.75
  end
end
