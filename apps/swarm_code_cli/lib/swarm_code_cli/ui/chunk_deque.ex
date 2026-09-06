defmodule SwarmCodeCLI.UI.ChunkDeque do
  @moduledoc "Prepend-only stream chunks keyed by entity/channel/attempt. Overflow preserves all admitted bytes."
  @derive {Inspect, only: [:limit]}
  defstruct entries: %{}, limit: 65_536
  @type t :: %__MODULE__{}
  def new(limit \\ 65_536) when is_integer(limit) and limit > 0, do: %__MODULE__{limit: limit}

  def append(deque, {id, channel, attempt} = key, text)
      when channel in [:text, :reasoning] and is_binary(text) do
    {chunks, bytes} = Map.get(deque.entries, key, {[], 0})

    cond do
      not SwarmCodeCLI.UI.Intent.valid_id?(id) or not SwarmCodeCLI.UI.Intent.valid_id?(attempt) or
          not String.valid?(text) ->
        {:error, :invalid_chunk, deque}

      text == "" ->
        {:ok, deque}

      bytes + byte_size(text) > deque.limit ->
        {:error, :snapshot_required, deque}

      true ->
        {:ok,
         %{
           deque
           | entries: Map.put(deque.entries, key, {[text | chunks], bytes + byte_size(text)})
         }}
    end
  end

  def reset(deque, {id, channel, attempt} = key, text) do
    candidate = %{
      deque
      | entries:
          Map.reject(deque.entries, fn {{entity, kind, old_attempt}, _} ->
            entity == id and (channel == kind or old_attempt != attempt)
          end)
    }

    case append(candidate, key, text) do
      {:ok, next} -> {:ok, next}
      {:error, reason, _} -> {:error, reason, deque}
    end
  end

  def materialize(deque, key) do
    {chunks, _} = Map.get(deque.entries, key, {[], 0})
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def delete(deque, id),
    do: %{deque | entries: Map.reject(deque.entries, fn {{entity, _, _}, _} -> entity == id end)}
end
