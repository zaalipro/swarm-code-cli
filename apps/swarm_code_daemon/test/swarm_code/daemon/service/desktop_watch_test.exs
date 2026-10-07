defmodule SwarmCode.Daemon.Service.DesktopWatchTest do
  @moduledoc "cli020 C4 (bugs-6): the desktop opening mid-session is noticed once."
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.DesktopWatch

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  defp detector(answers) do
    {:ok, agent} = Agent.start_link(fn -> answers end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)
    end
  end

  test "false then true sends one delta", c do
    watch =
      start_supervised!(
        {DesktopWatch,
         subscriber: self(),
         detector: detector([false, false, true]),
         interval_ms: 20,
         task_supervisor: c.supervisor}
      )

    assert_receive {:desktop_running, true}, 2_000
    refute_receive {:desktop_running, _}, 200
    assert DesktopWatch.running?(watch)
  end

  test "a probe that hangs past the interval does not block the next tick", c do
    test = self()

    hang = fn ->
      send(test, {:probe, self()})

      receive do
        :never -> true
      end
    end

    watch =
      start_supervised!(
        {DesktopWatch,
         subscriber: self(), detector: hang, interval_ms: 20, task_supervisor: c.supervisor}
      )

    assert_receive {:probe, first}, 1_000
    first_ref = Process.monitor(first)
    # The server answers while its probe hangs, and the ticks after it are
    # skipped rather than queued behind it.
    assert eventually(fn -> GenServer.call(watch, :stats).skipped >= 2 end)
    refute DesktopWatch.running?(watch)
    # Past three intervals the hung probe is killed and a new one runs.
    assert_receive {:probe, second}, 2_000
    assert second != first
    assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 1_000
  end

  test "the watch stops with its subscriber and kills its probe", c do
    test = self()
    subscriber = spawn(fn -> receive(do: (:never -> :ok)) end)

    hang = fn ->
      send(test, {:probe, self()})
      receive(do: (:never -> true))
    end

    {:ok, watch} =
      DesktopWatch.start_link(
        subscriber: subscriber,
        detector: hang,
        interval_ms: 1_000,
        task_supervisor: c.supervisor
      )

    Process.unlink(watch)
    ref = Process.monitor(watch)
    assert_receive {:probe, probe}, 1_000
    probe_ref = Process.monitor(probe)
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^ref, :process, ^watch, :normal}, 1_000
    assert_receive {:DOWN, ^probe_ref, :process, ^probe, _}, 1_000
  end

  defp eventually(fun, n \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    if fun.() do
      true
    else
      receive do
      after
        20 -> eventually(fun, n - 1)
      end
    end
  end
end
