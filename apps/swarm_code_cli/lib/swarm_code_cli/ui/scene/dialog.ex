defmodule SwarmCodeCLI.UI.Scene.Dialog do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Rect}
  @enforce_keys [:id, :rect, :title, :blocks]
  defstruct [
    :id,
    :rect,
    :title,
    :blocks,
    :focused_control_id,
    footer: [],
    body_scroll: 0,
    body_visible_range: {0, 0},
    body_total_count: 0
  ]

  @type t :: %__MODULE__{
          id: binary(),
          rect: Rect.t(),
          title: SafeText.t(),
          blocks: [Block.t()],
          footer: [Block.t()],
          focused_control_id: binary() | nil,
          body_scroll: non_neg_integer(),
          body_visible_range: {non_neg_integer(), non_neg_integer()},
          body_total_count: non_neg_integer()
        }
end
