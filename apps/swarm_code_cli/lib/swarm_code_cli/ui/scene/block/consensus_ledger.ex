defmodule SwarmCodeCLI.UI.Scene.Block.ConsensusLedger do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  defstruct entries: []
  @type t :: %__MODULE__{entries: [SafeText.t() | Span.t() | Block.t()]}
end
