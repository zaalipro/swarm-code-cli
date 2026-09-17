defmodule SwarmCodeCLI.UI.Scene.Block.Chart do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:series, :tone]
  defstruct [:series, :tone, :label, height: 1, style: :braille]

  # `:sparkline` is one row of vertical eighths at tier `:rich` and falls back
  # to braille at height 1 elsewhere.
  @type style :: :braille | :sparkline
  @type t :: %__MODULE__{
          series: [non_neg_integer()],
          tone: atom(),
          height: 1..4,
          style: style(),
          label: SafeText.t() | nil
        }
end
