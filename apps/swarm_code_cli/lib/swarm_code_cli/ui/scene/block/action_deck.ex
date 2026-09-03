defmodule SwarmCodeCLI.UI.Scene.Block.ActionDeck do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  defstruct actions: []
  @type t :: %__MODULE__{actions: [SafeText.t() | Span.t() | Block.t()]}
end
