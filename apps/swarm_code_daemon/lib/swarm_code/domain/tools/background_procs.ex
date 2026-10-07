defmodule SwarmCode.Domain.Tools.BackgroundProcs do
  @moduledoc """
  What a run left running (spec 67 G30).

  `run_command` returns as soon as the command itself is over, and whatever it
  started stays alive on purpose — `npm run dev &` is the whole point of the
  call. Before this table there was no record of it: three "start the server"
  turns left three servers on ports 4000–4002, Stop could not see them and the
  only cure was Activity Monitor. Codex keeps the same book
  (`core/src/unified_exec/process_manager.rs:1698`) and terminates on drop.

  A tiny public ETS table so the swarm pane can list them without asking any
  RunServer: key `{run_id, os_pid}`, value `{command, started_at, janitor,
  status, conversation_id}`. The janitor that drains the survivor's output
  deletes the entry when the pipe finally closes, so the list is what is
  *still* running.

  spec 74 UX-9: every chat message is its own run, so a process keyed by run
  alone was out of reach of the next turn — `poll:`/`stop:` said "it belongs
  to another run" and the strip dropped it once the new turn was focused. Each
  row also records the conversation (from the trusted tool context, never the
  model's arguments); `poll/3` and `stop/3` reach a process of an earlier run
  of the same conversation, and `list_conversation/1` is what the strip shows.

  spec 67 T25 (G25): the janitor is also where a survivor's output goes. It
  keeps a 64 KB rolling ring of everything printed since the last read, so
  `run_command` with `poll: <os_pid>` can hand the model more output — and, once
  the process is over, its exit code. The ring lives in the janitor **process**,
  not in the table: that process already owns the port, one mailbox is cheaper
  than an ETS write per chunk, and it dies with the survivor.
  """
  use GenServer

  @table __MODULE__

  @type entry :: %{
          run_id: String.t() | nil,
          conversation_id: String.t() | nil,
          os_pid: pos_integer(),
          command: String.t(),
          started_at: DateTime.t()
        }

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Remembers the processes `run_id`'s command left behind, and returns the key
  the janitor hands back to `delete/1` when they are gone.

  A command whose survivor could not be identified (no `jobs -p` line the shell
  agreed to print) is remembered under no pid at all rather than under a wrong
  one: `kill/2` would otherwise signal a pid that has already been recycled.
  """
  @spec put(String.t() | nil, [pos_integer()], String.t()) :: [{String.t() | nil, pos_integer()}]
  def put(run_id, os_pids, command), do: put(run_id, os_pids, command, nil)

  @doc """
  `put/3`, recording the janitor that holds this survivor's output ring and
  (spec 74 UX-9) the conversation the run belongs to.
  """
  @spec put(String.t() | nil, [pos_integer()], String.t(), pid() | nil, String.t() | nil) :: [
          {String.t() | nil, pos_integer()}
        ]
  def put(run_id, os_pids, command, janitor, conversation_id \\ nil) do
    started_at = DateTime.utc_now()

    for os_pid <- os_pids, is_integer(os_pid) and os_pid > 1 do
      key = {run_id, os_pid}
      insert(key, {command, started_at, janitor, conversation_id})
      key
    end
  end

  @doc "Forgets the keys `put/3` returned (the survivor's pipe finally closed)."
  @spec delete([{String.t() | nil, pos_integer()}] | {String.t() | nil, pos_integer()}) :: :ok
  def delete(keys) when is_list(keys), do: Enum.each(keys, &delete/1)

  def delete({_run_id, _os_pid} = key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Everything `run_id` left **running**, oldest first.

  spec 67 T25: a survivor whose pipe has closed stays in the table for a few
  minutes so that one last `poll` can collect its exit code. It is not in this
  list — this is what the pane offers a Stop button for.
  """
  @spec list(String.t() | nil) :: [entry()]
  def list(run_id) do
    # spec 68 T10: filter at the ETS level with match_object.
    @table
    |> :ets.match_object({{run_id, :_}, :_, :_, :_, nil, :_})
    |> Enum.map(&entry/1)
    |> Enum.sort_by(& &1.started_at, DateTime)
  rescue
    ArgumentError -> []
  end

  @doc """
  spec 74 UX-9: everything the runs of `conversation_id` left **running**,
  grouped by run — `[{run_id, [entry]}]`, the run whose process started first
  first, each run's entries oldest first. `[]` for a nil conversation.
  """
  @spec list_conversation(String.t() | nil) :: [{String.t() | nil, [entry()]}]
  def list_conversation(conversation_id) when is_binary(conversation_id) do
    @table
    |> :ets.match_object({:_, :_, :_, :_, nil, conversation_id})
    |> Enum.map(&entry/1)
    |> Enum.group_by(& &1.run_id)
    |> Enum.map(fn {run_id, entries} ->
      {run_id, Enum.sort_by(entries, & &1.started_at, DateTime)}
    end)
    |> Enum.sort_by(fn {_run_id, [first | _]} -> first.started_at end, DateTime)
  rescue
    ArgumentError -> []
  end

  def list_conversation(_conversation_id), do: []

  @doc "Everything every run left running, oldest first."
  @spec list_all() :: [entry()]
  def list_all do
    # spec 68 T10: filter at the ETS level with match_object.
    @table
    |> :ets.match_object({:_, :_, :_, :_, nil, :_})
    |> Enum.map(&entry/1)
    |> Enum.sort_by(& &1.started_at, DateTime)
  rescue
    ArgumentError -> []
  end

  defp entry({{run_id, os_pid}, command, started_at, _janitor, _status, conversation_id}),
    do: %{
      run_id: run_id,
      conversation_id: conversation_id,
      os_pid: os_pid,
      command: command,
      started_at: started_at
    }

  @doc """
  Kills one survivor **and its descendants** and forgets it.

  `OSProcess.kill_tree/1` because the pid `jobs -p` reported is usually a
  wrapper: `npm run dev` is npm, and the server is its child.

  spec 74 BUGS-54: the janitor decides what that means. A yielded shell that
  has exited is not signalled — its pid may already belong to someone else —
  the processes it left running are; a row whose shell is known to be gone is
  never signalled by pid either, even with no janitor left to ask.
  """
  @spec kill(String.t() | nil, pos_integer()) :: :ok
  def kill(run_id, os_pid) do
    key = {run_id, os_pid}

    targets =
      case janitor_pid(key) do
        pid when is_pid(pid) ->
          case call(pid, {:stop, os_pid}) do
            {:ok, targets} -> targets
            {:error, :unknown} -> if running?(key), do: [os_pid], else: []
          end

        _none ->
          if running?(key), do: [os_pid], else: []
      end

    Enum.each(targets, &SwarmCode.Domain.OSProcess.kill_tree/1)
    delete(key)
  end

  # The row says the process has not been seen to exit.
  defp running?(key) do
    match?([{^key, _command, _started_at, _janitor, nil, _conv}], :ets.lookup(@table, key))
  rescue
    ArgumentError -> false
  end

  @doc "Kills everything `run_id` left running. Returns how many it signalled."
  @spec kill_all(String.t() | nil) :: non_neg_integer()
  def kill_all(run_id) do
    entries = list(run_id)
    Enum.each(entries, &kill(run_id, &1.os_pid))
    length(entries)
  end

  @doc """
  `kill/2` without waiting for the kill (spec 74 UI-SPEED-17).

  The row goes at once — the strip empties on the next render and `list/1`
  stops offering it — and the janitor request plus `OSProcess.kill_tree/1`
  (a TERM, up to 500 ms of polls, then KILL) run in a `TaskSupervisor` child
  that owns only the external kill. Quit keeps the synchronous `kill/2`: it
  must finish before `System.halt`.
  """
  @spec kill_async(String.t() | nil, pos_integer()) :: :ok
  def kill_async(run_id, os_pid) do
    key = {run_id, os_pid}
    janitor = janitor_pid(key)
    fallback = if running?(key), do: [os_pid], else: []
    delete(key)

    {:ok, _pid} =
      Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
        targets =
          case janitor && call(janitor, {:stop, os_pid}) do
            {:ok, targets} -> targets
            _none_or_unknown -> fallback
          end

        Enum.each(targets, &SwarmCode.Domain.OSProcess.kill_tree/1)
      end)

    :ok
  end

  @doc "`kill_all/1` with `kill_async/2` per row. Returns how many it signalled."
  @spec kill_all_async(String.t() | nil) :: non_neg_integer()
  def kill_all_async(run_id) do
    entries = list(run_id)
    Enum.each(entries, &kill_async(run_id, &1.os_pid))
    length(entries)
  end

  defp insert(key, {command, started_at, janitor, conversation_id}) do
    :ets.insert(@table, {key, command, started_at, janitor, nil, conversation_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ------------------------------------------------------------------ T25: the janitor

  # What a survivor may have printed since the last read. Codex keeps 1 MiB per
  # process; this is one op's worth of catching up, and the model can poll again.
  @ring_bytes 64 * 1024

  # How long a finished survivor stays pollable, so a model that yielded can
  # still collect the exit code of the command it started.
  @linger_ms :timer.minutes(5)

  # spec 74 BUGS-54: how often a yielded command's janitor looks for its
  # shell's exit — the status file every time, the pid (one `ps`) every fifth.
  @shell_check_ms 1_000
  @shell_alive_every 5

  @doc """
  Hands `port` to a janitor process and registers what it is draining
  (spec 67 T1/T25). Returns the pids it registered.

  Must be called by the port's owner: `Port.connect/2` only works from there.
  `Port.close/1` is deliberately not an option — the survivor's next write would
  get EPIPE, which a shell ignores and Node and Python die on.

  `info` carries `:run_id`, `:conversation_id` (spec 74 UX-9), `:os_pids` (what to register — the shell itself on
  the yield path, `jobs -p` on the drain path; a list, or a zero-arity function
  evaluated once the port is handed over), `:command`, `:tmp` (files the
  janitor removes once the pipe closes) and `:rc_file` (where the shell writes
  its exit status). spec 74 BUGS-54: `:shell_pid` (the yield path) makes the
  janitor watch that shell and, once it exits, record its status and register
  what it left running.

  spec 74 BUGS-23: `Port.connect/2` redirects only *future* messages, so the
  output already queued in the caller's mailbox — everything the survivor
  printed while the op was reporting progress and running `ps` — used to be
  dropped with the op. It is drained into a backlog right after the connect
  and replayed by the janitor, in order, before anything newer. A port that
  closed before the handover hands over its real exit status (from that
  backlog, else the status file), never an invented 0.
  """
  @spec adopt(port(), map()) :: {:ok, [pos_integer()]}
  def adopt(port, info) do
    parent = self()
    command = Map.get(info, :command, "")
    tmp = Map.get(info, :tmp, [])
    shell = shell_watch(info, command)

    case Task.Supervisor.start_child(__MODULE__.Supervisor, fn ->
           # The keys are only known once the janitor's own pid is, so they
           # arrive in its first message rather than in the closure.
           {keys, backlog} =
             receive do
               {^parent, :keys, keys, backlog} -> {keys, backlog}
             after
               5_000 -> {[], []}
             end

           janitor(port, keys, tmp, backlog, shell)
         end) do
      {:ok, janitor} ->
        backlog =
          try do
            Port.connect(port, janitor)
            Process.unlink(port)
            backlog(port)
          rescue
            # The port closed between the drain decision and the handover: all
            # it ever sent is already here, the exit status included.
            _ -> port |> backlog() |> with_exit_status(port, info)
          end

        # spec 74 BUGS-23: the pids are read after the handover, so the `ps`
        # calls behind them no longer widen the window in which the
        # survivor's output lands in this process instead of the janitor.
        pids = info |> Map.get(:os_pids, []) |> resolve_pids()

        keys =
          put(Map.get(info, :run_id), pids, command, janitor, Map.get(info, :conversation_id))

        send(janitor, {parent, :keys, keys, backlog})
        {:ok, pids}

      _error ->
        close(port)
        {:ok, []}
    end
  end

  # spec 74 BUGS-54: on the yield path the registered pid is the shell's own,
  # and the janitor watches it (`:shell_pid` plus its `:rc_file`).
  defp shell_watch(%{shell_pid: pid, rc_file: rc_file} = info, command)
       when is_integer(pid) and is_binary(rc_file) do
    %{
      pid: pid,
      rc_file: rc_file,
      run_id: Map.get(info, :run_id),
      conversation_id: Map.get(info, :conversation_id),
      command: command,
      exited: nil,
      checks: 0
    }
  end

  defp shell_watch(_info, _command), do: nil

  defp resolve_pids(fun) when is_function(fun, 0), do: fun.()
  defp resolve_pids(pids) when is_list(pids), do: pids

  # Everything `port` sent that is still in this process's mailbox, oldest
  # first. After `Port.connect/2` and `Process.unlink/1` nothing new arrives.
  defp backlog(port, acc \\ []) do
    receive do
      {^port, _message} = message -> backlog(port, [message | acc])
      {:EXIT, ^port, _reason} = message -> backlog(port, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A closed port whose exit status is not in the backlog: the shell's status
  # file says it, or the janitor is told the pipe is closed with no status.
  defp with_exit_status(backlog, port, info) do
    if Enum.any?(backlog, &match?({_port, {:exit_status, _status}}, &1)) do
      backlog
    else
      case read_rc(Map.get(info, :rc_file)) do
        nil -> backlog ++ [{:EXIT, port, :closed}]
        status -> backlog ++ [{port, {:exit_status, status}}]
      end
    end
  end

  defp read_rc(nil), do: nil

  defp read_rc(file) do
    with {:ok, text} <- File.read(file),
         {status, ""} <- Integer.parse(String.trim(text)) do
      status
    else
      _ -> nil
    end
  end

  @doc """
  Everything `os_pid` has printed since the last poll, and its exit code once it
  has one (spec 67 T25 / G25).

  `status` is nil while it runs. A survivor that has both finished and been read
  is forgotten, so the poll after that one reports it gone.

  spec 74 BUGS-54: a yielded shell that exited while something it started
  still holds the pipe answers its exit code (`:unknown` when the shell never
  reported one) and `survivors`, the pids it left running. It stays pollable
  and stoppable until they are gone too.
  """
  @spec poll(String.t() | nil, pos_integer()) ::
          {:ok,
           %{
             output: binary(),
             status: integer() | :unknown | nil,
             dropped: non_neg_integer(),
             survivors: [pos_integer()]
           }}
          | {:error, :unknown}
  def poll(run_id, os_pid), do: poll(run_id, nil, os_pid)

  @doc """
  spec 74 UX-9: `poll/2` from a run of `conversation_id` — the exact
  `{run_id, os_pid}` row, else that pid's row in another run of the same
  conversation (the next chat turn is a new run). Any other conversation's
  process is `{:error, :unknown}`.
  """
  @spec poll(String.t() | nil, String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, :unknown}
  def poll(run_id, conversation_id, os_pid) do
    with {_run_id, _pid} = key <- find_key(run_id, conversation_id, os_pid),
         pid when is_pid(pid) <- janitor_pid(key) do
      call(pid, {:poll, os_pid})
    else
      _none -> {:error, :unknown}
    end
  end

  @doc "Kills `os_pid` and its descendants and forgets it; `{:error, :unknown}` when it is gone."
  @spec stop(String.t() | nil, pos_integer()) :: :ok | {:error, :unknown}
  def stop(run_id, os_pid), do: stop(run_id, nil, os_pid)

  @doc "spec 74 UX-9: `stop/2`, reaching the runs of `conversation_id` as `poll/3` does."
  @spec stop(String.t() | nil, String.t() | nil, pos_integer()) :: :ok | {:error, :unknown}
  def stop(run_id, conversation_id, os_pid) do
    case find_key(run_id, conversation_id, os_pid) do
      {owner_run, ^os_pid} ->
        kill(owner_run, os_pid)
        :ok

      nil ->
        {:error, :unknown}
    end
  end

  @doc """
  `stop/3` for the survivors strip (spec 74 UI-SPEED-17): the row is gone at
  once and the kill runs in an owned task. The `run_command` tool's `stop:`
  keeps `stop/3`, whose `:ok` means the kill is done.
  """
  @spec stop_async(String.t() | nil, String.t() | nil, pos_integer()) :: :ok | {:error, :unknown}
  def stop_async(run_id, conversation_id, os_pid) do
    case find_key(run_id, conversation_id, os_pid) do
      {owner_run, ^os_pid} -> kill_async(owner_run, os_pid)
      nil -> {:error, :unknown}
    end
  end

  # spec 74 UX-9: the row the call means. Ownership is read from the stored
  # row, never from the caller: a pid of another conversation (or a row with
  # no conversation) is not found. Of several rows of one pid — a recycled pid
  # across turns — the running one wins, then the newest.
  defp find_key(run_id, conversation_id, os_pid) do
    exact = {run_id, os_pid}

    case :ets.lookup(@table, exact) do
      [_row] ->
        exact

      [] when is_binary(conversation_id) ->
        @table
        |> :ets.match_object({{:_, os_pid}, :_, :_, :_, :_, conversation_id})
        |> Enum.sort_by(fn {_key, _command, at, _janitor, status, _conv} ->
          {status == nil, DateTime.to_unix(at, :microsecond)}
        end)
        |> List.last()
        |> case do
          {key, _command, _at, _janitor, _status, _conv} -> key
          nil -> nil
        end

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # One request to a janitor: `{:poll | :stop, os_pid}`. A janitor that is
  # gone, or does not answer in 5 s, is `{:error, :unknown}`.
  defp call(pid, {message, os_pid}) do
    ref = Process.monitor(pid)
    send(pid, {message, os_pid, self(), ref})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {:ok, reply}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        {:error, :unknown}
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :unknown}
    end
  end

  defp janitor_pid(key) do
    case :ets.lookup(@table, key) do
      [{^key, _command, _started_at, pid, _status, _conv}] when is_pid(pid) -> pid
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  def janitor(port, keys, tmp, backlog \\ [], shell \\ nil) do
    state = %{
      port: port,
      keys: keys,
      tmp: tmp,
      ring: SwarmCode.Domain.Tools.RunCommand.tail_new(),
      dropped: 0,
      status: nil,
      shell: shell,
      # The pids `stop:` may signal besides a running shell: on the drain path
      # every registered pid, on the yield path what the shell left running.
      survivors: if(shell, do: [], else: Enum.map(keys, &elem(&1, 1)))
    }

    if shell, do: Process.send_after(self(), :check_shell, @shell_check_ms)
    replay(backlog, state)
  end

  # spec 74 BUGS-23: what the op had already received, before anything newer.
  defp replay([], state), do: drain(state)

  defp replay([{from, {:data, data}} | rest], %{port: from} = state),
    do: replay(rest, push(state, IO.iodata_to_binary(data)))

  defp replay([{from, {:exit_status, status}} | _rest], %{port: from} = state),
    do: finish(%{state | status: status})

  defp replay([{:EXIT, from, _reason} | _rest], %{port: from} = state), do: finish(state)
  defp replay([_other | rest], state), do: replay(rest, state)

  defp drain(%{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        drain(push(state, IO.iodata_to_binary(data)))

      {^port, {:exit_status, status}} ->
        finish(%{state | status: status})

      {:EXIT, ^port, _reason} ->
        finish(state)

      :check_shell ->
        state = check_shell(state)

        if state.shell && state.shell.exited == nil,
          do: Process.send_after(self(), :check_shell, @shell_check_ms)

        drain(state)

      {:poll, os_pid, from, ref} ->
        send(from, {ref, taken(state, os_pid)})
        drain(%{state | ring: SwarmCode.Domain.Tools.RunCommand.tail_new(), dropped: 0})

      {:stop, os_pid, from, ref} ->
        stop_request(state, os_pid, from, ref)

      :shutdown ->
        :ok
    end
  end

  # spec 74 BUGS-54: a yielded command's shell can exit while something it
  # started still holds the pipe, and `{:exit_status, _}` only comes when the
  # last writer closes it — so `poll` said "pending" forever and `stop:` killed
  # a dead pid. Every `@shell_check_ms`: the status file (the shell's EXIT trap
  # writes it, `exit N` included), else — every `@shell_alive_every`th check,
  # one `ps` — the shell's pid.
  # Once it is gone its status is recorded and what it left running is read
  # from the job file and registered under this janitor, so the pane lists it
  # and Stop reaches it.

  defp check_shell(state, now? \\ false)

  defp check_shell(%{shell: %{exited: nil} = shell} = state, now?) do
    shell = %{shell | checks: shell.checks + 1}

    over? =
      File.exists?(shell.rc_file) or
        ((now? or rem(shell.checks, @shell_alive_every) == 0) and
           not SwarmCode.Domain.OSProcess.alive?(shell.pid))

    if over?, do: shell_exited(state, shell), else: %{state | shell: shell}
  end

  defp check_shell(state, _now?), do: state

  defp shell_exited(state, shell) do
    status = read_rc(shell.rc_file) || :unknown

    survivors = left_running(shell)

    keys = put(shell.run_id, survivors, shell.command, self(), shell.conversation_id)
    mark_exited({shell.run_id, shell.pid}, status)

    %{
      state
      | shell: %{shell | exited: status},
        survivors: survivors,
        keys: Enum.uniq(state.keys ++ keys)
    }
  end

  # What the shell left running: its job list (when it lived to write one) and
  # the live members of its process group (when it did not — `exec`, a kill).
  defp left_running(shell) do
    (SwarmCode.Domain.Tools.RunCommand.read_jobs(shell.rc_file) ++
       SwarmCode.Domain.OSProcess.group(shell.pid))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == shell.pid))
  end

  # What `stop: os_pid` kills: the shell itself while it runs (the tree walk
  # takes what it started along); once it has exited, only what it left
  # running — its own pid may already be someone else's. Stopping the shell,
  # or the last pid this janitor watches, ends the janitor; stopping one of
  # several survivors forgets that one and keeps draining the rest.
  defp stop_request(state, os_pid, from, ref) do
    shell? = match?(%{shell: %{pid: ^os_pid}}, state)
    state = if shell?, do: check_shell(state, true), else: state

    {targets, remaining} =
      cond do
        shell? and state.shell.exited == nil ->
          {[os_pid], []}

        shell? ->
          {Enum.uniq(
             SwarmCode.Domain.OSProcess.alive(state.survivors) ++ left_running(state.shell)
           ), []}

        true ->
          {[os_pid], List.delete(state.survivors, os_pid)}
      end

    send(from, {ref, targets})

    if remaining == [] do
      Enum.each(state.keys, &delete/1)
    else
      {gone, keys} = Enum.split_with(state.keys, &match?({_run_id, ^os_pid}, &1))
      Enum.each(gone, &delete/1)
      drain(%{state | survivors: remaining, keys: keys})
    end
  end

  # The pipe is closed: the command and everything it started are over. The row
  # keeps its status for `@linger_ms` so one last poll can report the exit code,
  # and `list/1` stops offering it as something to stop.
  defp finish(state) do
    Enum.each(state.tmp, &File.rm/1)
    Enum.each(state.keys, &mark_exited(&1, state.status))
    linger(%{state | survivors: []})
  end

  defp linger(state) do
    receive do
      {:poll, os_pid, from, ref} ->
        send(from, {ref, taken(state, os_pid)})
        Enum.each(state.keys, &delete/1)

      {:stop, _os_pid, from, ref} ->
        # Everything is over: there is nothing left to signal.
        send(from, {ref, []})
        Enum.each(state.keys, &delete/1)

      :shutdown ->
        :ok
    after
      @linger_ms -> Enum.each(state.keys, &delete/1)
    end
  end

  # spec 73 T98: the ring is the same chunk queue as run_command's tail
  # (spec 73 T101) — `ring <> chunk` then `binary_part/3` copied 64 KB per
  # chunk of a chatty survivor for the life of the run. It is materialised
  # here, once per poll; the bytes the exact cut drops are counted with the
  # whole chunks dropped while streaming, so `dropped` reads as before.
  defp taken(%{ring: {_queue, size} = ring} = state, os_pid) do
    output = SwarmCode.Domain.Tools.RunCommand.tail_binary(ring, @ring_bytes)

    # spec 74 BUGS-54: the shell's own pid answers the shell's exit once it is
    # known, with what it left running; any other pid of this janitor is
    # still running until the pipe closes.
    {status, survivors} =
      case state do
        %{status: status} when status != nil ->
          {status, []}

        %{shell: %{pid: ^os_pid, exited: exited}} when exited != nil ->
          {exited, SwarmCode.Domain.OSProcess.alive(state.survivors)}

        _running ->
          {nil, []}
      end

    %{
      output: output,
      status: status,
      dropped: state.dropped + (size - byte_size(output)),
      survivors: survivors
    }
  end

  defp push(state, chunk) do
    {ring, dropped} = SwarmCode.Domain.Tools.RunCommand.tail_push(state.ring, chunk, @ring_bytes)
    %{state | ring: ring, dropped: state.dropped + dropped}
  end

  # spec 74 BUGS-23: a pipe that closed without a status is `:unknown`, not a
  # made-up 0 — either way the row leaves `list/1`.
  defp mark_exited(key, status) do
    :ets.update_element(@table, key, {5, status || :unknown})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
