defmodule SwarmCodeCLI.UI.Scene.Cursor do
  @enforce_keys [:x, :y]
  defstruct [:x, :y, shape: :block, visible?: true]

  @type t :: %__MODULE__{
          x: non_neg_integer(),
          y: non_neg_integer(),
          shape: :block | :bar | :underline,
          visible?: boolean()
        }
end
