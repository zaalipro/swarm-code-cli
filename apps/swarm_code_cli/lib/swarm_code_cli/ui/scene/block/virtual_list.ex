defmodule SwarmCodeCLI.UI.Scene.Block.VirtualList do
  defstruct total_count: 0,
            first_index: 0,
            items: [],
            before_cursor: nil,
            after_cursor: nil,
            overscan: 0

  @type t :: %__MODULE__{}
end
