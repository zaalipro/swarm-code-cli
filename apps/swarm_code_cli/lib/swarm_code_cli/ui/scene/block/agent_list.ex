defmodule SwarmCodeCLI.UI.Scene.Block.AgentList do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  defstruct agents: []
  @type t :: %__MODULE__{agents: [SafeText.t() | Span.t() | Block.t()]}
end
