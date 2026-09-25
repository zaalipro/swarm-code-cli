defmodule SwarmCode.Daemon.Service.Settings.TaskCache do
  @moduledoc """
  The settings tasks' result cache (pass 74, spec §3.3.8 rule 7), pure.

  a. The last result per task key `{action, target}`: at most 64 entries and
     4 MiB (an entry's size is its encoded JSON), least recently used first
     out. An entry that holds secret values (MCP import drafts) carries the
     reference of its purge timer; `purge/3` drops it only when the reference
     still matches (a replaced or evicted entry ignores its old timer).
  b. The sessions store — the last storage measure's sessions — lives beside
     the LRU: at most 20 000 rows and 6 MiB; a larger measure keeps the
     largest rows by bytes and says so.

  `Inspect` shows keys and sizes only.
  """

  @max_entries 64
  @max_bytes 4 * 1_024 * 1_024
  @max_sessions 20_000
  @max_sessions_bytes 6 * 1_024 * 1_024

  defstruct entries: %{},
            clock: 0,
            bytes: 0,
            sessions: nil,
            sessions_bytes: 0,
            sessions_truncated: false,
            max_entries: @max_entries,
            max_bytes: @max_bytes

  @type key :: {String.t(), term()}
  @type entry :: %{
          required(:task_id) => String.t(),
          required(:state) => String.t(),
          optional(:at) => term(),
          optional(:summary) => map() | nil,
          optional(:result) => term(),
          optional(:message) => String.t() | nil,
          optional(:secret?) => boolean(),
          optional(:purge_ref) => reference() | nil,
          optional(:target) => term(),
          optional(:action) => String.t()
        }
  @type t :: %__MODULE__{}

  @doc "An empty cache (bounds may be lowered for tests)."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(%__MODULE__{}, Keyword.take(opts, [:max_entries, :max_bytes]))

  @doc "Put the last result of a key; answers the cache and the keys evicted to make room."
  @spec put(t(), key(), entry()) :: {t(), [key()]}
  def put(%__MODULE__{} = cache, key, entry) do
    bytes = size_of(entry)
    cache = delete(cache, key)
    clock = cache.clock + 1

    stored = entry |> Map.put(:bytes, bytes) |> Map.put(:used, clock)

    cache = %{
      cache
      | entries: Map.put(cache.entries, key, stored),
        clock: clock,
        bytes: cache.bytes + bytes
    }

    evict(cache, key, [])
  end

  @doc "The entry of a key (nil when absent)."
  @spec get(t(), key()) :: entry() | nil
  def get(%__MODULE__{entries: entries}, key), do: Map.get(entries, key)

  @doc "Mark a key as just used."
  @spec touch(t(), key()) :: t()
  def touch(%__MODULE__{entries: entries} = cache, key) do
    case Map.fetch(entries, key) do
      {:ok, entry} ->
        clock = cache.clock + 1
        %{cache | clock: clock, entries: Map.put(entries, key, %{entry | used: clock})}

      :error ->
        cache
    end
  end

  @doc "The key and entry of a task id."
  @spec find_task(t(), String.t()) :: {key(), entry()} | nil
  def find_task(%__MODULE__{entries: entries}, task_id),
    do: Enum.find(entries, fn {_key, entry} -> entry.task_id == task_id end)

  @doc "Every entry of an action (for `:all` declarations)."
  @spec entries_for(t(), String.t()) :: [{key(), entry()}]
  def entries_for(%__MODULE__{entries: entries}, action),
    do: Enum.filter(entries, fn {{entry_action, _}, _entry} -> entry_action == action end)

  @doc "Drop a key."
  @spec delete(t(), key()) :: t()
  def delete(%__MODULE__{entries: entries} = cache, key) do
    case Map.pop(entries, key) do
      {nil, _} -> cache
      {entry, rest} -> %{cache | entries: rest, bytes: cache.bytes - entry.bytes}
    end
  end

  @doc "Drop a secrets-bearing entry when its purge timer's reference still matches."
  @spec purge(t(), key(), reference()) :: t()
  def purge(%__MODULE__{} = cache, key, ref) do
    case get(cache, key) do
      %{purge_ref: ^ref} -> delete(cache, key)
      _ -> cache
    end
  end

  @doc "Every purge-timer reference held (cancelled on terminate)."
  @spec purge_refs(t()) :: [reference()]
  def purge_refs(%__MODULE__{entries: entries}),
    do: for({_key, %{purge_ref: ref}} <- entries, is_reference(ref), do: ref)

  @doc "The number of entries and their bytes."
  @spec size(t()) :: {non_neg_integer(), non_neg_integer()}
  def size(%__MODULE__{entries: entries, bytes: bytes}), do: {map_size(entries), bytes}

  @doc """
  Replace the sessions store. Keeps the largest rows by `bytes` within 20 000
  rows and 6 MiB; answers whether rows were left out.
  """
  @spec put_sessions(t(), [map()]) :: {t(), boolean()}
  def put_sessions(%__MODULE__{} = cache, rows) when is_list(rows) do
    sorted = Enum.sort_by(rows, &(Map.get(&1, :bytes) || Map.get(&1, "bytes") || 0), :desc)

    {kept, bytes, _count} =
      Enum.reduce_while(sorted, {[], 0, 0}, fn row, {acc, bytes, count} ->
        size = size_of(row)

        if count >= @max_sessions or bytes + size > @max_sessions_bytes,
          do: {:halt, {acc, bytes, count}},
          else: {:cont, {[row | acc], bytes + size, count + 1}}
      end)

    truncated = length(kept) < length(rows)

    {%{
       cache
       | sessions: Enum.reverse(kept),
         sessions_bytes: bytes,
         sessions_truncated: truncated
     }, truncated}
  end

  @doc "The sessions store (nil before a measure)."
  @spec sessions(t()) :: [map()] | nil
  def sessions(%__MODULE__{sessions: sessions}), do: sessions

  @doc "True when the last measure had more sessions than the store keeps."
  @spec sessions_truncated?(t()) :: boolean()
  def sessions_truncated?(%__MODULE__{sessions_truncated: truncated}), do: truncated

  @doc "The encoded size of a value (what the byte bound counts)."
  @spec size_of(term()) :: non_neg_integer()
  def size_of(value) do
    case Jason.encode(SwarmCode.Daemon.Service.Settings.Wire.json(strip(value))) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> :erlang.external_size(value)
    end
  end

  defp strip(%{} = entry) when not is_struct(entry),
    do: Map.drop(entry, [:purge_ref, :used, :bytes])

  defp strip(value), do: value

  defp evict(cache, keep, evicted) do
    if map_size(cache.entries) > cache.max_entries or
         (cache.bytes > cache.max_bytes and map_size(cache.entries) > 1) do
      case oldest(cache, keep) do
        nil -> {cache, Enum.reverse(evicted)}
        key -> evict(delete(cache, key), keep, [key | evicted])
      end
    else
      {cache, Enum.reverse(evicted)}
    end
  end

  defp oldest(%__MODULE__{entries: entries}, keep) do
    entries
    |> Enum.reject(fn {key, _} -> key == keep end)
    |> Enum.min_by(fn {_key, entry} -> entry.used end, fn -> nil end)
    |> case do
      nil -> nil
      {key, _} -> key
    end
  end

  defimpl Inspect do
    def inspect(cache, _opts) do
      keys = Enum.map(cache.entries, fn {key, entry} -> {key, entry.bytes} end)

      "#SwarmCode.Daemon.Service.Settings.TaskCache<#{Kernel.inspect(keys)} " <>
        "sessions: #{length(cache.sessions || [])}>"
    end
  end
end
