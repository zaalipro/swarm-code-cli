defmodule SwarmCode.Domain.Engine.RunSup do
  @moduledoc "Per-run supervisor: AgentsSup + RunServer. Shuts down when the RunServer stops."
  use Supervisor

  def child_spec(args) do
    %{
      id: {:run_sup, args.run.id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :supervisor
    }
  end

  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    children = [
      Supervisor.child_spec({SwarmCode.Domain.Engine.AgentsSup, args.run.id}, restart: :temporary),
      %{
        id: :run_server,
        start: {SwarmCode.Domain.Engine.RunServer, :start_link, [args]},
        restart: :temporary,
        significant: true,
        # spec 55 T11 (55a A7): terminate/2 may sit on busy_timeout (15 s) twice.
        shutdown: 30_000
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
  end
end
