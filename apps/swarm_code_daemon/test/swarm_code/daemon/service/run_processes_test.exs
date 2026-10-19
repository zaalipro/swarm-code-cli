defmodule SwarmCode.Daemon.Service.RunProcessesTest do
  @moduledoc """
  A run's row can read `done` while the run still has a launch to make: its
  server process is finishing (a workflow's starts its continuation first), or
  the continuation was handed to a chain task that waits for a compaction.
  `pending?/1` is what a headless `-p` asks before it concludes.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.RunProcesses

  defp register(key, value) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        {:ok, _} = Registry.register(SwarmCode.Domain.Registry, key, value)

        send(test, {:registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :finish) end)
    pid
  end

  defp register(run_id), do: register({:run, run_id}, {"conversation", "chat"})

  defp finish(pid) do
    monitor = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
  end

  test "is true while the run's server process runs and false once it has ended" do
    run_id = Ecto.UUID.generate()
    pid = register(run_id)
    assert RunProcesses.alive?(run_id)
    assert RunProcesses.pending?(run_id)

    finish(pid)

    # The registry may still list the dead pid for a moment; it does not count.
    refute RunProcesses.alive?(run_id)
    refute RunProcesses.pending?(run_id)
  end

  test "is false for a run nothing is registered for, and for a non-id" do
    refute RunProcesses.alive?(Ecto.UUID.generate())
    refute RunProcesses.alive?(nil)
    refute RunProcesses.alive?(:run)
    refute RunProcesses.pending?(Ecto.UUID.generate())
    refute RunProcesses.pending?(nil)
    refute RunProcesses.chained?(:run)
  end

  describe "a turn chained onto a compaction on behalf of a run" do
    test "is pending for that run while the chain task lives, with no server of its own" do
      owner = Ecto.UUID.generate()
      chain = register({:chain, Ecto.UUID.generate(), Ecto.UUID.generate()}, owner)

      refute RunProcesses.alive?(owner)
      assert RunProcesses.chained?(owner)
      assert RunProcesses.pending?(owner)

      finish(chain)
      refute RunProcesses.chained?(owner)
      refute RunProcesses.pending?(owner)
    end

    test "is not pending for another run, or for a user's own send (no owner)" do
      owner = Ecto.UUID.generate()
      compaction = Ecto.UUID.generate()
      register({:chain, Ecto.UUID.generate(), compaction}, owner)
      register({:chain, Ecto.UUID.generate(), Ecto.UUID.generate()}, nil)

      refute RunProcesses.pending?(Ecto.UUID.generate())
      refute RunProcesses.pending?(compaction)
      refute RunProcesses.chained?(nil)
    end
  end
end
