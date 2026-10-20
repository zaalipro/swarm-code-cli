defmodule SwarmCode.Daemon.R1019SessionEndReapTest do
  @moduledoc """
  Pass 77 X-1: a `session_end` hook that ignores TERM is still inside its
  tree's TERM / grace / KILL sweep when its cap and grace pass. The quit used
  to brutally kill that task and return, leaving the sweep to a guardian the
  VM halt then cut. It now gives the task the reap wait, stops what is left
  under the hooks' spawn lock, joins the guardians under one deadline and KILLs
  the trees still running, so no hook process outlives `Shutdown.run/1`.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias SwarmCode.Daemon.Shutdown
  alias SwarmCode.Domain.{Projects, Repo}

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})

    unless Process.whereis(SwarmCode.Domain.Hooks.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor})

    root = Path.join(System.tmp_dir!(), "session-end-reap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".swarm_code"))
    pid_file = Path.join(root, "hook.pid")

    on_exit(fn ->
      with {:ok, text} <- File.read(pid_file),
           {pid, _} <- Integer.parse(String.trim(text)) do
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      File.rm_rf!(root)
    end)

    %{root: root, pid_file: pid_file}
  end

  defp hook_project(c, command) do
    File.write!(
      Path.join(c.root, ".swarm_code/config.json"),
      Jason.encode!(%{"hooks" => %{"session_end" => [%{"command" => command}]}})
    )

    {:ok, project} = Projects.create(%{name: "Reap", root_path: c.root})
    {:ok, project} = Projects.trust(project)
    {:ok, _} = Projects.touch(project)
  end

  # `kill -0` also succeeds for a zombie that its parent has not reaped yet.
  defp running?(os_pid) do
    case System.cmd("/bin/ps", ["-o", "stat=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} -> not String.starts_with?(String.trim(out), "Z")
      _gone -> false
    end
  end

  test "a hook that ignores TERM is gone when the quit returns", c do
    hook_project(c, "trap '' TERM; echo $$ > '#{c.pid_file}'; sleep 120")

    # The cap and the later phases are cut short so that the task is still
    # inside its tree's sweep when the quit stops it: the join is what ends it.
    Shutdown.run(
      teardown: false,
      flush_ms: 0,
      cleanup_ms: 0,
      session_end_ms: 300,
      session_end_grace_ms: 0,
      session_end_reap_ms: 0
    )

    {os_pid, _} = c.pid_file |> File.read!() |> String.trim() |> Integer.parse()
    refute running?(os_pid)
    assert SwarmCode.Domain.OSProcess.tracked_guards() == []
  end

  test "a guardian that is not done by the final deadline has its tree KILLed by pid", c do
    hook_project(c, "trap '' TERM; echo $$ > '#{c.pid_file}'; sleep 120")

    Shutdown.run(
      teardown: false,
      flush_ms: 0,
      cleanup_ms: 0,
      session_end_ms: 300,
      session_end_grace_ms: 0,
      session_end_reap_ms: 0,
      session_end_final_ms: 0
    )

    {os_pid, _} = c.pid_file |> File.read!() |> String.trim() |> Integer.parse()
    assert eventually_gone(os_pid)
  end

  test "a hook that ends within its cap needs no join and leaves nothing running", c do
    hook_project(c, "echo $$ > '#{c.pid_file}'")

    Shutdown.run(teardown: false, flush_ms: 0, cleanup_ms: 0, session_end_ms: 2_000)

    {os_pid, _} = c.pid_file |> File.read!() |> String.trim() |> Integer.parse()
    refute running?(os_pid)
  end

  # `kill -KILL` is asynchronous at the OS level.
  defp eventually_gone(os_pid, attempts \\ 200) do
    cond do
      not running?(os_pid) ->
        true

      attempts == 0 ->
        false

      true ->
        receive do
        after
          20 -> eventually_gone(os_pid, attempts - 1)
        end
    end
  end
end
