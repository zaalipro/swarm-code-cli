defmodule SwarmCode.Domain.OSProcess do
  @moduledoc """
  Termination of an external process **and its descendants**.

  Sakana tasks 10/17: killing only the pid behind a `Port` leaves the real work
  running whenever the command is a wrapper — `npx`, `uvx`, `sh -c`, `git` with
  a pager. macOS does not ship `setsid`, so the tree is walked explicitly,
  signalled `TERM`, given a short grace period and then `KILL`ed. Every step
  degrades to a no-op when the helper binaries are missing, and the BEAM's own
  process group is never signalled.

  Spec 43 §1.6: the walk is one `ps` snapshot of every process (pid, ppid)
  filtered in memory, and the grace period polls the survivors with one `ps`
  per step — it used to be a `pgrep` per pid per level and a `kill -0` per pid
  every 25 ms, dozens of subprocesses per stop.
  """

  # spec 60 T16: the walk rejects revisits (`descendants/4`), so the cap is a courtesy, not a guard.
  @max_depth 64
  @grace_ms 500
  @poll_ms 50

  @doc """
  Terminates `os_pid` and every descendant. Returns `:ok` even when nothing was
  running — cancellation must never crash its caller.
  """
  @spec kill_tree(pos_integer() | nil) :: :ok
  def kill_tree(nil), do: :ok

  def kill_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if os_pid == self_pid() do
      :ok
    else
      # Leaves first: a parent that outlives its children can still be walked
      # for anything it forked between the snapshot and the signal.
      pids = tree(os_pid)
      signal(Enum.reverse(pids), "TERM")
      survivors = wait_gone(pids, System.monotonic_time(:millisecond) + @grace_ms)

      # Re-walk every pid that is still alive; a child started between the two
      # steps would otherwise be orphaned and keep running.
      late = if survivors == [], do: [], else: tree_of(survivors, snapshot())
      signal(Enum.reverse(Enum.uniq(survivors ++ late)), "KILL")
      :ok
    end
  end

  def kill_tree(_other), do: :ok

  @doc "The port's OS pid, or nil when the port is already gone."
  @spec port_pid(port() | nil) :: pos_integer() | nil
  def port_pid(nil), do: nil

  def port_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def port_pid(_other), do: nil

  @doc "`os_pid` and its descendants, deepest last, bounded to a depth of 64."
  @spec tree(pos_integer()) :: [pos_integer()]
  def tree(os_pid), do: tree_of([os_pid], snapshot())

  # `roots` and their descendants from one snapshot, deepest last; a root that
  # is itself a descendant of another is listed once.
  @doc false
  def tree_of(roots, children_by_parent) do
    Enum.uniq(roots ++ descendants(roots, @max_depth, [], children_by_parent))
  end

  defp descendants([], _depth, acc, _children), do: Enum.reverse(acc)
  defp descendants(_level, 0, acc, _children), do: Enum.reverse(acc)

  defp descendants(level, depth, acc, children) do
    next =
      level
      |> Enum.flat_map(&Map.get(children, &1, []))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in acc or &1 in level))

    descendants(next, depth - 1, Enum.reverse(next) ++ acc, children)
  end

  # `%{ppid => [pid]}` for every process on the machine, from one `ps`.
  defp snapshot do
    case run("ps", ["-Ao", "pid=,ppid="]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case line |> String.trim() |> String.split(~r/\s+/, parts: 2) do
            [pid, ppid] ->
              with {pid, ""} when pid > 1 <- Integer.parse(pid),
                   {ppid, ""} <- Integer.parse(ppid) do
                Map.update(acc, ppid, [pid], &[pid | &1])
              else
                _ -> acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc "True while the OS process exists."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid), do: living([os_pid]) == [os_pid]

  # The subset of `pids` that still exists — one `ps` for all of them.
  defp living([]), do: []

  defp living(pids) do
    case run("ps", ["-o", "pid=", "-p", Enum.map_join(pids, ",", &Integer.to_string/1)]) do
      {out, _status} ->
        alive =
          out
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(fn text ->
            case Integer.parse(text) do
              {pid, ""} -> [pid]
              _ -> []
            end
          end)
          |> MapSet.new()

        Enum.filter(pids, &MapSet.member?(alive, &1))
    end
  end

  defp signal([], _name), do: :ok

  defp signal(pids, name) do
    args = ["-" <> name | Enum.map(pids, &Integer.to_string/1)]
    run("kill", args)
    :ok
  end

  defp wait_gone(pids, deadline) do
    survivors = living(pids)

    cond do
      survivors == [] -> []
      System.monotonic_time(:millisecond) >= deadline -> survivors
      true -> Process.sleep(@poll_ms) && wait_gone(survivors, deadline)
    end
  end

  defp run(command, args) do
    case System.find_executable(command) do
      nil -> {"", 1}
      path -> System.cmd(path, args, stderr_to_stdout: true)
    end
  rescue
    _ -> {"", 1}
  end

  defp self_pid do
    case Integer.parse(System.pid()) do
      {pid, _} -> pid
      :error -> -1
    end
  end
end
