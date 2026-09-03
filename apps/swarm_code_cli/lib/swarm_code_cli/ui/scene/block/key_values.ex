defmodule SwarmCodeCLI.UI.Scene.Block.KeyValues do
  alias SwarmCodeCLI.UI.SafeText
  defstruct rows: []
  @type t :: %__MODULE__{rows: [{SafeText.t(), SafeText.t()}]}
end
