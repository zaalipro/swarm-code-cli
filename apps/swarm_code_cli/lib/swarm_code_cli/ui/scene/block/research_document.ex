defmodule SwarmCodeCLI.UI.Scene.Block.ResearchDocument do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  @enforce_keys [:title]
  defstruct [:title, sources: []]
  @type t :: %__MODULE__{title: SafeText.t(), sources: [SafeText.t() | Span.t() | Block.t()]}
end
