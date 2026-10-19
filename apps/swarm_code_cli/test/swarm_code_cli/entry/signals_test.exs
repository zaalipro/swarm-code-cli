defmodule SwarmCodeCLI.Release.SignalsTest do
  @moduledoc """
  cli020 B9 (bugs-5): SIGTERM and SIGHUP reach the session owner as
  `{:shutdown_signal, sig}`; the owner runs its normal close (here: a
  one-shot stops its live run) and the process exits 143 or 129.

  pass76 cli-signals-ledger: the close gets the owned shutdown's whole budget
  before the VM is halted, a second signal halts at once, and a real SIGTERM
  or SIGHUP in a real VM lets the owner finish.
  """
  use ExUnit.Case, async: true

  # The watchdog's warning would otherwise land on the console while other
  # async tests capture the VM's standard devices.
  @moduletag :capture_log

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCode.Daemon.Shutdown
  alias SwarmCodeCLI.Release.Signals
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.Request

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  test "the handler tells the owner, and the exit codes are the shell's" do
    assert :ok = Signals.notify(self(), :sigterm)
    assert_receive {:shutdown_signal, :sigterm}
    assert :ok = Signals.notify(self(), :sighup)
    assert_receive {:shutdown_signal, :sighup}
    assert Signals.exit_code(:sigterm) == 143
    assert Signals.exit_code(:sighup) == 129
  end

  test "a one-shot that gets SIGTERM stops its live run and ends with 143", context do
    session = start(context) |> accept() |> run_update(:running)
    # The owner is the process running OneShot.run/1 (the session's caller).
    Signals.notify(session.task.pid, :sigterm)

    assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, run}}}},
                   5_000

    assert run == H.run_id()
    assert code(session) == 143
    assert text(context.error) =~ "ncode: stopped by SIGTERM"
  end

  test "the close's deadline outlasts everything the owned shutdown can take" do
    assert Shutdown.max_ms() > 0
    assert Shutdown.budget_ms() > Shutdown.max_ms()
    assert Signals.deadline_ms() > Shutdown.budget_ms()
    # At least the 60 s a quit was always given.
    assert Signals.deadline_ms() >= 60_000
  end

  describe "the watchdog" do
    defp watch_opts(extra) do
      test = self()
      name = :"signals_test_watchdog_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if watchdog = Process.whereis(name), do: Process.exit(watchdog, :kill)
      end)

      [name: name, halt: fn code, why -> send(test, {:halt, code, why}) end] ++ extra
    end

    test "the first signal tells the owner and halts only at the deadline" do
      opts = watch_opts(deadline_ms: 200, repeat_ms: 60_000)

      assert :ok = Signals.deliver(self(), :sigterm, opts)
      assert_receive {:shutdown_signal, :sigterm}
      refute_receive {:halt, _, _}, 100
      assert_receive {:halt, 143, :deadline}, 2_000
    end

    test "the deadline halt keeps SIGHUP's code" do
      opts = watch_opts(deadline_ms: 50, repeat_ms: 60_000)

      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert_receive {:halt, 129, :deadline}, 2_000
    end

    test "a second signal halts at once with its own code and does not tell the owner again" do
      opts = watch_opts(deadline_ms: 60_000, repeat_ms: 0)

      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert_receive {:shutdown_signal, :sighup}
      refute_receive {:halt, _, _}, 50

      assert :ok = Signals.deliver(self(), :sigterm, opts)
      assert_receive {:halt, 143, :again}, 2_000
      refute_receive {:shutdown_signal, _}, 50
    end

    test "the same signal twice is a second signal: SIGHUP keeps 129" do
      opts = watch_opts(deadline_ms: 60_000, repeat_ms: 0)

      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert_receive {:halt, 129, :again}, 2_000
    end

    test "signals right behind the first are the same event and wait for the deadline" do
      opts = watch_opts(deadline_ms: 300, repeat_ms: 60_000)

      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert :ok = Signals.deliver(self(), :sighup, opts)
      assert :ok = Signals.deliver(self(), :sigterm, opts)
      assert_receive {:shutdown_signal, :sighup}
      refute_receive {:halt, _, :again}, 150
      refute_receive {:shutdown_signal, _}, 10
      assert_receive {:halt, 129, :deadline}, 2_000
    end
  end

  describe "in a real VM" do
    @describetag timeout: 60_000

    # The owner's close takes `close` and then exits the way a session does.
    defp owner_script(install_opts, close) do
      """
      alias SwarmCodeCLI.Release.Signals
      Signals.install(self(), #{install_opts})
      IO.puts("ready")

      receive do
        {:shutdown_signal, signal} ->
          IO.puts("closing")
          #{close}
          IO.puts("closed")
          System.halt(Signals.exit_code(signal))
      end
      """
    end

    defp start_vm(script) do
      elixir = System.find_executable("elixir") || flunk("elixir executable is unavailable")

      port =
        Port.open({:spawn_executable, elixir}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-pa", Application.app_dir(:swarm_code_cli, "ebin"), "-e", script]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      on_exit(fn ->
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      end)

      {port, os_pid}
    end

    defp await_output(port, text, seen \\ "") do
      if seen =~ text do
        seen
      else
        receive do
          {^port, {:data, data}} ->
            await_output(port, text, seen <> data)

          {^port, {:exit_status, status}} ->
            flunk("the VM ended (#{status}) before #{inspect(text)}: #{seen}")
        after
          20_000 -> flunk("no #{inspect(text)} from the VM: #{seen}")
        end
      end
    end

    defp await_exit(port, seen \\ "") do
      receive do
        {^port, {:data, data}} -> await_exit(port, seen <> data)
        {^port, {:exit_status, status}} -> {status, seen}
      after
        20_000 -> flunk("the VM did not end: #{seen}")
      end
    end

    defp send_signal(signal, os_pid),
      do: {_, 0} = System.cmd("/bin/kill", ["-" <> signal, Integer.to_string(os_pid)])

    test "SIGTERM lets the owner finish its close and the VM exits 143" do
      {port, os_pid} = start_vm(owner_script("deadline_ms: 30_000", "Process.sleep(3_000)"))

      await_output(port, "ready")
      send_signal("TERM", os_pid)

      # OTP's own answer to SIGTERM, `init:stop/0`, ends a VM this small with
      # status 0 within a second or two, before "closed".
      assert {143, output} = await_exit(port)
      assert output =~ "closing"
      assert output =~ "closed"
    end

    test "SIGHUP lets the owner finish its close and the VM exits 129" do
      {port, os_pid} = start_vm(owner_script("deadline_ms: 30_000", "Process.sleep(1_000)"))

      await_output(port, "ready")
      send_signal("HUP", os_pid)

      assert {129, output} = await_exit(port)
      assert output =~ "closed"
    end

    test "a close that hangs is halted at the deadline with the signal's code" do
      {port, os_pid} = start_vm(owner_script("deadline_ms: 1_000", "Process.sleep(:infinity)"))

      await_output(port, "ready")
      send_signal("HUP", os_pid)

      assert {129, output} = await_exit(port)
      assert output =~ "closing"
      refute output =~ "closed"
    end

    test "a second signal halts a hanging close at once" do
      {port, os_pid} =
        start_vm(owner_script("deadline_ms: 600_000, repeat_ms: 0", "Process.sleep(:infinity)"))

      await_output(port, "ready")
      send_signal("TERM", os_pid)
      await_output(port, "closing")
      send_signal("TERM", os_pid)

      assert {143, output} = await_exit(port)
      refute output =~ "closed"
    end
  end
end
