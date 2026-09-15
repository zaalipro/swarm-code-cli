defmodule SwarmCodeCLI.UI.Scene.Block.Chart do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:series, :tone]
  defstruct [:series, :tone, :label, height: 1]

  @type t :: %__MODULE__{
          series: [non_neg_integer()],
          tone: atom(),
          height: 1..4,
          label: SafeText.t() | nil
        }
end
