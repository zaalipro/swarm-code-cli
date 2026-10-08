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

  test "a model without a configured window gets the 1 M default (desktop pass 74 K1)" do
    assert ContextWindow.window("some-model", settings(%{})) == 1_000_000
    assert ContextWindow.window("some-model", nil) == 1_000_000
    # K1: one default for every model (the old Claude 160 000 budget is gone).
    assert ContextWindow.window("claude-sonnet", nil) == 1_000_000
  end

  test "the window is the synced engine's effective window, never its 75 % budget" do
    pricing = %{"tiny" => %{"input" => 0.1, "output" => 0.2, "context_window" => 32_000}}

    for {model, settings} <- [{"tiny", settings(pricing)}, {"other", settings(pricing)}, {"x", nil}] do
      assert ContextWindow.window(model, settings) ==
               SwarmCode.Domain.Engine.Context.effective_window(model, settings)
    end

    assert SwarmCode.Domain.Engine.Context.default_window() == 1_000_000
    refute function_exported?(ContextWindow, :__default__, 1)
  end

  test "no model, no window" do
    assert ContextWindow.window(nil, nil) == nil
    assert ContextWindow.window("", nil) == nil
  end
end
