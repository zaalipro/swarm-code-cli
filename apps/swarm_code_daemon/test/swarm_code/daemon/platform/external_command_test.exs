defmodule SwarmCode.Daemon.Platform.ExternalCommandTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Platform.ExternalCommand

  test "normal and nonzero exits report exact child termination" do
    for {executable, args, expected} <- [
          {"/bin/echo", ["bounded-output"], {:ok, "bounded-output"}},
          {"/usr/bin/false", [], {:error, :command_failed}}
        ] do
      assert ExternalCommand.run(executable, args,
               timeout: 1_000,
               max_line_bytes: 1_024,
               observer: self()
             ) == expected

      assert_receive {:external_command_started, _owner, os_pid}
      assert_receive {:external_command_terminal, ^os_pid}
      refute os_pid_alive?(os_pid)
    end
  end

  test "child exit before PID lookup preserves output and exact terminal evidence" do
    test = self()

    for {executable, args, expected} <- [
          {"/bin/echo", ["bounded-output"], {:ok, "bounded-output"}},
          {"/usr/bin/false", [], {:error, :command_failed}}
        ],
        evidence_order <- [:exit_first, :eof_first] do
      assert ExternalCommand.run(executable, args,
               observer: test,
               test_after_port_open: fn port ->
                 messages = await_open_child_exit!(port)

                 messages
                 |> Enum.sort_by(fn
                   {^port, {:exit_status, _}} -> evidence_order != :exit_first
                   _other -> evidence_order == :exit_first
                 end)
                 |> Enum.each(&send(self(), &1))

                 send(test, {:exited_before_pid_lookup, port})
               end
             ) == expected

      assert_receive {:exited_before_pid_lookup, port}
      assert_receive {:external_command_started, _owner, os_pid}
      assert_receive {:external_command_terminal, ^os_pid}
      refute_receive {:external_command_signal, ^os_pid, _signal}
      assert Port.info(port) == nil
      refute os_pid_alive?(os_pid)
    end
  end

  test "known child exit suppresses PID signals while output EOF is pending" do
    test = self()

    assert {:error, :command_cleanup_pending} =
             ExternalCommand.run("/bin/echo", ["bounded-output"],
               observer: test,
               terminate_grace: 10,
               kill_grace: 10,
               test_fail_after_port_open: true,
               test_after_port_open: fn port ->
                 # Delay only the real EOF event; the real child exit remains
                 # queued for cleanup, and must prevent any stale PID signal.
                 receive do
                   {^port, :eof} -> :ok
                 after
                   1_000 -> flunk("child output did not close")
                 end

                 receive do
                   {^port, {:exit_status, _status}} = message -> send(self(), message)
                 after
                   1_000 -> flunk("child did not exit")
                 end

                 send(test, {:withheld_output_eof, port})
               end
             )

    assert_receive {:withheld_output_eof, port}
    assert_receive {:external_command_started, owner, os_pid}
    owner_monitor = Process.monitor(owner)
    refute os_pid_alive?(os_pid)
    refute_receive {:external_command_signal, ^os_pid, _signal}
    refute_receive {:external_command_terminal, ^os_pid}
    assert Process.alive?(owner)

    send(owner, {port, :eof})
    assert_receive {:external_command_terminal, ^os_pid}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    assert Port.info(port) == nil
  end

  test "observer protocol accepts only a nonblocking process destination" do
    callback = fn _event -> :ok end

    assert {:error, :invalid_command} =
             ExternalCommand.run("/bin/echo", ["unused"],
               timeout: 1_000,
               observer: callback
             )
  end

  test "timeout sends TERM then bounded KILL and awaits exact terminal evidence" do
    assert {:error, :command_timeout} =
             ExternalCommand.run(
               "/bin/sh",
               ["-c", "trap '' TERM; while :; do :; done"],
               timeout: 50,
               terminate_grace: 50,
               kill_grace: 1_000,
               max_line_bytes: 1_024,
               observer: self()
             )

    assert_receive {:external_command_started, _owner, os_pid}
    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_signal, ^os_pid, :kill}
    assert_receive {:external_command_terminal, ^os_pid}
    refute os_pid_alive?(os_pid)
  end

  test "signal failure keeps the exact reaper alive until terminal Port and PID evidence" do
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ExternalCommand.run("/bin/sleep", ["60"],
          timeout: 20,
          terminate_grace: 20,
          kill_grace: 20,
          max_line_bytes: 1_024,
          observer: test,
          test_signal_executable: "/definitely/missing/swarm-code-kill"
        )
      end)

    assert_receive {:external_command_started, owner, os_pid}
    owner_monitor = Process.monitor(owner)
    on_exit(fn -> terminate_os_pid(os_pid) end)

    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_signal, ^os_pid, :kill}
    assert {:ok, {:error, :command_cleanup_pending}} = result = Task.yield(task, 5_000)
    assert os_pid_alive?(os_pid)

    terminate_os_pid(os_pid)

    assert result == {:ok, {:error, :command_cleanup_pending}}
    assert_receive {:external_command_terminal, ^os_pid}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    refute os_pid_alive?(os_pid)
  end

  test "queued terminal evidence at the cleanup boundary suppresses stale PID signals" do
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ExternalCommand.run("/bin/sleep", ["0.05"],
          timeout: 10,
          terminate_grace: 20,
          kill_grace: 20,
          max_line_bytes: 1_024,
          observer: test,
          test_before_terminate: fn owner ->
            send(test, {:external_command_cleanup_boundary, owner})

            receive do
              {:continue_external_command_cleanup, ^owner} -> :ok
            end
          end
        )
      end)

    assert_receive {:external_command_started, owner, os_pid}
    assert_receive {:external_command_cleanup_boundary, ^owner}
    await_os_pid_dead!(os_pid)
    send(owner, {:continue_external_command_cleanup, owner})

    assert Task.await(task) == {:error, :command_timeout}
    assert_receive {:external_command_terminal, ^os_pid}
    refute_receive {:external_command_signal, ^os_pid, _signal}
  end

  test "requester death terminates and reaps the exact command child" do
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ExternalCommand.run("/bin/sleep", ["60"],
          timeout: 60_000,
          terminate_grace: 100,
          kill_grace: 1_000,
          max_line_bytes: 1_024,
          observer: test
        )
      end)

    assert_receive {:external_command_started, owner, os_pid}
    owner_monitor = Process.monitor(owner)
    assert Task.shutdown(task, :brutal_kill) == nil
    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_terminal, ^os_pid}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    refute os_pid_alive?(os_pid)
  end

  test "requester death escalates a TERM-resistant exact child to bounded KILL" do
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        ExternalCommand.run(
          "/bin/sh",
          ["-c", "trap '' TERM; kill -STOP $$; while :; do :; done"],
          timeout: 60_000,
          terminate_grace: 50,
          kill_grace: 1_000,
          max_line_bytes: 1_024,
          observer: test
        )
      end)

    assert_receive {:external_command_started, owner, os_pid}
    await_os_pid_stopped!(os_pid)
    owner_monitor = Process.monitor(owner)
    assert Task.shutdown(task, :brutal_kill) == nil
    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_signal, ^os_pid, :kill}
    assert_receive {:external_command_terminal, ^os_pid}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    refute os_pid_alive?(os_pid)
  end

  test "invalid live output is an error that TERM then KILL reaps before the deadline" do
    assert {:error, :command_failed} =
             ExternalCommand.run(
               "/bin/sh",
               [
                 "-c",
                 "trap '' TERM; printf '0123456789abcdef'; kill -STOP $$; while :; do :; done"
               ],
               timeout: 5_000,
               terminate_grace: 50,
               kill_grace: 1_000,
               max_line_bytes: 8,
               observer: self()
             )

    assert_receive {:external_command_started, _owner, os_pid}
    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_signal, ^os_pid, :kill}
    assert_receive {:external_command_terminal, ^os_pid}
    refute os_pid_alive?(os_pid)
  end

  test "failure after Port open TERM then KILL reaps the registered exact child" do
    assert {:error, :command_start_failed} =
             ExternalCommand.run("/bin/sleep", ["60"],
               timeout: 5_000,
               terminate_grace: 50,
               kill_grace: 1_000,
               observer: self(),
               test_fail_after_port_open: true
             )

    assert_receive {:external_command_started, _owner, os_pid}
    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_terminal, ^os_pid}
    refute os_pid_alive?(os_pid)
  end

  # Leave real Port evidence queued, but hold the owner before its PID lookup
  # until the child has exited and the driver has delivered EOF or closed.
  defp await_open_child_exit!(port, exit? \\ false, ended? \\ false, messages \\ [])

  defp await_open_child_exit!(_port, true, true, messages) do
    Enum.reverse(messages)
  end

  defp await_open_child_exit!(port, exit?, ended?, messages) do
    receive do
      {^port, {:exit_status, _status}} = message ->
        await_open_child_exit!(port, true, ended?, [message | messages])

      {^port, :eof} = message ->
        await_open_child_exit!(port, exit?, true, [message | messages])

      {:DOWN, _monitor, :port, ^port, _reason} = message ->
        await_open_child_exit!(port, exit?, true, [message | messages])
    after
      1_000 -> flunk("child did not exit before PID lookup")
    end
  end

  defp os_pid_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp terminate_os_pid(pid) do
    _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    await_os_pid_dead!(pid)
  end

  defp await_os_pid_dead!(pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_await_os_pid_dead!(pid, deadline)
  end

  defp await_os_pid_stopped!(pid) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_await_os_pid_stopped!(pid, deadline)
  end

  defp do_await_os_pid_stopped!(pid, deadline) do
    {state, status} =
      System.cmd("/bin/ps", ["-o", "state=", "-p", Integer.to_string(pid)],
        stderr_to_stdout: true
      )

    cond do
      status == 0 and String.starts_with?(String.trim(state), "T") ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("OS process #{pid} did not enter the stopped state")

      true ->
        receive do
        after
          1 -> do_await_os_pid_stopped!(pid, deadline)
        end
    end
  end

  defp do_await_os_pid_dead!(pid, deadline) do
    cond do
      not os_pid_alive?(pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("OS process #{pid} did not reach terminal state")

      true ->
        receive do
        after
          1 -> do_await_os_pid_dead!(pid, deadline)
        end
    end
  end
end
