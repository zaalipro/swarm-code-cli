defmodule SwarmCodeCLI.UI.Settings.Wire do
  @moduledoc """
  The settings layer's requests to the service (spec §3.4): `settings.query`
  for the views a page reads and `settings.command` for the writes. Pure: it
  answers the effects that send them, correlated by the layer's generation
  and a reference.
  """

  alias SwarmCodeCLI.UI.Settings.Layer

  @doc """
  The effects that send a `settings.command` with `params` (`action`,
  `target`, `attributes`, `expected`, …) for the write `ref`, or the words
  why it cannot leave.
  """
  @spec command(map(), pos_integer(), map()) :: {:ok, map(), list()} | {:error, String.t()}
  def command(%{settings: %Layer{available: false, message: message}}, _ref, _params),
    do: {:error, message || "the settings service is not available"}

  # Until the settings wire is merged the service is never reached.
  def command(%{settings: %Layer{available: :wired}} = state, _ref, _params), do: {:ok, state, []}
  def command(_state, _ref, _params), do: {:error, "the settings service is not connected"}

  @doc "A service op of a section (`:command`, `:task`, `:cancel_task`, `:load`)."
  @spec op(map(), term()) :: {map(), list()}
  def op(state, _op), do: {state, []}
end
