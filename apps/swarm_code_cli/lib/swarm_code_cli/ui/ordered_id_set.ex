defmodule SwarmCodeCLI.UI.OrderedIdSet do
  @moduledoc "Insertion ordered bounded identities; overflow is explicit and lossless."
  defstruct order: [], index: MapSet.new(), limit: 512
  @type t :: %__MODULE__{}
  def new(limit \\ 512) when limit in 1..512, do: %__MODULE__{limit: limit}

  def put(set, id) do
    cond do
      not SwarmCodeCLI.UI.Intent.valid_id?(id) -> {:error, :invalid_id, set}
      MapSet.member?(set.index, id) -> {:ok, set}
      MapSet.size(set.index) >= set.limit -> {:error, :snapshot_required, set}
      true -> {:ok, %{set | order: [id | set.order], index: MapSet.put(set.index, id)}}
    end
  end

  def delete(set, id),
    do: %{set | order: List.delete(set.order, id), index: MapSet.delete(set.index, id)}

  def to_list(set), do: Enum.reverse(set.order)
  def size(set), do: MapSet.size(set.index)
  def member?(set, id), do: MapSet.member?(set.index, id)
  def clear(set), do: new(set.limit)
end
