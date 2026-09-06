defmodule SwarmCode.LLM.Chunks do
  @moduledoc "A linear append-only iodata accumulator for streamed LLM fields."

  @type t :: %__MODULE__{parts: iodata(), size: non_neg_integer()}
  defstruct parts: [], size: 0

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(binary()) :: t()
  def new(binary) when is_binary(binary),
    do: %__MODULE__{parts: [binary], size: byte_size(binary)}

  @spec append(t(), iodata()) :: t()
  def append(%__MODULE__{} = chunks, part) do
    %{chunks | parts: [part | chunks.parts], size: chunks.size + IO.iodata_length(part)}
  end

  @spec to_string(t()) :: binary()
  def to_string(%__MODULE__{parts: parts}), do: parts |> Enum.reverse() |> IO.iodata_to_binary()

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: size}), do: size == 0
end
