defmodule SwarmCodeCLI.Application do
  @moduledoc false
  use Application

  # The packaged entry points a release may run, chosen by `SWARM_RELEASE_MODE`
  # from this fixed table (runtime input never names a module). `tui` is the
  # default whenever `SWARM_RELEASE_TUI=1`. Each entry returns the exit status.
  @entries %{
    "tui" => {SwarmCodeCLI.Release.PersistedSession, :run},
    "headless" => {SwarmCodeCLI.Release.Headless, :run},
    "plain" => {SwarmCodeCLI.Release.Headless, :run_plain}
  }

  @impl true
  def start(_type, _args) do
    children =
      if System.get_env("SWARM_RELEASE_TUI") == "1" do
        [
          %{
            id: SwarmCodeCLI.ReleaseSession,
            start: {Task, :start_link, [fn -> run_release_session() end]},
            restart: :temporary
          }
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: SwarmCodeCLI.Supervisor)
  end

  # pass70 B3: the release exits with the session's status (0 done, 1 failure,
  # 2 usage, 3 startup refused) and never prints a stack trace: the entry point
  # reports its own failures, and anything that still escapes is one line.
  defp run_release_session do
    status =
      try do
        run_entry(System.get_env("SWARM_RELEASE_MODE") || "tui")
      catch
        _kind, _reason ->
          IO.puts(:stderr, "swarmcode: stopped unexpectedly. Run it again; your work is saved.")
          1
      end

    System.stop(if(is_integer(status) and status in 0..255, do: status, else: 1))
  end

  defp run_entry(mode) do
    with {module, function} <- Map.get(@entries, mode),
         true <- Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      _ ->
        IO.puts(
          :stderr,
          "swarmcode: this build has no #{inspect(mode)} mode. Run swarmcode --help."
        )

        2
    end
  end
end
