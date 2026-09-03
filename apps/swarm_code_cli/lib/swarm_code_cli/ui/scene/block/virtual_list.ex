defmodule SwarmCodeCLI.UI.Scene.Block.VirtualList do
  alias SwarmCodeCLI.UI.Scene.Block

  defstruct total_count: 0,
            first_index: 0,
            items: [],
            before_cursor: nil,
            after_cursor: nil,
            overscan: 0

  @type t :: %__MODULE__{
          total_count: non_neg_integer(),
          first_index: non_neg_integer(),
          items: [Block.t()],
          before_cursor: binary() | nil,
          after_cursor: binary() | nil,
          overscan: 0..2
        }
end
