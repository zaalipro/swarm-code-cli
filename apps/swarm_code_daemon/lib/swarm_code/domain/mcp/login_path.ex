defmodule SwarmCode.Domain.MCP.LoginPath do
  @moduledoc """
  pass74 (spec 74) UX-10: the `PATH` a stdio MCP server is looked up on and
  started with.

  A `.app` launched from the Dock or Finder inherits launchd's
  `/usr/bin:/bin:/usr/sbin:/sbin`, so `npx`, `uvx` and `node` — which live in
  brew, mise, nvm or asdf directories that the user's login files put on
  `PATH` — were "command not found", and after three strikes the client
  stopped retrying. The login shell's `PATH` is read once at boot, through the
  same shell `run_command` uses (`SWARM_CODE_SHELL` → `shell_path` → `$SHELL`
  → `/bin/sh`), in an owned task with a 5 s bound (the process tree is killed
  past it), and cached in `:persistent_term`.

  `path/0` is that `PATH` followed by every VM `PATH` entry it lacks, so a
  server found before (a dev VM started from a terminal) is still found. Like
  `run_command`, a login shell reads `~/.zprofile`, not `~/.zshrc`.

  The resolver never blocks a client: `await/1` answers `:ready`, or `:later`
  and sends `{:login_path_ready, tag}` once the `PATH` is known.
  """
  use GenServer
  require Logger

  alias SwarmCode.Domain.OSProcess
  alias SwarmCode.Domain.Tools.RunCommand

  @key {__MODULE__, :path}
  @timeout 5_000
  @max_output 65_536
  @marker "__SWARM_CODE_LOGIN_PATH__"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The login `PATH` once resolved, else nil."
  @spec cached() :: String.t() | nil
  def cached, do: :persistent_term.get(@key, nil)

  @doc """
  The `PATH` for a stdio MCP server: the login shell's entries, then the VM's
  entries it lacks. The VM's alone while the login one is not known.
  """
  @spec path() :: String.t()
  def path, do: merge(cached(), vm_path())

  @doc """
  `:ready` when `path/0` is final (resolved, or no resolver runs), else
  `:later`: `{:login_path_ready, tag}` is sent to the caller when it is.
  """
  @spec await(term()) :: :ready | :later
  def await(tag) do
    cond do
      cached() != nil ->
        :ready

      Process.whereis(__MODULE__) == nil ->
        :ready

      true ->
        GenServer.cast(__MODULE__, {:await, self(), tag})
        :later
    end
  end

  @doc "Resolves again and waits for it (tests, and after `SWARM_CODE_SHELL` changed)."
  @spec refresh() :: String.t()
  def refresh, do: GenServer.call(__MODULE__, :refresh, @timeout * 2)

  ## ------------------------------------------------------------------ server

  @impl true
  def init(:ok), do: {:ok, %{task: nil, waiters: [], callers: []}, {:continue, :resolve}}

  @impl true
  def handle_continue(:resolve, state), do: {:noreply, start_task(state)}

  @impl true
  def handle_cast({:await, pid, tag}, state) do
    if cached() != nil do
      send(pid, {:login_path_ready, tag})
      {:noreply, state}
    else
      {:noreply, %{state | waiters: [{pid, tag} | state.waiters]}}
    end
  end

  @impl true
  def handle_call(:refresh, from, state) do
    :persistent_term.erase(@key)
    state = if state.task, do: state, else: start_task(state)
    {:noreply, %{state | callers: [from | state.callers]}}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, settle(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, settle(state, nil)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_task(state) do
    %{state | task: Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, &resolve/0)}
  end

  # An unreadable login shell is not an error: the VM's `PATH` is what every
  # server was started with before, and `path/0` falls back to it.
  defp settle(state, result) do
    login = if is_binary(result) and result != "", do: result, else: vm_path()
    :persistent_term.put(@key, login)

    for {pid, tag} <- state.waiters, do: send(pid, {:login_path_ready, tag})
    for from <- state.callers, do: GenServer.reply(from, path())

    %{state | task: nil, waiters: [], callers: []}
  end

  ## ---------------------------------------------------------------- resolving

  @doc false
  # Runs the login shell once and reads the `PATH` it prints after a marker,
  # so whatever the login files echo first is ignored. nil on any failure.
  @spec resolve() :: String.t() | nil
  def resolve do
    {shell, args} = RunCommand.shell(settings(), ~s(printf '#{@marker}%s' "$PATH"))

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        {:args, args},
        {:cd, System.user_home!()}
      ])

    deadline = System.monotonic_time(:millisecond) + @timeout
    collect(port, [], 0, deadline)
  rescue
    e ->
      Logger.warning("swarm_code mcp: login PATH not read (#{Exception.message(e)})")
      nil
  end

  defp collect(port, parts, size, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        # The bound is enforced while reading: login noise is not unbounded memory.
        if size + byte_size(data) > @max_output,
          do: give_up(port, "over #{@max_output} bytes"),
          else: collect(port, [data | parts], size + byte_size(data), deadline)

      {^port, {:exit_status, 0}} ->
        parts |> Enum.reverse() |> IO.iodata_to_binary() |> after_marker()

      {^port, {:exit_status, status}} ->
        Logger.warning("swarm_code mcp: login shell exited #{status}; using the app's PATH")
        nil
    after
      remaining -> give_up(port, "timed out after #{div(@timeout, 1000)} s")
    end
  end

  defp give_up(port, why) do
    port |> OSProcess.port_pid() |> OSProcess.kill_tree()

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    Logger.warning("swarm_code mcp: login PATH not read (#{why}); using the app's PATH")
    nil
  end

  defp after_marker(output) do
    case String.split(output, @marker) do
      [_only] -> nil
      parts -> parts |> List.last() |> String.trim()
    end
  end

  ## ------------------------------------------------------------------ helpers

  # `shell_path` / `shell_login` from Settings; the defaults when they cannot
  # be read (a database that is not up, or not this process's in a test).
  defp settings do
    SwarmCode.Domain.Settings.get_cached()
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  # The VM's own `PATH`, as `run_command` passes it on (the embedded ERTS
  # directories of a packaged release dropped).
  defp vm_path do
    Enum.find_value(RunCommand.clean_env_base(), "", fn
      {~c"PATH", value} -> List.to_string(value)
      _other -> nil
    end)
  end

  @doc false
  # The login entries first, then the VM entries they lack; empty entries go.
  @spec merge(String.t() | nil, String.t()) :: String.t()
  def merge(nil, vm), do: vm

  def merge(login, vm) do
    (String.split(login, ":") ++ String.split(vm, ":"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(":")
  end
end
