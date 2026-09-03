defmodule SwarmCodeCLI.UI.Scene.Block.Tabs do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  defstruct tabs: [], selected: 0
  @type t :: %__MODULE__{tabs: [SafeText.t() | Span.t() | Block.t()], selected: non_neg_integer()}
end
