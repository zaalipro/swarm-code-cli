defmodule SwarmCodeCLI.UI.Scene.Announcement do
  alias SwarmCodeCLI.UI.SafeText
  @enforce_keys [:id, :text]
  defstruct [:id, :text, politeness: :polite]
  @type t :: %__MODULE__{id: binary(), text: SafeText.t(), politeness: :polite | :assertive}
end
