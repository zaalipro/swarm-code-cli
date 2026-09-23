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
  status}`. The janitor that drains the survivor's output deletes the entry when
  the pipe finally closes, so the list is what is *still* running.

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

  @doc "`put/3`, recording the janitor that holds this survivor's output ring."
  @spec put(String.t() | nil, [pos_integer()], String.t(), pid() | nil) :: [
          {String.t() | nil, pos_integer()}
        ]
  def put(run_id, os_pids, command, janitor) do
    started_at = DateTime.utc_now()

    for os_pid <- os_pids, is_integer(os_pid) and os_pid > 1 do
      key = {run_id, os_pid}
      insert(key, {command, started_at, janitor})
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
    |> :ets.match_object({{run_id, :_}, :_, :_, :_, nil})
    |> Enum.map(&entry/1)
    |> Enum.sort_by(& &1.started_at, DateTime)
  rescue
    ArgumentError -> []
  end

  @doc "Everything every run left running, oldest first."
  @spec list_all() :: [entry()]
  def list_all do
    # spec 68 T10: filter at the ETS level with match_object.
    @table
    |> :ets.match_object({:_, :_, :_, :_, nil})
    |> Enum.map(&entry/1)
    |> Enum.sort_by(& &1.started_at, DateTime)
  rescue
    ArgumentError -> []
  end

  defp entry({{run_id, os_pid}, command, started_at, _janitor, _status}),
    do: %{run_id: run_id, os_pid: os_pid, command: command, started_at: started_at}

  @doc """
  Kills one survivor **and its descendants** and forgets it.

  `OSProcess.kill_tree/1` because the pid `jobs -p` reported is usually a
  wrapper: `npm run dev` is npm, and the server is its child.
  """
  @spec kill(String.t() | nil, pos_integer()) :: :ok
  def kill(run_id, os_pid) do
    # The janitor holds this survivor's port and its ring; without this it would
    # sit in its linger window for five minutes after the pid is already gone.
    case janitor_pid({run_id, os_pid}) do
      pid when is_pid(pid) -> send(pid, :shutdown)
      _none -> :ok
    end

    SwarmCode.Domain.OSProcess.kill_tree(os_pid)
    delete({run_id, os_pid})
  end

  @doc "Kills everything `run_id` left running. Returns how many it signalled."
  @spec kill_all(String.t() | nil) :: non_neg_integer()
  def kill_all(run_id) do
    entries = list(run_id)
    Enum.each(entries, &kill(run_id, &1.os_pid))
    length(entries)
  end

  defp insert(key, {command, started_at, janitor}) do
    :ets.insert(@table, {key, command, started_at, janitor, nil})
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

  @doc """
  Hands `port` to a janitor process and registers what it is draining
  (spec 67 T1/T25).

  Must be called by the port's owner: `Port.connect/2` only works from there.
  `Port.close/1` is deliberately not an option — the survivor's next write would
  get EPIPE, which a shell ignores and Node and Python die on.

  `info` carries `:run_id`, `:os_pids` (what to register — the shell itself on
  the yield path, `jobs -p` on the drain path), `:command` and `:tmp` (files the
  janitor removes once the pipe closes).
  """
  @spec adopt(port(), map()) :: :ok
  def adopt(port, info) do
    parent = self()
    pids = Map.get(info, :os_pids, [])
    command = Map.get(info, :command, "")
    tmp = Map.get(info, :tmp, [])

    case Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
           # The keys are only known once the janitor's own pid is, so they
           # arrive in its first message rather than in the closure.
           keys =
             receive do
               {^parent, :keys, keys} -> keys
             after
               5_000 -> []
             end

           janitor(port, keys, tmp)
         end) do
      {:ok, janitor} ->
        keys = put(Map.get(info, :run_id), pids, command, janitor)

        try do
          Port.connect(port, janitor)
          Process.unlink(port)
          send(janitor, {parent, :keys, keys})
          :ok
        rescue
          # The port closed between the drain decision and the handover: the
          # janitor has nothing to drain and must not wait for ever.
          _ ->
            send(janitor, {parent, :keys, keys})
            send(janitor, {port, {:exit_status, 0}})
            :ok
        end

      _error ->
        close(port)
        :ok
    end
  end

  @doc """
  Everything `os_pid` has printed since the last poll, and its exit code once it
  has one (spec 67 T25 / G25).

  `status` is nil while it runs. A survivor that has both finished and been read
  is forgotten, so the poll after that one reports it gone.
  """
  @spec poll(String.t() | nil, pos_integer()) ::
          {:ok, %{output: binary(), status: integer() | nil, dropped: non_neg_integer()}}
          | {:error, :unknown}
  def poll(run_id, os_pid), do: ask({run_id, os_pid}, :poll)

  @doc "Kills `os_pid` and its descendants and forgets it; `{:error, :unknown}` when it is gone."
  @spec stop(String.t() | nil, pos_integer()) :: :ok | {:error, :unknown}
  def stop(run_id, os_pid) do
    case :ets.lookup(@table, {run_id, os_pid}) do
      [_row] ->
        kill(run_id, os_pid)
        :ok

      _none ->
        {:error, :unknown}
    end
  rescue
    ArgumentError -> {:error, :unknown}
  end

  defp ask(key, message) do
    case janitor_pid(key) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        send(pid, {message, self(), ref})

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

      _none ->
        {:error, :unknown}
    end
  end

  defp janitor_pid(key) do
    case :ets.lookup(@table, key) do
      [{^key, _command, _started_at, pid, _status}] when is_pid(pid) -> pid
      _other -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  def janitor(port, keys, tmp) do
    drain(port, keys, tmp, %{
      ring: SwarmCode.Domain.Tools.RunCommand.tail_new(),
      dropped: 0,
      status: nil
    })
  end

  defp drain(port, keys, tmp, state) do
    receive do
      {^port, {:data, data}} ->
        drain(port, keys, tmp, push(state, IO.iodata_to_binary(data)))

      {^port, {:exit_status, status}} ->
        finish(keys, tmp, %{state | status: status})

      {:EXIT, ^port, _reason} ->
        finish(keys, tmp, state)

      {:poll, from, ref} ->
        send(from, {ref, taken(state)})

        drain(port, keys, tmp, %{
          state
          | ring: SwarmCode.Domain.Tools.RunCommand.tail_new(),
            dropped: 0
        })

      :shutdown ->
        :ok
    end
  end

  # The pipe is closed: the command and everything it started are over. The row
  # keeps its status for `@linger_ms` so one last poll can report the exit code,
  # and `list/1` stops offering it as something to stop.
  defp finish(keys, tmp, state) do
    Enum.each(tmp, &File.rm/1)
    Enum.each(keys, &mark_exited(&1, state.status))
    linger(keys, state)
  end

  defp linger(keys, state) do
    receive do
      {:poll, from, ref} ->
        send(from, {ref, taken(state)})
        Enum.each(keys, &delete/1)

      :shutdown ->
        :ok
    after
      @linger_ms -> Enum.each(keys, &delete/1)
    end
  end

  # spec 73 T98: the ring is the same chunk queue as run_command's tail
  # (spec 73 T101) — `ring <> chunk` then `binary_part/3` copied 64 KB per
  # chunk of a chatty survivor for the life of the run. It is materialised
  # here, once per poll; the bytes the exact cut drops are counted with the
  # whole chunks dropped while streaming, so `dropped` reads as before.
  defp taken(%{ring: {_queue, size} = ring} = state) do
    output = SwarmCode.Domain.Tools.RunCommand.tail_binary(ring, @ring_bytes)
    %{output: output, status: state.status, dropped: state.dropped + (size - byte_size(output))}
  end

  defp push(state, chunk) do
    {ring, dropped} = SwarmCode.Domain.Tools.RunCommand.tail_push(state.ring, chunk, @ring_bytes)
    %{state | ring: ring, dropped: state.dropped + dropped}
  end

  defp mark_exited(key, status) do
    :ets.update_element(@table, key, {5, status || 0})
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
