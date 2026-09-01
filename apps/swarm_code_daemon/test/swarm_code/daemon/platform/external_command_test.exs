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

  test "signal failures are contained and a live requester sees cleanup failure" do
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

    assert Task.await(task) == {:error, :command_cleanup_failed}
    assert_receive {:external_command_signal, ^os_pid, :term}
    assert_receive {:external_command_signal, ^os_pid, :kill}
    refute_receive {:external_command_terminal, ^os_pid}
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}
    assert os_pid_alive?(os_pid)
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
