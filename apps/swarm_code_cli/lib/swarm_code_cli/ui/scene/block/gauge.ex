defmodule SwarmCodeCLI.UI.Scene.Block.Gauge do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:tone]
  defstruct [:tone, :label, value: 0, maximum: 0, style: :ticks]

  @type style :: :ticks | :bar | :segments
  @type t :: %__MODULE__{
          tone: atom(),
          value: non_neg_integer(),
          maximum: non_neg_integer(),
          style: style(),
          label: SafeText.t() | nil
        }
end
