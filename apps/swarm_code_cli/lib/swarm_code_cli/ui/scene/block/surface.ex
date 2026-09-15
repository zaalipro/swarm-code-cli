defmodule SwarmCodeCLI.UI.Scene.Block.Surface do
  @enforce_keys [:blocks]
  defstruct [:blocks, :accent, tone: :card, rounded: false]

  @type t :: %__MODULE__{
          blocks: [SwarmCodeCLI.UI.Scene.Block.t()],
          tone: atom(),
          accent: atom() | nil,
          rounded: boolean()
        }
end
