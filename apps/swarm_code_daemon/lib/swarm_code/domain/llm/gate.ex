defmodule SwarmCode.Domain.LLM.Gate do
  @moduledoc """
  pass76 llm-gate: at most `:llm_max_concurrent_per_provider` (default 16)
  provider streams are in flight per key (a provider id, else a URL origin).
  Later callers queue first come, first served.

  `acquire/2` blocks the *caller*, never this server: the server answers at
  once with a grant or a place in the queue, and a queued caller waits in its
  own `receive`. The acquire ref is the monitor of the caller, so a holder that
  dies frees its slot and a waiter that dies leaves the queue; nothing leaks
  when an op task is killed mid-wait.
  """
  use GenServer

  @default_limit 16

  @type key :: term()
  @type ref :: reference()

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Takes a slot for `key`, waiting for one if the key is at its limit.

  Options: `:on_wait` (0-arity, called once if the caller has to queue) and
  `:on_acquired` (0-arity, called after a queued caller is admitted).
  """
  @spec acquire(key, keyword()) :: {:ok, ref} | {:error, :stopped}
  def acquire(key, opts \\ []) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :stopped}
      pid -> do_acquire(pid, key, opts)
    end
  end

  defp do_acquire(pid, key, opts) do
    gate_mon = Process.monitor(pid)

    try do
      case GenServer.call(pid, {:acquire, key, self()}, :infinity) do
        {:granted, ref} ->
          {:ok, ref}

        {:queued, ref} ->
          call(opts[:on_wait])
          await(ref, gate_mon, opts)
      end
    catch
      :exit, _ -> {:error, :stopped}
    after
      Process.demonitor(gate_mon, [:flush])
    end
  end

  defp await(ref, gate_mon, opts) do
    receive do
      {:gate_granted, ^ref} ->
        call(opts[:on_acquired])
        {:ok, ref}

      {:DOWN, ^gate_mon, :process, _, _} ->
        {:error, :stopped}
    end
  end

  defp call(nil), do: :ok
  defp call(fun), do: fun.()

  # pass76 llm-cooldown-patience: when a provider answers 429/529 every caller
  # of that key waits, not just the one that was told. The table is public so
  # a caller reads and raises its key without a message to this server, and it
  # holds one `{key, until_monotonic_ms}` row per provider or origin.
  @cooldown :swarm_code_llm_cooldown

  @doc """
  Raises the cooldown of `key` to `until` (monotonic ms). A later cooldown that
  is already there is never shortened, whoever writes at the same time.
  """
  @spec cool_down(key, integer()) :: :ok
  def cool_down(key, until) when is_integer(until) do
    case :ets.lookup(@cooldown, key) do
      [] ->
        if :ets.insert_new(@cooldown, {key, until}), do: :ok, else: cool_down(key, until)

      [{_, current}] when current >= until ->
        :ok

      [{_, current}] ->
        spec = [{{key, current}, [], [{{{:const, key}, until}}]}]
        if :ets.select_replace(@cooldown, spec) == 1, do: :ok, else: cool_down(key, until)
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "The monotonic ms `key` is cooling down until, or nil when it is not."
  @spec cooldown_until(key) :: integer() | nil
  def cooldown_until(key) do
    case :ets.lookup(@cooldown, key) do
      [{_, until}] -> until
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Gives the slot back. Safe to call twice or after the holder's slot is already gone."
  @spec release(ref) :: :ok
  def release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  @doc "`%{key => %{in_flight: n, waiting: n}}` for keys that hold or queue anything."
  @spec stats() :: %{key => %{in_flight: non_neg_integer(), waiting: non_neg_integer()}}
  def stats, do: GenServer.call(__MODULE__, :stats)

  # --------------------------------------------------------------- server

  @impl true
  def init(:ok) do
    :ets.new(@cooldown, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{keys: %{}, refs: %{}}}
  end

  @impl true
  def handle_call({:acquire, key, pid}, _from, state) do
    ref = Process.monitor(pid)
    entry = Map.get(state.keys, key, new_entry())

    if map_size(entry.holders) < limit() and :queue.is_empty(entry.queue) do
      entry = %{entry | holders: Map.put(entry.holders, ref, pid)}
      {:reply, {:granted, ref}, put(state, key, entry, ref)}
    else
      entry = %{entry | queue: :queue.in({ref, pid}, entry.queue), waiting: entry.waiting + 1}
      {:reply, {:queued, ref}, put(state, key, entry, ref)}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.new(state.keys, fn {key, e} ->
        {key, %{in_flight: map_size(e.holders), waiting: e.waiting}}
      end)

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:release, ref}, state), do: {:noreply, drop(state, ref)}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state), do: {:noreply, drop(state, ref)}
  def handle_info(_other, state), do: {:noreply, state}

  defp new_entry, do: %{holders: %{}, queue: :queue.new(), waiting: 0}

  defp put(state, key, entry, ref),
    do: %{state | keys: Map.put(state.keys, key, entry), refs: Map.put(state.refs, ref, key)}

  defp drop(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        state

      {key, refs} ->
        Process.demonitor(ref, [:flush])
        entry = Map.fetch!(state.keys, key)

        entry =
          if Map.has_key?(entry.holders, ref) do
            %{entry | holders: Map.delete(entry.holders, ref)}
          else
            # A waiter: the queue is rebuilt only for this rare removal.
            queue = :queue.filter(fn {r, _} -> r != ref end, entry.queue)
            %{entry | queue: queue, waiting: max(entry.waiting - 1, 0)}
          end

        state = %{state | refs: refs}
        state = admit(state, key, entry)
        state
    end
  end

  defp admit(state, key, entry) do
    if map_size(entry.holders) < limit() do
      case :queue.out(entry.queue) do
        {{:value, {ref, pid}}, queue} ->
          send(pid, {:gate_granted, ref})

          entry = %{
            entry
            | holders: Map.put(entry.holders, ref, pid),
              queue: queue,
              waiting: entry.waiting - 1
          }

          admit(state, key, entry)

        {:empty, _} ->
          store(state, key, entry)
      end
    else
      store(state, key, entry)
    end
  end

  defp store(state, key, entry) do
    if map_size(entry.holders) == 0 and entry.waiting == 0,
      do: %{state | keys: Map.delete(state.keys, key)},
      else: %{state | keys: Map.put(state.keys, key, entry)}
  end

  defp limit do
    case Application.get_env(:swarm_code_daemon, :llm_max_concurrent_per_provider, @default_limit) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_limit
    end
  end
end
