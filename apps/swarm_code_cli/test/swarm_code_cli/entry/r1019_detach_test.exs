defmodule SwarmCodeCLI.Release.R1019DetachTest do
  @moduledoc """
  pass 77 C-FEAT-3: a hang-up with live runs keeps them going until none is
  progressing. DB-free: the registry and the waits are injected.
  """
  use ExUnit.Case, async: true

  # The watchdog's warning would otherwise land on the console while other
  # async tests capture the VM's standard devices.
  @moduletag :capture_log

  alias SwarmCodeCLI.Release.{Detach, Signals}

  describe "progressing?/2" do
    test "a live run that waits for a person is not progressing" do
      refute Detach.progressing?(["a", "b"], ["a", "b"])
      refute Detach.progressing?(["a"], ["a", "elsewhere"])
    end

    test "one free live run is enough" do
      assert Detach.progressing?(["a", "b"], ["a"])
      assert Detach.progressing?(["a"], [])
    end

    test "no live run is nothing to wait for" do
      refute Detach.progressing?([], [])
      refute Detach.progressing?([], ["a"])
    end
  end

  describe "await/1" do
    test "returns once nothing is progressing any more" do
      {:ok, flag} = Agent.start_link(fn -> true end)
      test = self()

      task =
        Task.async(fn ->
          Detach.await(
            progressing?: fn ->
              send(test, :checked)
              Agent.get(flag, & &1)
            end,
            count: fn -> 1 end,
            recheck_ms: 10
          )
        end)

      # It checks, finds a run progressing, and keeps waiting.
      assert_receive :checked, 1_000
      assert_receive :checked, 1_000
      assert Task.yield(task, 0) == nil

      Agent.update(flag, fn _ -> false end)
      assert Task.await(task, 5_000) == :settled
    end

    test "returns at once when nothing is progressing" do
      assert Detach.await(progressing?: fn -> false end, count: fn -> 0 end) == :settled
    end

    test "wakes on a run's status change instead of waiting for the recheck" do
      {:ok, flag} = Agent.start_link(fn -> true end)

      task =
        Task.async(fn ->
          Detach.await(
            progressing?: fn -> Agent.get(flag, & &1) end,
            count: fn -> 1 end,
            recheck_ms: 60_000
          )
        end)

      Agent.update(flag, fn _ -> false end)
      send(task.pid, {:run_lifecycle, "conversation", "done"})
      assert Task.await(task, 5_000) == :settled
    end
  end

  describe "the close deadline" do
    defp watch_opts(extra) do
      test = self()
      name = :"r1019_detach_watchdog_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if watchdog = Process.whereis(name), do: Process.exit(watchdog, :kill)
      end)

      [name: name, halt: fn code, why -> send(test, {:halt, code, why}) end] ++ extra
    end

    test "is held while a detached session finishes, and starts afresh after" do
      opts = watch_opts(deadline_ms: 40, repeat_ms: 10_000)
      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert_receive {:shutdown_signal, :sighup}

      assert :ok = Signals.hold_deadline(opts[:name])
      refute_receive {:halt, _, _}, 150

      assert :ok = Signals.release_deadline(opts[:name])
      assert_receive {:halt, 129, :deadline}, 2_000
    end

    test "holding with no signal delivered is a no-op" do
      assert :ok = Signals.hold_deadline(:r1019_no_such_watchdog)
      assert :ok = Signals.release_deadline(:r1019_no_such_watchdog)
    end

    test "a second signal still halts a held close at once" do
      opts = watch_opts(deadline_ms: 60_000, repeat_ms: 0)
      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert :ok = Signals.hold_deadline(opts[:name])
      assert :ok = Signals.deliver(self(), :sigterm, opts)
      assert_receive {:halt, 143, :again}, 2_000
    end
  end

  describe "the words" do
    test "a hang-up that let the runs finish says so; one that stopped them keeps the old words" do
      assert Signals.words(:sighup, true) == "the terminal closed; the live runs finished first."
      assert Signals.words(:sighup) =~ "stopped by SIGHUP (the terminal closed)"
      assert Signals.words(:sighup, false) == Signals.words(:sighup)
      assert Signals.words(:sigterm, true) == Signals.words(:sigterm)
    end
  end
end
