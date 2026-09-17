defmodule SwarmCodeCLI.UI.Scene.Block.Columns do
  @moduledoc """
  Columns painted side by side.

  Each column is laid out to its own width and the rows are zipped across the
  columns with `gap` spaces between; a column that runs out of rows contributes
  blanks in the inherited style. The widths plus the gaps must fit the region.
  """
  alias SwarmCodeCLI.UI.Scene.Block

  @enforce_keys [:columns]
  defstruct [:columns, gap: 1]

  @type column :: %{width: pos_integer(), blocks: [Block.t()]}
  @type t :: %__MODULE__{columns: [column()], gap: non_neg_integer()}
end
