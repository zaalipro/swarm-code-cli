defmodule SwarmCodeCLI.Release.Signals do
  @moduledoc """
  cli020 B9 (bugs-5): SIGTERM and SIGHUP close a session the normal way.

  Before, both killed the VM at once: no `Daemon.Shutdown`, live runs left
  `running` in the database, the private socket folder left in /tmp and the
  terminal not restored. `install/1` traps both (`System.trap_signal/3`); the
  handler sends `{:shutdown_signal, sig}` to the session owner, which runs
  its close path (stop the live runs, stop the applications, remove the
  private folder) and exits `exit_code/1` (143 for SIGTERM, 129 for SIGHUP,
  the shell's 128 + signal number). A close that takes longer than 10 s is
  cut short by `System.halt/1` with the same code.

  SIGINT cannot be trapped (`os:set_signal(sigint, handle)` raises `badarg`
  on OTP 28) and stays under `+Bd` (`rel/env.sh.eex`, unchanged).
  """

  require Logger

  @signals %{sigterm: :ncode_term, sighup: :ncode_hup}
  @deadline_ms 10_000

  @doc "Traps SIGTERM and SIGHUP for `owner`; safe to call again (the newest owner wins)."
  @spec install(pid()) :: :ok
  def install(owner \\ self()) when is_pid(owner) do
    Enum.each(@signals, fn {signal, id} ->
      _ = System.untrap_signal(signal, id)

      case System.trap_signal(signal, id, fn -> handle(owner, signal) end) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("could not trap #{signal}: #{inspect(reason)}")
      end
    end)
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

  @doc "The exit code for a signal: 128 + its number."
  @spec exit_code(:sigterm | :sighup) :: 129 | 143
  def exit_code(:sigterm), do: 143
  def exit_code(:sighup), do: 129

  @doc "The words a session says when a signal closes it."
  @spec words(:sigterm | :sighup) :: String.t()
  def words(:sigterm), do: "stopped by SIGTERM; the live runs were stopped."
  def words(:sighup), do: "stopped by SIGHUP (the terminal closed); the live runs were stopped."

  # Runs in the signal server: say it, then make sure the VM ends even if the
  # close path hangs on a terminal that is gone.
  defp handle(owner, signal) do
    notify(owner, signal)
    code = exit_code(signal)

    spawn(fn ->
      receive do
      after
        @deadline_ms -> System.halt(code)
      end
    end)

    :ok
  end
end
