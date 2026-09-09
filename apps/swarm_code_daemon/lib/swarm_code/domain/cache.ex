defmodule SwarmCode.Domain.Cache do
  @moduledoc """
  Read-through cache for the three rows the engine re-reads on its hot path
  (spec 54 §1.3, 54a A2).

  `Providers.get/1` runs once per LLM call (spec 51 §6.8, so a rotated key
  reaches the next request), `Projects.get/1` once per tool op (spec 39, so a
  changed approval mode applies to the next op) and `Settings.get/0` once per
  tool batch (spec 51 §6.11) and three times per run start. Under 54a's
  eight-lane load that was 41 000 of 152 000 queries — **27 % of everything the
  database did** — and in the burst those reads waited an average of 5.5 ms for
  a pool connection because the writers held theirs while they slept in
  SQLite's busy handler.

  The liveness those three call sites bought is kept: nothing here has a TTL.
  A key is dropped by the same broadcast the writers already send
  (`Providers.broadcast/0`, `Projects.broadcast/0`, `Settings.update/1`), so the
  next call reads the row. Spec 51 §3 refuted a `:persistent_term` Settings
  cache because it leaked across sandboxed tests; this table is cleared by
  `DataCase.setup_sandbox/1` on both ends of every test.

  Only the engine call sites use it. The LiveViews keep reading rows: they are
  user-paced, and a settings form must never render its own cache.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  The cached value for `key`, or `fun.()` stored under it.

  A `nil` result is cached too — a deleted provider is a miss on every call
  otherwise, which is exactly the path the hot loop takes.
  """
  # spec 60 T20: rows are `{key, value, gen}`; `{{:gen, tag}, n}` counts invalidations per tag.
  # A fill captures its gen before `fun.()`, so a stale fill lands with an old gen and misses.
  @spec fetch(term(), (-> value)) :: value when value: term()
  def fetch(key, fun) do
    gen = gen(key)

    case :ets.lookup(@table, key) do
      [{^key, value, ^gen}] ->
        value

      _ ->
        value = fun.()
        :ets.insert(@table, {key, value, gen})
        value
    end
  rescue
    # No table: the application is not started (a unit test, a release script).
    ArgumentError -> fun.()
  end

  @doc "Drops every key whose first element is `tag` (`:provider`, `:project`)."
  @spec invalidate(atom()) :: :ok
  def invalidate(tag) do
    bump(tag)
    :ets.match_delete(@table, {{tag, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops one key."
  @spec delete(term()) :: :ok
  def delete(key) do
    bump(tag(key))
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empties the table (tests, and any write path that cannot name its key)."
  @spec clear() :: :ok
  def clear do
    for [tag] <- :ets.match(@table, {{:gen, :"$1"}, :_}), do: bump(tag)
    :ets.match_delete(@table, {:_, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp tag({tag, _}) when is_atom(tag), do: tag
  defp tag(tag) when is_atom(tag), do: tag
  defp tag(_other), do: :other

  defp gen(key),
    do: :ets.update_counter(@table, {:gen, tag(key)}, {2, 0}, {{:gen, tag(key)}, 0})

  defp bump(tag), do: :ets.update_counter(@table, {:gen, tag}, 1, {{:gen, tag}, 0})
end
