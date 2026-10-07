defmodule SwarmCode.Daemon.Service.DesktopWatch do
  @moduledoc """
  cli020 C4 (bugs-6): notices the ncode app opening (or quitting) on the same
  database while a saved session runs.

  Every `interval_ms` (10 s) one probe runs as an owned
  `Task.Supervisor.async_nolink` task (`FoundationGate.desktop_running?/1`,
  about 0.25 s warm, 1 s cold, measured 2026-10-07). Only one probe runs at a
  time: a tick that finds the last one still running is skipped, never queued,
  and a probe older than three intervals is killed. When the answer changes,
  the subscriber (the persisted backend) receives `{:desktop_running, boolean}`.
  The persisted service starts this beside its backend; the live backend never
  does. It stops with the service and kills its probe.
  """
  use GenServer
  alias SwarmCode.Daemon.FoundationGate

  @interval_ms 10_000

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The last answer (false until a probe said otherwise)."
  def running?(server), do: GenServer.call(server, :running?)

  @impl true
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    interval = Keyword.get(opts, :interval_ms, @interval_ms)

    state = %{
      subscriber: subscriber,
      monitor: Process.monitor(subscriber),
      detector: Keyword.get(opts, :detector, fn -> FoundationGate.desktop_running?([]) end),
      interval: interval,
      supervisor: Keyword.get(opts, :task_supervisor, SwarmCode.Domain.TaskSupervisor),
      running: false,
      probe: nil,
      probe_at: nil,
      timer: nil,
      skipped: 0
    }

    {:ok, tick(state)}
  end

  @impl true
  def handle_call(:running?, _from, state), do: {:reply, state.running, state}
  def handle_call(:stats, _from, state), do: {:reply, Map.take(state, [:skipped, :probe]), state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(%{state | timer: nil})}

  def handle_info({ref, answer}, %{probe: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | probe: nil, probe_at: nil}
    running = answer == true

    if running != state.running do
      send(state.subscriber, {:desktop_running, running})
      {:noreply, %{state | running: running}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{probe: %Task{ref: ref}} = state),
    do: {:noreply, %{state | probe: nil, probe_at: nil}}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.probe, do: Task.shutdown(state.probe, :brutal_kill)
    :ok
  end

  defp tick(state) do
    now = System.monotonic_time(:millisecond)

    state =
      cond do
        state.probe == nil ->
          probe(state, now)

        now - state.probe_at > 3 * state.interval ->
          Task.shutdown(state.probe, :brutal_kill)
          probe(%{state | probe: nil}, now)

        true ->
          %{state | skipped: state.skipped + 1}
      end

    %{state | timer: Process.send_after(self(), :tick, state.interval)}
  end

  defp probe(state, now) do
    detector = state.detector

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        try do
          detector.() == true
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      end)

    %{state | probe: task, probe_at: now}
  end
end
