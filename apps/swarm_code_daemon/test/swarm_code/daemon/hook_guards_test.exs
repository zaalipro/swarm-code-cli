defmodule SwarmCode.Daemon.HookGuardsTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.OSProcess

  # The daemon is not a distributed node; `:global` locks must still serialise
  # `spawn_locked/1` against `exclusive_spawn/2` there.
  test "the spawn lock works on the daemon's own node" do
    refute Node.alive?()
    parent = self()

    {:ok, holder} =
      Task.start_link(fn ->
        OSProcess.spawn_locked(fn ->
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 5_000

    # A second taker with no retries left runs anyway (a quit must not hang),
    # but one that can wait gets the lock only after the holder leaves.
    assert OSProcess.exclusive_spawn(0, fn -> :ran end) == :ran

    waiter =
      Task.async(fn ->
        OSProcess.exclusive_spawn(20, fn -> :after_holder end)
      end)

    ref = Process.monitor(holder)
    send(holder, :release)
    assert_receive {:DOWN, ^ref, :process, ^holder, _}, 5_000
    assert Task.await(waiter, 10_000) == :after_holder
    assert OSProcess.spawn_locked(fn -> :free end) == :free
  end

  test "a tracked guardian is registered before guard_port_tracked returns, and leaves with its tree" do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        args: ["-c", "exec sleep 30"]
      ])

    guardian = OSProcess.guard_port_tracked(port)
    assert [{^guardian, os_pid}] = OSProcess.tracked_guards()
    assert is_integer(os_pid)

    ref = Process.monitor(guardian)
    OSProcess.release_guard(guardian)
    assert_receive {:DOWN, ^ref, :process, ^guardian, _}, 5_000
    OSProcess.kill_now([os_pid])
    assert OSProcess.tracked_guards() == []
  end
end
