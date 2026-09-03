defmodule SwarmCodeCLI.UI.Scene.Block.Notice do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:text]
  defstruct [:text, :action_id, severity: :info]
  @type severity :: :info | :success | :warning | :error
  @type t :: %__MODULE__{severity: severity(), text: SafeText.t(), action_id: binary() | nil}
end
