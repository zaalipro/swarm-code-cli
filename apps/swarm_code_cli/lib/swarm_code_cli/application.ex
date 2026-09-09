defmodule SwarmCodeCLI.Application do
  @moduledoc false
  use Application

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

  defp run_release_session do
    try do
      SwarmCodeCLI.Release.PersistedSession.run()
    after
      :init.stop()
    end
  end
end
