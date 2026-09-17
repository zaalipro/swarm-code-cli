defmodule SwarmCodeCLI.UI.Scene.Block.Surface do
  @enforce_keys [:blocks]
  defstruct [:blocks, :accent, tone: :card, rounded: false, edges: :corners]

  # `:corners` is the rounded quadrant frame; `:half` paints the top row as a
  # lower half block and the bottom row as an upper half block in the surface
  # colour over the outside colour (a half-row margin). At tier `:measured`
  # `:half` falls back to `:corners`.
  @type edges :: :corners | :half
  @type t :: %__MODULE__{
          blocks: [SwarmCodeCLI.UI.Scene.Block.t()],
          tone: atom(),
          accent: atom() | nil,
          rounded: boolean(),
          edges: edges()
        }
end
