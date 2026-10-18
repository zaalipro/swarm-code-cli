defmodule SwarmCode.Daemon.Service.RunProcessesTest do
  @moduledoc """
  A run's row can read `done` while its server process is still finishing
  (a workflow's starts its continuation first); `alive?/1` is what a headless
  `-p` asks before it concludes.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.RunProcesses

  defp register(run_id) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        {:ok, _} =
          Registry.register(SwarmCode.Domain.Registry, {:run, run_id}, {"conversation", "chat"})

        send(test, {:registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :finish) end)
    pid
  end

  test "is true while the run's server process runs and false once it has ended" do
    run_id = Ecto.UUID.generate()
    pid = register(run_id)
    assert RunProcesses.alive?(run_id)

    monitor = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}

    # The registry may still list the dead pid for a moment; it does not count.
    refute RunProcesses.alive?(run_id)
  end

  test "is false for a run nothing is registered for, and for a non-id" do
    refute RunProcesses.alive?(Ecto.UUID.generate())
    refute RunProcesses.alive?(nil)
    refute RunProcesses.alive?(:run)
  end
end
