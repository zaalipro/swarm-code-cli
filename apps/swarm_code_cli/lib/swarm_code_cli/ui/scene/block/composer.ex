defmodule SwarmCodeCLI.UI.Scene.Block.Composer do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:text, :placeholder]
  defstruct [:text, :placeholder]
  @type t :: %__MODULE__{text: SafeText.t(), placeholder: SafeText.t()}
end
