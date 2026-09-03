defmodule SwarmCodeCLI.UI.SafeText do
  @moduledoc """
  Opaque text that is safe to place in terminal-facing UI data.

  This initial catalogue contains only fixed application chrome. External text
  does not have a constructor yet.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: binary()}
  @type chrome :: :fake_banner | :empty | :main | :help | :detach | :plain

  @spec chrome(chrome()) :: t()
  def chrome(:fake_banner), do: %__MODULE__{value: "FAKE DEMO — NO USER DATA"}
  def chrome(:empty), do: %__MODULE__{value: ""}
  def chrome(:main), do: %__MODULE__{value: "Main"}
  def chrome(:help), do: %__MODULE__{value: "Help"}
  def chrome(:detach), do: %__MODULE__{value: "Detach"}
  def chrome(:plain), do: %__MODULE__{value: "Plain"}

  @spec value(t()) :: binary()
  def value(%__MODULE__{value: value}), do: value
end
