defmodule SwarmCode.Daemon.Service.Settings.ProbeRunner do
  @moduledoc """
  Runs a settings task that starts external processes (an MCP stdio probe,
  pass 74 §3.3.8 rules 3 and 8) so that stopping it leaves no OS process: the
  task's work runs in a child linked to the task, and `stop/1` reads the OS pid
  of every port linked to that child (and to the processes linked to it), kills
  the child and then the OS process trees.
  """

  alias SwarmCode.Domain.OSProcess

  @stop_wait 2_000

  @doc "Start `run.(report)` under `supervisor`; returns the `Task`."
  @spec start(GenServer.server(), (function() -> term()), (map() -> :ok)) :: Task.t()
  def start(supervisor, run, report) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      Process.flag(:trap_exit, true)
      owner = self()
      child = spawn_link(fn -> send(owner, {:probe_result, self(), run.(report)}) end)
      wait(child)
    end)
  end

  defp wait(child) do
    receive do
      {:probe_result, ^child, result} ->
        result

      {:probe_stop, from, ref} ->
        reap(child)
        send(from, {:probe_stopped, ref})
        exit(:shutdown)

      {:EXIT, ^child, :normal} ->
        wait(child)

      {:EXIT, ^child, _reason} ->
        {:error, "the check stopped without an answer"}

      {:EXIT, _other, reason} ->
        reap(child)
        exit(reason)
    end
  end

  @doc "Stop a probe task: its OS processes first, then the task."
  @spec stop(Task.t()) :: :ok
  def stop(%Task{pid: pid} = task) do
    ref = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:probe_stop, self(), ref})

    receive do
      {:probe_stopped, ^ref} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @stop_wait -> :ok
    end

    Process.demonitor(monitor, [:flush])
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  @doc false
  @spec reap(pid()) :: :ok
  def reap(child) do
    os_pids = child |> ports(2) |> Enum.flat_map(&os_pid/1) |> Enum.uniq()
    Process.exit(child, :kill)
    Enum.each(os_pids, &OSProcess.kill_tree/1)
    :ok
  end

  # The ports linked to `pid` and to the processes linked to it (depth levels).
  defp ports(pid, depth) do
    links =
      case Process.info(pid, :links) do
        {:links, links} -> links
        _ -> []
      end

    {ports, pids} = Enum.split_with(links, &is_port/1)

    nested =
      if depth > 1,
        do: pids |> Enum.reject(&(&1 == self())) |> Enum.flat_map(&ports(&1, depth - 1)),
        else: []

    ports ++ nested
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> [os_pid]
      _ -> []
    end
  end
end
