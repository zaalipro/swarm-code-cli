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

  The engine call sites use it, and so does the router's theme read (spec 74
  EFFICIENCY-65). The LiveViews keep reading rows: they are user-paced, and a
  settings form must never render its own cache.
  """
  use GenServer

  @table __MODULE__
  # pass 77 D-ARCH-7: `{key, expires_at_ms, bytes}` for the values `put_derived/3` stored.
  @derived __MODULE__.Derived
  @epoch :"$cache_gen_epoch"
  @sweep_ms 30_000
  @default_derived_budget 16 * 1024 * 1024

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@derived, [:named_table, :public, :set])
    {:ok, %{timer: Process.send_after(self(), :sweep, @sweep_ms)}}
  end

  # pass 77 D-ARCH-7: ETS only, no IO. Expired derived values leave both tables; the
  # timer is replaced, not stacked, when a sweep is asked for by hand.
  @impl true
  def handle_info(:sweep, state) do
    if state[:timer], do: Process.cancel_timer(state.timer)
    sweep_expired()
    {:noreply, %{state | timer: Process.send_after(self(), :sweep, @sweep_ms)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

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

  @doc """
  Stores `value` under `key` outright (spec 67 T33).

  `fetch/2` is read-through — it has no way to record something the engine
  *learned*, like the rate-limit snapshot a response header carried.
  """
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value, gen(key)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  `put/2` for a value that is only derived from something else (a directory's agent
  definitions, a project's environment block) and can always be recomputed exactly.

  It expires `ttl_ms` after it was stored (the sweep drops it) and the table of all such values
  is held to `:cache_derived_budget_bytes` (default 16 MiB, by `:erlang.external_size/1`): over
  the budget, the values that expire first go first. An evicted value is a miss, which the
  caller answers by computing it again — nothing is lost. Values stored with `put/2` (what the
  engine *learned*, like a rate-limit snapshot) are never evicted.
  """
  @spec put_derived(term(), term(), pos_integer()) :: :ok
  def put_derived(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    :ets.insert(@table, {key, value, gen(key)})

    :ets.insert(
      @derived,
      {key, System.monotonic_time(:millisecond) + ttl_ms, :erlang.external_size(value)}
    )

    evict_over_budget()
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict_over_budget do
    budget =
      Application.get_env(
        :swarm_code_daemon,
        :cache_derived_budget_bytes,
        @default_derived_budget
      )

    rows = :ets.tab2list(@derived)
    total = Enum.reduce(rows, 0, fn {_key, _expires, bytes}, acc -> acc + bytes end)

    if total > budget do
      rows
      |> Enum.sort_by(fn {_key, expires, _bytes} -> expires end)
      |> Enum.reduce_while(total, fn {key, _expires, bytes}, left ->
        :ets.delete(@derived, key)
        :ets.delete(@table, key)
        if left - bytes > budget, do: {:cont, left - bytes}, else: {:halt, left - bytes}
      end)
    end

    :ok
  end

  defp sweep_expired do
    now = System.monotonic_time(:millisecond)

    for {key, expires, _bytes} <- :ets.tab2list(@derived), expires <= now do
      :ets.delete(@derived, key)
      :ets.delete(@table, key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The value stored under `key`, or `default`."
  @spec get(term(), term()) :: term()
  def get(key, default \\ nil) do
    gen = gen(key)

    case :ets.lookup(@table, key) do
      [{^key, value, ^gen}] -> value
      _other -> default
    end
  rescue
    ArgumentError -> default
  end

  @doc "Drops every key whose first element is `tag` (`:provider`, `:project`)."
  @spec invalidate(atom()) :: :ok
  def invalidate(tag) do
    bump(tag)
    :ets.match_delete(@table, {{tag, :_}, :_, :_})
    :ets.match_delete(@derived, {{tag, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops one key."
  @spec delete(term()) :: :ok
  def delete(key) do
    bump(tag(key))
    :ets.delete(@table, key)
    :ets.delete(@derived, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empties the table (tests, and any write path that cannot name its key)."
  @spec clear() :: :ok
  def clear do
    :ets.update_counter(@table, @epoch, 1, {@epoch, 0})
    :ets.match_delete(@table, {:_, :_, :_})
    :ets.delete_all_objects(@derived)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp tag({tag, _}) when is_atom(tag), do: tag
  defp tag(tag) when is_atom(tag), do: tag
  defp tag(_other), do: :other

  # spec 74 EFFICIENCY-63: a read never writes. The generation is `{epoch, tag gen}`, two
  # lock-free lookups on the `read_concurrency` table (the old `update_counter(…, {2, 0})` took the
  # write lock on every `fetch`/`get`/`put`). `clear/0` bumps the epoch, so a tag that was never
  # bumped is invalidated too.
  defp gen(key),
    do:
      {:ets.lookup_element(@table, @epoch, 2, 0),
       :ets.lookup_element(@table, {:gen, tag(key)}, 2, 0)}

  defp bump(tag), do: :ets.update_counter(@table, {:gen, tag}, 1, {{:gen, tag}, 0})
end
