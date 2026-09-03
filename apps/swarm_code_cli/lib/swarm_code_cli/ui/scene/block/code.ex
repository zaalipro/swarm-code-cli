defmodule SwarmCodeCLI.UI.Scene.Block.Code do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:text]
  defstruct [:text, :language]
  @type t :: %__MODULE__{text: SafeText.t(), language: SafeText.t() | nil}
end
