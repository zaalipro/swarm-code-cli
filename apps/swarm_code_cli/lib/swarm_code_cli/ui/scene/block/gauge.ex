defmodule SwarmCodeCLI.UI.Scene.Block.Gauge do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:tone]
  defstruct [:tone, :label, :gradient_to, value: 0, maximum: 0, style: :ticks]

  # `:smooth` is an eighth-block fill (eight steps per cell) at tier `:rich`
  # and falls back to `:ticks` elsewhere. `gradient_to` names a second role;
  # at `:rich` under truecolor the painter mixes each lit cell from `tone`
  # towards it, and ignores it everywhere else.
  @type style :: :ticks | :bar | :segments | :smooth
  @type t :: %__MODULE__{
          tone: atom(),
          value: non_neg_integer(),
          maximum: non_neg_integer(),
          style: style(),
          gradient_to: atom() | nil,
          label: SafeText.t() | nil
        }
end
