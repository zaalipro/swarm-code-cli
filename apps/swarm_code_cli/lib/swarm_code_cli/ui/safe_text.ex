defmodule SwarmCodeCLI.UI.SafeText do
  @moduledoc """
  Opaque text that is safe to place in terminal-facing UI data.

  This initial catalogue contains only fixed application chrome. External text
  does not have a constructor yet.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:token]
  defstruct [:token]

  @opaque t :: %__MODULE__{token: chrome()}
  @type chrome :: :fake_banner | :empty | :main | :help | :detach | :plain

  @spec chrome(chrome()) :: t()
  def chrome(:fake_banner), do: %__MODULE__{token: :fake_banner}
  def chrome(:empty), do: %__MODULE__{token: :empty}
  def chrome(:main), do: %__MODULE__{token: :main}
  def chrome(:help), do: %__MODULE__{token: :help}
  def chrome(:detach), do: %__MODULE__{token: :detach}
  def chrome(:plain), do: %__MODULE__{token: :plain}

  @spec value(t()) :: binary()
  def value(%{__struct__: __MODULE__, token: :fake_banner} = safe_text)
      when map_size(safe_text) == 2,
      do: "FAKE DEMO — NO USER DATA"

  def value(%{__struct__: __MODULE__, token: :empty} = safe_text)
      when map_size(safe_text) == 2,
      do: ""

  def value(%{__struct__: __MODULE__, token: :main} = safe_text)
      when map_size(safe_text) == 2,
      do: "Main"

  def value(%{__struct__: __MODULE__, token: :help} = safe_text)
      when map_size(safe_text) == 2,
      do: "Help"

  def value(%{__struct__: __MODULE__, token: :detach} = safe_text)
      when map_size(safe_text) == 2,
      do: "Detach"

  def value(%{__struct__: __MODULE__, token: :plain} = safe_text)
      when map_size(safe_text) == 2,
      do: "Plain"
end
