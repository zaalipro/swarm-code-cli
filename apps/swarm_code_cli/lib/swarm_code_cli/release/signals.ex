defmodule SwarmCodeCLI.Release.Signals do
  @moduledoc """
  cli020 B9 (bugs-5): SIGTERM and SIGHUP close a session the normal way.

  Before, both killed the VM at once: no `Daemon.Shutdown`, live runs left
  `running` in the database, the private socket folder left in /tmp and the
  terminal not restored. `install/1` traps both (`System.trap_signal/3`); the
  handler sends `{:shutdown_signal, sig}` to the session owner, which runs
  its close path (stop the live runs, stop the applications, remove the
  private folder) and exits `exit_code/1` (143 for SIGTERM, 129 for SIGHUP,
  the shell's 128 + signal number).

  pass76: the close gets `deadline_ms/0` to finish: the owned shutdown's own
  budget (`Daemon.Shutdown.budget_ms/0`, which its phase deadlines add up to)
  plus room for the stops around it. It used to get 10 s, so closing a
  terminal could end the VM with runs still `running` and worktree cleanups
  half done. When the deadline passes the VM halts with the first signal's
  code. A second signal halts it at once with its own code. A signal that
  arrives less than `@repeat_ms` after the first is the same event, not a
  second signal: a closing terminal can reach the process through both the
  kernel and the shell, and halting on that pair would cut the very close
  this module exists for.

  OTP answers SIGTERM with `init:stop/0` after the traps have run, which
  stops every application, the session owner among them, and exits with 0
  while the close is still going. `install/1` takes that answer away and
  keeps OTP's other two, halting on SIGQUIT and SIGUSR1.

  SIGINT cannot be trapped (`os:set_signal(sigint, handle)` raises `badarg`
  on OTP 28) and stays under `+Bd` (`rel/env.sh.eex`, unchanged).
  """

  # The daemon app is not a compile-time dependency of this one.
  @compile {:no_warn_undefined, [SwarmCode.Daemon.Shutdown]}
  require Logger

  @signals %{sigterm: :ncode_term, sighup: :ncode_hup}
  # Around the owned shutdown the close restores the terminal (the session
  # supervisor's stop) and stops the applications and the storage. That is
  # quick when it works, and a hang there gains nothing from a longer wait.
  @close_slack_ms 20_000
  @repeat_ms 1_000
  @log_flush_ms 500
  @watchdog __MODULE__.Watchdog

  @doc """
  How long a signal's close may take before the VM is halted: the owned
  shutdown's budget plus the slack for the stops around it.
  """
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: SwarmCode.Daemon.Shutdown.budget_ms() + @close_slack_ms

  @doc """
  Traps SIGTERM and SIGHUP for `owner`; safe to call again (the newest owner
  wins). `opts` go to `deliver/3`.
  """
  @spec install(pid(), keyword()) :: :ok
  def install(owner \\ self(), opts \\ []) when is_pid(owner) and is_list(opts) do
    trapped =
      for {signal, id} <- @signals,
          trap(signal, id, fn -> safely(fn -> deliver(owner, signal, opts) end) end),
          do: signal

    if :sigterm in trapped, do: replace_default_handler()
    :ok
  catch
    kind, reason ->
      Logger.error("signal traps failed: #{Exception.format(kind, reason)}")
      :ok
  end

  @doc "Tells `owner` that `signal` arrived (the handler's message)."
  @spec notify(pid(), :sigterm | :sighup) :: :ok
  def notify(owner, signal) when signal in [:sigterm, :sighup] do
    send(owner, {:shutdown_signal, signal})
    :ok
  end

  @doc """
  What the trap does when `signal` arrives. The first signal tells `owner` and
  starts the watchdog that ends the VM at the deadline; a later one goes to
  the watchdog. Nothing here waits: the signal server runs every trap in turn.

  Options (tests): `:deadline_ms`, `:repeat_ms`, `:name` (the watchdog's) and
  `:halt`, a function of the exit code and `:deadline | :again`.
  """
  @spec deliver(pid(), :sigterm | :sighup, keyword()) :: :ok
  def deliver(owner, signal, opts \\ []) when is_pid(owner) and signal in [:sigterm, :sighup] do
    name = Keyword.get(opts, :name, @watchdog)

    case Process.whereis(name) do
      nil ->
        notify(owner, signal)
        arm(name, signal, opts)

      watchdog ->
        send(watchdog, {:again, signal, System.monotonic_time(:millisecond)})
        :ok
    end
  end

  @doc "The exit code for a signal: 128 + its number."
  @spec exit_code(:sigterm | :sighup) :: 129 | 143
  def exit_code(:sigterm), do: 143
  def exit_code(:sighup), do: 129

  @doc "The words a session says when a signal closes it."
  @spec words(:sigterm | :sighup) :: String.t()
  def words(:sigterm), do: "stopped by SIGTERM; the live runs were stopped."
  def words(:sighup), do: "stopped by SIGHUP (the terminal closed); the live runs were stopped."

  # A trap that raises is removed by the signal server, and the signal after
  # it would find the VM's own answer again.
  defp safely(fun) do
    fun.()
    :ok
  catch
    kind, reason ->
      Logger.error("signal handler failed: #{Exception.format(kind, reason)}")
      :ok
  end

  defp trap(signal, id, fun) do
    _ = System.untrap_signal(signal, id)

    case System.trap_signal(signal, id, fun) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.error("could not trap #{signal}: #{inspect(reason)}")
        false
    end
  end

  defp replace_default_handler do
    case :gen_event.delete_handler(:erl_signal_server, :erl_signal_handler, []) do
      {:error, :module_not_found} ->
        :ok

      _removed ->
        trap(:sigquit, :ncode_quit, fn -> :erlang.halt() end)
        trap(:sigusr1, :ncode_usr1, fn -> :erlang.halt(~c"Received SIGUSR1") end)
        :ok
    end
  end

  # The watchdog outlives the session owner on purpose: it is what ends the
  # VM when the owner cannot. Its registered name is also what marks the first
  # signal as taken.
  defp arm(name, signal, opts) do
    halt = Keyword.get(opts, :halt, &halt/2)
    deadline = Keyword.get_lazy(opts, :deadline_ms, &deadline_ms/0)
    repeat = Keyword.get(opts, :repeat_ms, @repeat_ms)
    first_at = System.monotonic_time(:millisecond)

    watchdog =
      spawn(fn -> watch(signal, first_at, first_at + deadline, repeat, halt) end)

    true = Process.register(watchdog, name)
    :ok
  end

  defp watch(signal, first_at, due, repeat, halt) do
    receive do
      {:again, _signal, at} when at - first_at < repeat ->
        watch(signal, first_at, due, repeat, halt)

      {:again, again, _at} ->
        halt.(exit_code(again), :again)
    after
      max(due - System.monotonic_time(:millisecond), 0) ->
        Logger.warning("closing on #{signal} took longer than #{due - first_at} ms")
        halt.(exit_code(signal), :deadline)
    end
  end

  # Neither way out waits for the VM's ports to drain: the other end of one
  # may be the terminal that is gone.
  defp halt(code, :again), do: :erlang.halt(code, flush: false)

  defp halt(code, :deadline) do
    SwarmCodeCLI.Release.flush_logs(@log_flush_ms)
    :erlang.halt(code, flush: false)
  end
end
