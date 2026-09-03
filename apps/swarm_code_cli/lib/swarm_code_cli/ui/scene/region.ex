defmodule SwarmCodeCLI.UI.Scene.Region do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Rect}
  @enforce_keys [:id, :role, :rect, :label, :blocks]
  defstruct [
    :id,
    :role,
    :rect,
    :label,
    :blocks,
    focus: :inactive,
    scroll_offset: nil,
    visible_range: nil,
    follow: nil
  ]

  @type t :: %__MODULE__{
          id: binary(),
          role: atom(),
          rect: Rect.t(),
          label: SafeText.t(),
          blocks: [Block.t()],
          focus: atom(),
          scroll_offset: non_neg_integer() | nil,
          visible_range: {non_neg_integer(), non_neg_integer()} | nil,
          follow: :start | :end | :none | nil
        }
end
