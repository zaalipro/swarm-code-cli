defmodule SwarmCode.Daemon.Service.ContextWindow do
  @moduledoc """
  cli021 C3: the context window the status line shows for a model.

  The synced engine trims history to a budget that is 75 % of the model's
  window (`Engine.Context.budget/2`). The wire used to send that budget as
  `context_window`, so the status line read `8k/120k` for a model whose real
  window is 1 M. The window is now sent: the model's own `context_window`
  (Settings, Pricing; 8 000 to 2 000 000, the desktop's validation) when it has
  one, else the engine's default window (desktop pass 74 K1: 1 000 000 for
  every model, synced in cli021 K7), exactly `Context.effective_window/2`.
  """
  alias SwarmCode.Domain.Engine.Context

  @doc "The window in tokens, or nil without a model."
  @spec window(String.t() | nil, map() | nil) :: pos_integer() | nil
  def window(model, settings) when is_binary(model) and model != "",
    do: Context.effective_window(model, settings)

  def window(_model, _settings), do: nil
end
