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

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_size}
  def validate(%__MODULE__{columns: columns, rows: rows} = size)
      when is_integer(columns) and columns > 0 and is_integer(rows) and rows > 0 and
             map_size(size) == 3,
      do: {:ok, size}

  def validate(_size), do: {:error, :invalid_size}

  @spec valid?(term()) :: boolean()
  def valid?(size), do: match?({:ok, _size}, validate(size))

  @spec validate!(term()) :: t()
  def validate!(size) do
    case validate(size) do
      {:ok, valid} -> valid
      {:error, :invalid_size} -> raise ArgumentError, "invalid terminal size"
    end
  end
end
