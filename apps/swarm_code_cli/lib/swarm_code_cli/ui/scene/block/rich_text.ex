defmodule SwarmCodeCLI.UI.Scene.Block.RichText do
  alias SwarmCodeCLI.UI.Scene.Span
  defstruct spans: [], action_id: nil
  @type t :: %__MODULE__{spans: [Span.t()], action_id: binary() | nil}
end
