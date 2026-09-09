defmodule SwarmCode.Domain.Engine.AgentSup do
  @moduledoc "Per-agent supervisor: a Task.Supervisor for operations + the AgentServer. Shuts down when the AgentServer stops."
  use Supervisor

  def child_spec(args) do
    %{
      id: {:agent_sup, args.node_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :supervisor
    }
  end

  def start_link(args), do: Supervisor.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    children = [
      {Task.Supervisor, name: ops_sup(args.node_id)},
      %{
        id: :agent,
        start: {SwarmCode.Domain.Engine.AgentServer, :start_link, [args]},
        restart: :temporary,
        significant: true
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
  end

  def ops_sup(node_id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:ops_sup, node_id}}}
end
