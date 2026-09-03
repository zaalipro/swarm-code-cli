defmodule SwarmCodeCLI.UI.Size do
  @moduledoc """
  Positive terminal dimensions used by renderer-neutral UI data.
  """

  @enforce_keys [:columns, :rows]
  defstruct [:columns, :rows]

  @type t :: %__MODULE__{columns: pos_integer(), rows: pos_integer()}

  @spec new(term(), term()) :: {:ok, t()} | {:error, :invalid_size}
  def new(columns, rows)
      when is_integer(columns) and columns > 0 and is_integer(rows) and rows > 0 do
    {:ok, %__MODULE__{columns: columns, rows: rows}}
  end

  def new(_columns, _rows), do: {:error, :invalid_size}
end
