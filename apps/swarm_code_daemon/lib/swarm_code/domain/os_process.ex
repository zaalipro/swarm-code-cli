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
  # ncode p4: rounds of `sweep_group/4` at most (a fork bomb outruns any number).
  @sweep_rounds 16
  # ncode p4 final review: and no round starts this long after the sweep began.
  # Each round is two synchronous helper calls (`ps`, `kill`), which under load
  # take seconds; the callers that stop an LSP, MCP server or hook wait for it.
  @sweep_ms 2_000

  @doc """
  Terminates `os_pid` and every descendant. Returns `:ok` even when nothing was
  running — cancellation must never crash its caller.

  When `os_pid` leads its own process group (a port's shell does), members of
  that group born while the kill ran are killed too (`sweep_group/4`).
  """
  @spec kill_tree(pos_integer() | nil) :: :ok
  def kill_tree(nil), do: :ok

  def kill_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    if os_pid == self_pid() do
      :ok
    else
      # Leaves first: a parent that outlives its children can still be walked
      # for anything it forked between the snapshot and the signal.
      first = snapshot()
      pids = tree_of([os_pid], first.children)
      signal(Enum.reverse(pids), "TERM")
      survivors = wait_gone(pids, System.monotonic_time(:millisecond) + @grace_ms)

      # Re-walk every pid that is still alive; a child started between the two
      # steps would otherwise be orphaned and keep running.
      late = if survivors == [], do: [], else: tree_of(survivors, snapshot().children)
      killed = Enum.uniq(survivors ++ late)
      signal(Enum.reverse(killed), "KILL")

      if leads_own_group?(first, os_pid),
        do:
          sweep_group(
            os_pid,
            first,
            MapSet.new(pids ++ killed),
            @sweep_rounds,
            System.monotonic_time(:millisecond) + @sweep_ms
          )

      :ok
    end
  end

  def kill_tree(_other), do: :ok

  @doc """
  Runs `executable args` through a Port with a deadline and a byte bound
  enforced while reading (spec 74 ARCHITECTURE-19): the one bounded runner
  for `rg`, `gh`, `df`, `du` and friends, which ran through `System.cmd/3`
  with neither.

  Options:

    * `:cd` — working directory; `:env` — `[{name, value | false}]`;
    * `:timeout` — ms (default 60 000); past it the tree is killed
      (`kill_tree/1`) and the result is `{:error, :timeout}`;
    * `:max_bytes` — the output kept (default 10 MB). `on_cap: :kill`
      (default) kills the tree at the bound and returns what was kept;
      `on_cap: :drain` keeps reading (and dropping) until the exit;
    * `:stderr_to_stdout` — default `true`;
    * `:on_line` — `{fun, acc}`: the output is folded line by line
      (`fun.(line, acc)` returns the new acc, or `{:halt, acc}` to stop and
      kill the tree) and the acc is returned instead of the output; a line
      is at most `max_bytes` long.

  Returns `{:ok, status, output_or_acc, cut?}` (`status` is `nil` when the
  runner stopped the process itself — a cap or a halt), `{:error, :timeout}`,
  or `{:error, reason}` when it could not start.
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, non_neg_integer() | nil, term(), boolean()}
          | {:error, :timeout}
          | {:error, term()}
  def run(executable, args, opts \\ []) do
    path =
      if String.contains?(executable, "/"),
        do: executable,
        else: System.find_executable(executable)

    if is_nil(path) or not File.exists?(path) do
      {:error, {:not_found, executable}}
    else
      line_fold = opts[:on_line]

      port_opts =
        [:binary, :exit_status, args: args] ++
          if(opts[:stderr_to_stdout] == false, do: [], else: [:stderr_to_stdout]) ++
          if(opts[:cd], do: [cd: String.to_charlist(opts[:cd])], else: []) ++
          if(opts[:env], do: [env: port_env(opts[:env])], else: [])

      port = Port.open({:spawn_executable, path}, port_opts)
      deadline = System.monotonic_time(:millisecond) + (opts[:timeout] || 60_000)

      state = %{
        port: port,
        deadline: deadline,
        max: opts[:max_bytes] || 10 * 1024 * 1024,
        on_cap: opts[:on_cap] || :kill,
        fold: line_fold,
        acc: if(line_fold, do: elem(line_fold, 1), else: []),
        partial: [],
        partial_bytes: 0,
        bytes: 0,
        cut?: false
      }

      collect_run(state)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp port_env(env) do
    for {k, v} <- env do
      {to_charlist(k), if(v in [false, nil], do: false, else: to_charlist(v))}
    end
  end

  defp collect_run(%{port: port} = state) do
    remaining = max(state.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case take(state, data) do
          {:cont, state} -> collect_run(state)
          {:stop, state} -> stop_run(state)
        end

      {^port, {:exit_status, status}} ->
        {:ok, status, run_result(flush_partial(state)), state.cut?}
    after
      remaining ->
        close_run(port)
        {:error, :timeout}
    end
  end

  # Plain output: keep up to `max`, then kill or drain.
  defp take(%{fold: nil} = state, data) do
    keep = min(byte_size(data), max(state.max - state.bytes, 0))
    acc = if keep > 0, do: [binary_part(data, 0, keep) | state.acc], else: state.acc
    cut? = state.cut? or keep < byte_size(data)
    state = %{state | acc: acc, bytes: state.bytes + keep, cut?: cut?}
    if cut? and state.on_cap == :kill, do: {:stop, state}, else: {:cont, state}
  end

  # Line mode: the chunks are split here, not by the port's `{:line, N}` mode —
  # a message per line floods the mailbox with heap copies, while a chunk is
  # one off-heap binary. The unfinished line is iodata (bounded by `max`).
  defp take(state, data) do
    case :binary.split(data, "\n", [:global]) do
      [partial] ->
        {:cont, add_partial(state, partial)}

      [first | rest] ->
        {last, full} = List.pop_at(rest, -1)
        state = add_partial(state, first)
        line = IO.iodata_to_binary(state.partial)
        state = %{state | partial: [], partial_bytes: 0}

        case fold_lines(state, [line | full]) do
          {:cont, state} -> {:cont, add_partial(state, last)}
          stop -> stop
        end
    end
  end

  defp add_partial(state, ""), do: state

  defp add_partial(state, part) do
    if state.partial_bytes + byte_size(part) > state.max,
      do: %{state | cut?: true},
      else: %{
        state
        | partial: [state.partial, part],
          partial_bytes: state.partial_bytes + byte_size(part)
      }
  end

  defp fold_lines(state, []), do: {:cont, state}

  defp fold_lines(state, [line | rest]) do
    case fold(state, line) do
      {:cont, state} -> fold_lines(state, rest)
      stop -> stop
    end
  end

  defp fold(%{fold: {fun, _}} = state, line) do
    case fun.(line, state.acc) do
      {:halt, acc} -> {:stop, %{state | acc: acc}}
      acc -> {:cont, %{state | acc: acc}}
    end
  end

  defp flush_partial(%{fold: nil} = state), do: state
  defp flush_partial(%{partial_bytes: 0} = state), do: state

  defp flush_partial(state) do
    line = IO.iodata_to_binary(state.partial)

    case fold(%{state | partial: [], partial_bytes: 0}, line) do
      {_cont_or_stop, state} -> state
    end
  end

  defp run_result(%{fold: nil, acc: acc}), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp run_result(%{acc: acc}), do: acc

  # The runner ends the process itself: a cap or a halt.
  defp stop_run(state) do
    close_run(state.port)
    {:ok, nil, run_result(state), state.cut?}
  end

  defp close_run(port) do
    port |> port_pid() |> kill_tree()

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    flush_port(port)
  end

  # Messages the port sent before it closed must not reach the caller later.
  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end

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
  def tree(os_pid), do: tree_of([os_pid], snapshot().children)

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

  # ncode p4: the walk is one snapshot, so a process forked after it to a
  # parent the TERM then killed is a descendant of no survivor: orphaned, it ran
  # on (a 10-deep chain still being built at a 5 ms timeout kept its last nine
  # levels; under CPU load the window is seconds). It is still in the process
  # group the root leads, though, so every member the first snapshot did not
  # list was born during the kill and is KILLed — by pid, with whatever it
  # started. A round catches what the last round's victims forked before their
  # KILL landed; a round that finds no one new ends the sweep, and so does the
  # deadline (the first round always runs). Members the first snapshot did list
  # but the walk did not reach are left as they were.
  #
  # ncode p4 review: so is what they start. Such a member is one whose parent
  # had already exited (`( server & )`), not one the kill orphaned, and a child
  # it forks while the kill runs is its own, not the kill's: a looping one lost
  # a child to each of the 16 rounds (~450 ms instead of ~50 ms per kill).
  # `done` is every pid the walk signalled; only what is not in it, and not
  # under a member left alone, can be new. "Under" is the snapshot's ppid: a
  # child that detaches (double-forks to ppid 1) cannot be told from one the
  # kill orphaned, so it is KILLed like one.
  defp leads_own_group?(%{groups: groups}, os_pid),
    do: Map.get(groups, os_pid) == os_pid and Map.get(groups, self_pid()) != os_pid

  defp sweep_group(_pgid, _first, _done, 0, _deadline), do: :ok

  defp sweep_group(pgid, first, done, rounds, deadline) do
    now = snapshot()

    {left, born} =
      now.groups
      |> Enum.filter(fn {pid, group} -> group == pgid and not MapSet.member?(done, pid) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.split_with(&Map.has_key?(first.groups, &1))

    left = left |> tree_of(now.children) |> MapSet.new()
    spare? = &(MapSet.member?(done, &1) or MapSet.member?(left, &1))

    case born |> Enum.reject(spare?) |> tree_of(now.children) |> Enum.reject(spare?) do
      [] ->
        :ok

      victims ->
        signal(Enum.reverse(victims), "KILL")
        done = MapSet.union(done, MapSet.new(victims))

        if System.monotonic_time(:millisecond) < deadline,
          do: sweep_group(pgid, first, done, rounds - 1, deadline),
          else: :ok
    end
  end

  # Every process on the machine, from one `ps`: `children` is
  # `%{ppid => [pid]}` for the walk, `groups` is `%{pid => pgid}`.
  defp snapshot do
    empty = %{children: %{}, groups: %{}}

    case cmd("ps", ["-Ao", "pid=,ppid=,pgid="]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reduce(empty, fn line, acc ->
          with [pid, ppid, pgid] <- line |> String.trim() |> String.split(~r/\s+/, parts: 3),
               {pid, ""} when pid > 1 <- Integer.parse(pid),
               {ppid, ""} <- Integer.parse(ppid),
               {pgid, ""} <- Integer.parse(pgid) do
            %{
              acc
              | children: Map.update(acc.children, ppid, [pid], &[pid | &1]),
                groups: Map.put(acc.groups, pid, pgid)
            }
          else
            _ -> acc
          end
        end)

      _ ->
        empty
    end
  end

  @doc "True while the OS process exists."
  @spec alive?(pos_integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid), do: living([os_pid]) == [os_pid]

  @doc "The subset of `pids` that still exists, from one `ps` (spec 74 BUGS-54)."
  @spec alive([pos_integer()]) :: [pos_integer()]
  def alive(pids) when is_list(pids), do: living(pids)

  @doc """
  The live members of process group `pgid`, from one `ps` (spec 74 BUGS-54).

  A port's shell leads its own group, and a job it starts with `&` stays in it
  (no job control in a non-interactive shell), so after the shell exits these
  are what it left running — whether or not it lived to write `jobs -p`. The
  group's id is only ever used to find its members; each member is signalled
  by its own pid, never the group, whose id may be a recycled pid once it is
  empty.
  """
  @spec group(pos_integer()) :: [pos_integer()]
  def group(pgid) when is_integer(pgid) and pgid > 1 do
    case cmd("ps", ["-Ao", "pid=,pgid="]) do
      {out, 0} ->
        for line <- String.split(out, "\n", trim: true),
            [pid, group] <- [line |> String.trim() |> String.split(~r/\s+/, parts: 2)],
            {group, ""} <- [Integer.parse(group)],
            group == pgid,
            {pid, ""} <- [Integer.parse(pid)],
            pid > 1 and pid != self_pid(),
            do: pid

      _failed ->
        []
    end
  end

  def group(_pgid), do: []

  # The subset of `pids` that still exists — one `ps` for all of them.
  defp living([]), do: []

  defp living(pids) do
    case cmd("ps", ["-o", "pid=", "-p", Enum.map_join(pids, ",", &Integer.to_string/1)]) do
      {out, _status} ->
        # spec 73 T71: one pid per *line* — stderr is merged, and macOS `ps`
        # answers a pid past its range with "process id too large: N", whose
        # N read as a live process when the output was split on whitespace.
        alive =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Integer.parse(String.trim(line)) do
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
    cmd("kill", args)
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

  defp cmd(command, args) do
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
