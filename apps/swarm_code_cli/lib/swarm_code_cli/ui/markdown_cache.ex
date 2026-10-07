defmodule SwarmCodeCLI.UI.MarkdownCache do
  @moduledoc """
  cli020 D21 (tui-code-17, for E31): the rendered-markdown row cache that
  lives in `State.markdown_cache`, owned by the session runtime.

  After each projection the runtime merges the rows the projector reports
  as computed (`table.markdown_rows`, `key => rows`) with `merge/3`. Every
  entry is byte-accounted (`:erlang.external_size/1` of its key and value);
  past 4 MiB the least recently merged keys go first, one at a time, so an
  eviction only ever costs an exact recomputation, never data. A switch to
  another conversation empties it.
  """

  @max_bytes 4 * 1024 * 1024

  defstruct entries: %{}, order: :gb_trees.empty(), bytes: 0, tick: 0, scope: nil

  @type t :: %__MODULE__{
          entries: %{term() => {term(), non_neg_integer(), non_neg_integer()}},
          order: :gb_trees.tree(),
          bytes: non_neg_integer(),
          tick: non_neg_integer(),
          scope: term()
        }

  @doc "The byte bound."
  def max_bytes, do: @max_bytes

  @doc "An empty cache for `scope` (the conversation in view)."
  def new(scope \\ nil), do: %__MODULE__{scope: scope}

  @doc "The cached rows of `key`, or nil."
  def get(%__MODULE__{entries: entries}, key) do
    case Map.get(entries, key) do
      {value, _bytes, _tick} -> value
      nil -> nil
    end
  end

  def get(_cache, _key), do: nil

  @doc """
  Merges `rows` (`key => value`) for `scope`; a different scope starts over.
  An entry larger than the whole bound is not kept.
  """
  @spec merge(t() | nil, map(), term()) :: t()
  def merge(cache, rows, scope)
  def merge(%__MODULE__{scope: scope} = cache, rows, scope) when rows == %{}, do: cache
  def merge(%__MODULE__{scope: scope} = cache, rows, scope), do: Enum.reduce(rows, cache, &put/2)
  def merge(_cache, rows, scope), do: merge(new(scope), rows, scope)

  defp put({key, value}, cache) do
    bytes = :erlang.external_size(key) + :erlang.external_size(value)
    cache = delete(cache, key)

    if bytes > @max_bytes do
      cache
    else
      tick = cache.tick + 1

      %{
        cache
        | entries: Map.put(cache.entries, key, {value, bytes, tick}),
          order: :gb_trees.insert(tick, key, cache.order),
          bytes: cache.bytes + bytes,
          tick: tick
      }
      |> evict()
    end
  end

  defp delete(cache, key) do
    case Map.pop(cache.entries, key) do
      {nil, _} ->
        cache

      {{_value, bytes, tick}, entries} ->
        %{
          cache
          | entries: entries,
            order: :gb_trees.delete(tick, cache.order),
            bytes: cache.bytes - bytes
        }
    end
  end

  defp evict(%{bytes: bytes} = cache) when bytes <= @max_bytes, do: cache

  defp evict(cache) do
    {_tick, key} = :gb_trees.smallest(cache.order)
    cache |> delete(key) |> evict()
  end
end
