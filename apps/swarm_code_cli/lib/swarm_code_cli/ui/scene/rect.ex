defmodule SwarmCodeCLI.UI.Scene.Rect do
  @enforce_keys [:x, :y, :width, :height]
  defstruct [:x, :y, :width, :height]

  @type t :: %__MODULE__{
          x: non_neg_integer(),
          y: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer()
        }
end
