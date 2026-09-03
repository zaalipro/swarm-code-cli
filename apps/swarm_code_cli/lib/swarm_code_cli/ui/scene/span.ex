defmodule SwarmCodeCLI.UI.Scene.Span do
  alias SwarmCodeCLI.UI.{SafeText}
  alias SwarmCodeCLI.UI.Scene.Style
  @enforce_keys [:text]
  defstruct [:text, :action_id, style: %Style{}]
  @type t :: %__MODULE__{text: SafeText.t(), action_id: binary() | nil, style: Style.t()}
end
