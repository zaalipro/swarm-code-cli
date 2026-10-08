defmodule SwarmCode.Daemon.Service.Vitals do
  @moduledoc """
  cli021 C2: the side panel's vitals, owned by one persisted backend.

  Per model slot of the shown conversation (main, worker, validator, and the
  other models its runs used) the newest output tokens per second and the last
  12 finished-call rates, from the synced engine's speed monitor
  (`Domain.LLM.Speed`: `{:speed_sample, conversation_id, roles}` on the
  `speed` topic and the ETS read `Speed.get/1`, the desktop's sidebar speed
  rows), and memory: the VM's total, the OS resident size of the VM and of the
  processes it started, and the machine's memory.

  Nothing runs unless the backend says a client watches (`demand/2`). Then one
  timer ticks: every second while a call streams or just finished, every five
  seconds otherwise (memory only), and `{:vitals, body}` goes to the
  subscriber only when a shown value changed and never sooner than one second
  after the last update. The model names come from an owned task that reads the
  conversation every ten seconds; the OS reading is another, every five. Both
  are `Task.Supervisor.async_nolink` children that stop with this process.

  The body is a string-keyed map of `DTO.Vitals` (`models` of `DTO.ModelSpeed`).
  """
  use GenServer

  alias SwarmCode.Daemon.Service.Vitals.{Config, OsMemory}
  alias SwarmCode.Domain.LLM.Speed

  @live_ms 1_000
  @idle_ms 5_000
  @min_emit_ms 1_000
  @hot_ms 3_000
  @config_ms 10_000
  @sys_ms 5_000
  @sys_timeout_ms 4_000
  @history 12
  @max_history_conversations 8
  @max_models 8
  @slots [:main, :worker, :validator]

  ## ------------------------------------------------------------------- API

  @doc """
  Options: `:subscriber` (required; receives `{:vitals, body}`), `:conversation_id`,
  and for tests `:speed` (`cid -> roles`), `:config` (`cid -> map`), `:sampler`
  (`keyword -> OsMemory.reading()`), `:clock` (`-> ms`, monotonic), `:wall` (`-> unix ms`),
  `:task_supervisor`.
  """
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The conversation the panel shows."
  def focus(server, conversation_id), do: GenServer.cast(server, {:focus, conversation_id})

  @doc "Whether a client watches: nothing is measured or sent while it does not."
  def demand(server, on?) when is_boolean(on?), do: GenServer.cast(server, {:demand, on?})

  @doc "The current body (for a snapshot), or nil without a conversation."
  def body(server) do
    GenServer.call(server, :body, 500)
  catch
    :exit, _ -> nil
  end

  ## ---------------------------------------------------------------- server

  @impl true
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)

    try do
      Speed.subscribe()
    rescue
      _ -> :ok
    end

    state = %{
      subscriber: subscriber,
      monitor: Process.monitor(subscriber),
      focus: Keyword.get(opts, :conversation_id),
      demand: false,
      speed: Keyword.get(opts, :speed, &Speed.get/1),
      config_fun: Keyword.get(opts, :config, &Config.read/1),
      sampler: Keyword.get(opts, :sampler, &OsMemory.read/1),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      wall: Keyword.get(opts, :wall, fn -> System.os_time(:millisecond) end),
      supervisor: Keyword.get(opts, :task_supervisor, SwarmCode.Domain.TaskSupervisor),
      config: %{},
      config_at: nil,
      config_task: nil,
      sys: %{os_rss_bytes: nil, children_rss_bytes: nil, machine_bytes: nil},
      sys_at: nil,
      sys_task: nil,
      history: %{},
      history_order: [],
      seen: %{},
      timer: nil,
      last_key: nil,
      last_emit: nil,
      hot_until: 0
    }

    {:ok, seed(state)}
  end

  @impl true
  def handle_call(:body, _from, state), do: {:reply, build(state), state}

  @impl true
  def handle_cast({:focus, id}, %{focus: id} = state), do: {:noreply, state}

  def handle_cast({:focus, id}, state) do
    state = %{state | focus: id, last_key: nil, config_at: nil}
    {:noreply, state |> seed() |> wake(:soon)}
  end

  def handle_cast({:demand, on?}, %{demand: on?} = state), do: {:noreply, state}

  def handle_cast({:demand, true}, state),
    do: {:noreply, wake(seed(%{state | demand: true, last_key: nil}), :soon)}

  def handle_cast({:demand, false}, state), do: {:noreply, cancel_timer(%{state | demand: false})}

  @impl true
  def handle_info({:speed_sample, cid, shown}, state) when is_map(shown) do
    state = absorb(state, cid, shown)

    if cid == state.focus and state.demand,
      do: {:noreply, wake(%{state | hot_until: now(state) + @hot_ms}, :soon)},
      else: {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = %{state | timer: nil}

    if state.demand and is_binary(state.focus),
      do: {:noreply, tick(state)},
      else: {:noreply, state}
  end

  # An owned task answered: the model names of a conversation, or the OS reading.
  def handle_info({ref, {:config, cid, config}}, %{config_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | config_task: nil,
        config_at: now(state),
        config: Map.put(state.config, cid, config)
    }

    {:noreply, if(cid == state.focus, do: wake(state, :soon), else: state)}
  end

  def handle_info({ref, {:sys, reading}}, %{sys_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    sys = Map.merge(state.sys, Map.reject(reading, fn {_key, value} -> is_nil(value) end))
    {:noreply, %{state | sys_task: nil, sys_at: now(state), sys: sys}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{config_task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | config_task: nil, config_at: now(state)}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sys_task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | sys_task: nil, sys_at: now(state)}}

  def handle_info({:sys_timeout, ref}, %{sys_task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, %{state | sys_task: nil, sys_at: now(state)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    for task <- [state.config_task, state.sys_task], task, do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  ## ------------------------------------------------------------------ tick

  defp tick(state) do
    state = state |> ensure_config() |> ensure_sys()
    body = build(state)
    key = comparable(body)
    now = now(state)

    state =
      if key != state.last_key do
        send(state.subscriber, {:vitals, body})
        %{state | last_key: key, last_emit: now}
      else
        state
      end

    state = %{state | hot_until: if(live?(body), do: now + @hot_ms, else: state.hot_until)}
    schedule(state, if(now < state.hot_until, do: @live_ms, else: @idle_ms))
  end

  # A change worth showing soon: the next update goes out when the one-second
  # floor since the last one allows.
  defp wake(%{demand: false} = state, _when), do: state
  defp wake(%{focus: nil} = state, _when), do: state
  defp wake(state, :soon), do: schedule(state, 0)

  defp schedule(state, wanted) do
    state = cancel_timer(state)
    floor = if state.last_emit, do: max(state.last_emit + @min_emit_ms - now(state), 0), else: 0
    %{state | timer: Process.send_after(self(), :tick, max(wanted, floor))}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp now(state), do: state.clock.()

  defp ensure_config(%{config_task: nil, focus: cid} = state) when is_binary(cid) do
    if state.config_at == nil or now(state) - state.config_at >= @config_ms do
      fun = state.config_fun
      task = Task.Supervisor.async_nolink(state.supervisor, fn -> {:config, cid, fun.(cid)} end)
      %{state | config_task: task}
    else
      state
    end
  end

  defp ensure_config(state), do: state

  defp ensure_sys(%{sys_task: nil} = state) do
    if state.sys_at == nil or now(state) - state.sys_at >= @sys_ms do
      sampler = state.sampler
      machine? = state.sys.machine_bytes == nil

      task =
        Task.Supervisor.async_nolink(state.supervisor, fn ->
          {:sys, sampler.(machine: machine?)}
        end)

      Process.send_after(self(), {:sys_timeout, task.ref}, @sys_timeout_ms)
      %{state | sys_task: task}
    else
      state
    end
  end

  defp ensure_sys(state), do: state

  ## ------------------------------------------------------------------ data

  # The speed monitor already holds the exact rates of finished calls of the
  # shown conversation: they are the first sample of each slot's history.
  defp seed(%{focus: cid} = state) when is_binary(cid), do: absorb(state, cid, state.speed.(cid))
  defp seed(state), do: state

  # A finished call (`live?: false`) with a new instant or rate is one more
  # sample of its slot; estimates of a streaming call are never stored.
  defp absorb(state, cid, shown) do
    Enum.reduce(@slots, state, fn slot, acc ->
      case Map.get(shown, slot) do
        %{live?: false, tps: tps, at: at} when is_integer(tps) ->
          mark = {at, tps}

          if Map.get(acc.seen, {cid, slot}) == mark,
            do: acc,
            else: push(acc, cid, slot, tps, mark)

        _other ->
          acc
      end
    end)
  end

  defp push(state, cid, slot, tps, mark) do
    per_slot = Map.get(state.history, cid, %{})
    samples = (Map.get(per_slot, slot, []) ++ [tps]) |> Enum.take(-@history)
    order = [cid | List.delete(state.history_order, cid)] |> Enum.take(@max_history_conversations)
    history = state.history |> Map.put(cid, Map.put(per_slot, slot, samples)) |> Map.take(order)

    %{
      state
      | history: history,
        history_order: order,
        seen: Map.put(state.seen, {cid, slot}, mark)
    }
  end

  defp build(%{focus: cid} = state) when is_binary(cid) do
    shown = state.speed.(cid)
    config = Map.get(state.config, cid, %{})
    history = Map.get(state.history, cid, %{})

    slots =
      Enum.filter(@slots, fn slot -> slot in base_slots(config) or Map.has_key?(shown, slot) end)

    rows =
      for slot <- slots,
          row =
            row(slot, Map.get(shown, slot), Map.get(config, slot), Map.get(history, slot, [])),
          do: row

    others = for name <- Map.get(config, :others, []), do: idle_row(:other, name)

    %{
      "conversation_id" => cid,
      "models" => Enum.take(rows ++ others, @max_models),
      "beam_bytes" => :erlang.memory(:total),
      "os_rss_bytes" => state.sys.os_rss_bytes,
      "children_rss_bytes" => state.sys.children_rss_bytes,
      "machine_bytes" => state.sys.machine_bytes,
      "sampled_at" => state.wall.()
    }
  end

  defp build(_state), do: nil

  defp base_slots(%{mode: :ultra}), do: @slots
  defp base_slots(%{mode: :two}), do: [:main, :worker]
  defp base_slots(_config), do: [:main]

  defp row(slot, nil, configured, _history) when configured in [nil, ""], do: idle_row(slot, nil)

  defp row(slot, nil, configured, history),
    do: %{idle_row(slot, configured) | "history" => history}

  defp row(slot, value, configured, history) do
    live? = value[:live?] == true
    tps = if is_integer(value[:tps]), do: value[:tps]

    %{
      "slot" => Atom.to_string(slot),
      "model" => clip(value[:model] || configured || ""),
      "tps" => tps,
      "live" => live?,
      "ttft_ms" => if(is_integer(value[:ttft_ms]), do: value[:ttft_ms]),
      "at" => at_ms(value[:at]),
      "history" => if(live? and tps, do: Enum.take(history ++ [tps], -@history), else: history)
    }
  end

  defp idle_row(_slot, nil), do: nil

  defp idle_row(slot, name) do
    %{
      "slot" => Atom.to_string(slot),
      "model" => clip(name),
      "tps" => nil,
      "live" => false,
      "ttft_ms" => nil,
      "at" => nil,
      "history" => []
    }
  end

  defp at_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp at_ms(_other), do: nil

  defp clip(name) when is_binary(name), do: String.slice(name, 0, 256)
  defp clip(_other), do: ""

  defp live?(nil), do: false
  defp live?(%{"models" => models}), do: Enum.any?(models, & &1["live"])

  # What makes two updates the same: the rows, and memory to a MiB (a byte of
  # drift is not news).
  defp comparable(nil), do: nil

  defp comparable(body) do
    {body["conversation_id"], body["models"], mib(body["beam_bytes"]), mib(body["os_rss_bytes"]),
     mib(body["children_rss_bytes"]), body["machine_bytes"]}
  end

  defp mib(nil), do: nil
  defp mib(bytes), do: div(bytes, 1_048_576)
end
