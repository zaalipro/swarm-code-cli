defmodule SwarmCodeCLI.UI.Scene.Block.Progress do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:label]
  defstruct [:label, value: 0, maximum: 0]

  @type t :: %__MODULE__{
          label: SafeText.t(),
          value: non_neg_integer(),
          maximum: non_neg_integer()
        }
end
