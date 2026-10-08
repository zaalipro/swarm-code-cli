defmodule SwarmCode.Daemon.Service.Cli021ContextWindowTest do
  @moduledoc """
  cli021 C3: the status line's context window is the model's window (the
  configured one, else the default), not the 75 % trim budget the engine spends.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.ContextWindow

  defp settings(pricing), do: %{pricing: pricing}

  test "a configured window wins and is sent whole, not as the 75 % budget" do
    pricing = %{
      "deepseek-v4-pro" => %{"input" => 1.0, "output" => 2.0, "context_window" => 1_000_000}
    }

    assert ContextWindow.window("deepseek-v4-pro", settings(pricing)) == 1_000_000

    small = %{"tiny" => %{"input" => 0.1, "output" => 0.2, "context_window" => 32_000}}
    assert ContextWindow.window("tiny", settings(small)) == 32_000
  end

  test "a model without a configured window gets the domain's default" do
    assert ContextWindow.window("some-model", settings(%{})) == 120_000
    assert ContextWindow.window("some-model", nil) == 120_000
    assert ContextWindow.window("claude-sonnet", nil) == 160_000
  end

  test "the K1 default budget (750 000, 75 % of 1 M) reads as a 1 000 000 window" do
    # Pinned against the arithmetic K1 states, so the sync needs no edit here.
    assert trunc(1_000_000 * 0.75) == 750_000
    assert ContextWindow.__default__(750_000) == 1_000_000
  end

  test "no model, no window" do
    assert ContextWindow.window(nil, nil) == nil
    assert ContextWindow.window("", nil) == nil
  end
end
