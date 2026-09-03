defmodule SwarmCodeCLI.UI.Scene.Block.Markdown do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:text]
  defstruct [:text]
  @type t :: %__MODULE__{text: SafeText.t()}
end
