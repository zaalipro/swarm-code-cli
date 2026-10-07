defmodule SwarmCode.Domain.LLM.Speed do
  @moduledoc """
  Spec 75 (pass 71): the sidebar speed monitor's numbers — the most recent
  output tokens/second per model slot (main, worker, validator) of each
  conversation.

  The op process that streams a call writes its byte count straight into a
  public ETS row (one `:ets.update_counter/3` per delta, nothing else); this
  process owns the table, monitors the streaming processes, ticks once a second
  only while something streams, and broadcasts `{:speed_sample, conversation_id,
  roles}` on "speed" only when a shown value changes. At most 32
  conversations are kept; the least recently touched one goes first.
  """
  use GenServer

  @table :swarm_code_speed
  @topic "speed"
  @max_conversations 32
  @min_window_ms 250
  # Smoke H3: a bursty provider (big chunks) makes a short live window read far
  # too fast, so a live estimate needs a full second of streaming; the exact
  # value at finish keeps @min_window_ms.
  @min_live_window_ms 1_000
  @roles [:main, :worker, :validator]

  # ------------------------------------------------------------------ API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, @topic)

  @doc "The shown values of one conversation (an ETS read, never a call)."
  def get(conversation_id) when is_binary(conversation_id) do
    case :ets.whereis(@table) do
      :undefined ->
        %{}

      _tid ->
        case :ets.lookup(@table, {:conv, conversation_id}) do
          [{_key, shown}] -> shown
          [] -> %{}
        end
    end
  end

  def get(_conversation_id), do: %{}

  def enabled? do
    Application.get_env(:swarm_code_daemon, :speed_sampler, true) == true and
      :ets.whereis(@table) != :undefined
  end

  @doc "Starts measuring one call; nil (a no-op handle) when it is not measured."
  def begin(%{conversation_id: cid, role: role}, model)
      when is_binary(cid) and role in @roles do
    if enabled?() do
      %{
        key: {:stream, make_ref()},
        conversation_id: cid,
        role: role,
        model: to_string(model || ""),
        t0: now()
      }
    end
  end

  def begin(_tag, _model), do: nil

  @doc "Hot path: one process-dictionary read and one ETS counter bump."
  def delta(nil, _bytes), do: :ok

  def delta(%{key: key} = handle, bytes) do
    case Process.get(key) do
      true ->
        bump(key, bytes)

      nil ->
        Process.put(key, true)
        first(handle, bytes)

      # Spec 75 §11.3: the first delta after a stream retry restarts the window.
      :retry ->
        Process.put(key, true)
        restart(key, bytes)
    end

    :ok
  end

  @doc """
  Spec 75 §11.3: a stream retry (`{:text_reset}`) throws the partial text away,
  so the call's byte counter and first-token time start over — the live
  estimate and the bytes/4 fallback then count only the final attempt. One ETS
  write per retry; nothing is sent to the owner (it already watches the op).
  """
  def retry(nil), do: :ok

  def retry(%{key: key}) do
    if Process.get(key) do
      Process.put(key, :retry)
      reset_row(key)
    end

    :ok
  end

  @doc "Ends one call with the stream's return value."
  def finish(nil, _result), do: :ok

  def finish(%{key: key} = handle, result) do
    output =
      case result do
        {:ok, %{usage: %{output: n}}} when is_integer(n) and n > 0 -> n
        _other -> nil
      end

    ok? = match?({:ok, _}, result)

    cond do
      Process.delete(key) ->
        GenServer.cast(__MODULE__, {:finish, key, now(), output, ok?})

      # Spec 75 critic: a call that streamed no text and no thinking — one bare
      # tool call, whose arguments emit no event (anthropic.ex:907/915) — has no
      # row. It is still measured, once, over its whole window (contract §5.2).
      ok? and is_integer(output) ->
        GenServer.cast(__MODULE__, {:finish_bare, Map.delete(handle, :key), now(), output})

      true ->
        :ok
    end

    :ok
  end

  @doc false
  # Tests only: forget everything.
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc false
  def now do
    case Application.get_env(:swarm_code_daemon, :speed_clock) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.monotonic_time(:millisecond)
    end
  end

  # The table can vanish under a crashed owner; a lost sample is fine, a
  # crashed operation is not.
  defp bump(key, bytes) do
    :ets.update_counter(@table, key, {7, bytes})
  rescue
    ArgumentError -> :ok
  end

  defp reset_row(key) do
    :ets.update_element(@table, key, [{6, now()}, {7, 0}])
  rescue
    ArgumentError -> :ok
  end

  defp restart(key, bytes) do
    :ets.update_element(@table, key, [{6, now()}, {7, bytes}])
  rescue
    ArgumentError -> :ok
  end

  defp first(handle, bytes) do
    row = {handle.key, handle.conversation_id, handle.role, handle.model, handle.t0, now(), bytes}
    :ets.insert(@table, row)
    GenServer.cast(__MODULE__, {:streaming, handle.key, self()})
  rescue
    ArgumentError -> :ok
  end

  # --------------------------------------------------------------- server
  #
  # state.streams: key => %{pid, mref}
  # state.convs:   cid => %{exact: %{role => value}, live: %{role => value},
  #                         shown: %{role => value}, touched: integer}
  # A value: %{tps:, ttft_ms:, model:, at:, live?:} (contract §5.3).

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{streams: %{}, convs: %{}, timer: nil, seq: 0}}
  end

  @impl true
  def handle_cast({:streaming, key, pid}, state) do
    mref = Process.monitor(pid)
    state = %{state | streams: Map.put(state.streams, key, %{pid: pid, mref: mref})}
    {:noreply, ensure_tick(state)}
  end

  def handle_cast({:finish, key, t_end, output, ok?}, state) do
    case take_stream(state, key) do
      {nil, state} ->
        {:noreply, state}

      {{_key, cid, role, model, t0, t_first, bytes}, state} ->
        window = t_end - t_first
        tokens = output || div(bytes, 4)

        state =
          if ok? and window >= @min_window_ms and tokens > 0 do
            value = %{
              tps: round(tokens * 1000 / window),
              ttft_ms: max(t_first - t0, 0),
              model: model,
              at: DateTime.utc_now() |> DateTime.truncate(:second),
              live?: false
            }

            update_conv(state, cid, fn conv -> put_in(conv, [:exact, role], value) end)
          else
            state
          end

        {:noreply, refresh_live(state, [cid])}
    end
  end

  # Spec 75 critic: no first delta — the window is the whole call (t0 to the
  # end), so the rate includes the wait for the first token; ttft is unknown.
  def handle_cast({:finish_bare, h, t_end, output}, state) do
    window = t_end - h.t0

    state =
      if window >= @min_window_ms do
        value = %{
          tps: round(output * 1000 / window),
          ttft_ms: nil,
          model: h.model,
          at: DateTime.utc_now() |> DateTime.truncate(:second),
          live?: false
        }

        update_conv(state, h.conversation_id, fn conv -> put_in(conv, [:exact, h.role], value) end)
      else
        state
      end

    {:noreply, refresh_live(state, [h.conversation_id])}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    for {_key, %{mref: mref}} <- state.streams, do: Process.demonitor(mref, [:flush])
    if state.timer, do: Process.cancel_timer(state.timer)
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{streams: %{}, convs: %{}, timer: nil, seq: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = %{state | timer: nil}
    cids = for {key, _} <- state.streams, row <- :ets.lookup(@table, key), do: elem(row, 1)
    state = refresh_live(state, Enum.uniq(cids))
    {:noreply, ensure_tick(state)}
  end

  # The op that streamed died (stopped run, crash): its estimate goes.
  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    case Enum.find(state.streams, fn {_key, s} -> s.mref == mref end) do
      nil ->
        {:noreply, state}

      {key, _s} ->
        {row, state} = take_stream(state, key)
        cids = if row, do: [elem(row, 1)], else: []
        {:noreply, refresh_live(state, cids)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------- helpers

  defp take_stream(state, key) do
    row =
      case :ets.take(@table, key) do
        [row] -> row
        [] -> nil
      end

    case Map.pop(state.streams, key) do
      {nil, streams} ->
        {row, %{state | streams: streams}}

      {%{mref: mref}, streams} ->
        Process.demonitor(mref, [:flush])
        {row, %{state | streams: streams}}
    end
  end

  # Recomputes the live estimates of `cids` from the rows still streaming and
  # publishes each conversation whose shown map changed.
  defp refresh_live(state, cids) do
    now = now()

    rows =
      for {key, _s} <- state.streams, row <- :ets.lookup(@table, key), do: row

    Enum.reduce(cids, state, fn cid, acc ->
      live =
        rows
        |> Enum.filter(fn row -> elem(row, 1) == cid end)
        |> Enum.group_by(fn row -> elem(row, 2) end)
        |> Enum.flat_map(fn {role, role_rows} -> live_value(role, role_rows, now) end)
        |> Map.new()

      acc
      |> update_conv(cid, fn conv -> %{conv | live: live} end)
      |> publish(cid)
    end)
  end

  defp live_value(role, rows, now) do
    rates =
      for {_k, _c, _r, _m, _t0, t_first, bytes} <- rows,
          bytes > 0,
          now - t_first >= @min_live_window_ms,
          do: div(bytes, 4) * 1000 / (now - t_first)

    case rates do
      [] ->
        []

      rates ->
        {_k, _c, _r, model, t0, t_first, _b} = Enum.max_by(rows, &elem(&1, 5))
        tps = round(Enum.sum(rates) / length(rates))
        [{role, %{tps: tps, ttft_ms: max(t_first - t0, 0), model: model, at: nil, live?: true}}]
    end
  end

  defp update_conv(state, cid, fun) do
    seq = state.seq + 1
    conv = Map.get(state.convs, cid, %{exact: %{}, live: %{}, shown: %{}, touched: seq})
    convs = Map.put(state.convs, cid, %{fun.(conv) | touched: seq})
    evict(%{state | convs: convs, seq: seq})
  end

  defp evict(state) when map_size(state.convs) <= @max_conversations, do: state

  defp evict(state) do
    {cid, _conv} = Enum.min_by(state.convs, fn {_cid, conv} -> conv.touched end)
    :ets.delete(@table, {:conv, cid})
    %{state | convs: Map.delete(state.convs, cid)}
  end

  defp publish(state, cid) do
    case Map.fetch(state.convs, cid) do
      {:ok, conv} ->
        shown = Map.merge(conv.exact, conv.live)

        if shown == conv.shown do
          state
        else
          :ets.insert(@table, {{:conv, cid}, shown})

          SwarmCode.Domain.PubSub.broadcast(
            SwarmCode.Domain.PubSub,
            @topic,
            {:speed_sample, cid, shown}
          )

          %{state | convs: Map.put(state.convs, cid, %{conv | shown: shown})}
        end

      :error ->
        state
    end
  end

  defp ensure_tick(%{timer: nil, streams: streams} = state) when map_size(streams) > 0 do
    ms = Application.get_env(:swarm_code_daemon, :speed_tick_ms, 1_000)
    %{state | timer: Process.send_after(self(), :tick, ms)}
  end

  defp ensure_tick(state), do: state
end
