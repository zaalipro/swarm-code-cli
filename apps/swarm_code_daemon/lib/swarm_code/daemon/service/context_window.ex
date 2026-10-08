defmodule SwarmCode.Daemon.Service.ContextWindow do
  @moduledoc """
  cli021 C3: the context window the status line shows for a model.

  The synced engine trims history to a budget that is 75 % of the model's
  window (`Engine.Context.budget/2`). The wire used to send that budget as
  `context_window`, so the status line read `8k/120k` for a model whose real
  window is 1 M. The window is now sent: the model's own `context_window`
  (Settings, Pricing; 8 000 to 2 000 000, the desktop's validation) when it has
  one, else the default window.

  The default is the engine's default budget turned back into a window. The
  desktop's pass 74 K1 makes every unconfigured model a 1 M window with a
  750 000 budget, so that budget reads as 1 M; the budgets of the domain this
  CLI is synced to today (120 000, Claude 160 000, `[1m]` 900 000) are not 75 %
  shares of a stated window and are sent as they are.
  """
  alias SwarmCode.Domain.Engine.Context

  @default_window 1_000_000
  @default_window_budget 750_000

  @doc "The window in tokens, or nil without a model."
  @spec window(String.t() | nil, map() | nil) :: pos_integer() | nil
  def window(model, settings) when is_binary(model) and model != "" do
    case Context.window(model, settings) do
      configured when is_integer(configured) and configured > 0 -> configured
      _none -> default(Context.budget(model, settings))
    end
  end

  def window(_model, _settings), do: nil

  @doc false
  def __default__(budget), do: default(budget)

  defp default(@default_window_budget), do: @default_window
  defp default(budget), do: budget
end
