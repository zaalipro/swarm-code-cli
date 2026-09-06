defmodule SwarmCodeCLI.UI.Editor.Selection do
  @moduledoc "Logical grapheme selection; the editor retains its directional anchor."
  @type t :: nil | {non_neg_integer(), non_neg_integer()}
  def range(nil, _cursor), do: nil
  def range(cursor, cursor), do: nil
  def range(anchor, cursor), do: {min(anchor, cursor), max(anchor, cursor)}
end
