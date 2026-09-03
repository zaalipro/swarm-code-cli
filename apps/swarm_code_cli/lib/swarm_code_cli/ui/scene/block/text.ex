defmodule SwarmCodeCLI.UI.Scene.Block.Text do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:text]
  defstruct [:text, :action_id]
  @type t :: %__MODULE__{text: SafeText.t(), action_id: binary() | nil}
end
