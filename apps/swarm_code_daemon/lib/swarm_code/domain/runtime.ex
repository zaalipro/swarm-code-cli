defmodule SwarmCode.Domain.Runtime do
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SwarmCode.Domain.Registry},
      {Task.Supervisor, name: SwarmCode.Domain.TaskSupervisor},
      SwarmCode.Domain.PubSub,
      SwarmCode.Domain.MarkdownCache,
      SwarmCode.Domain.UIState,
      SwarmCode.Domain.Cache,
      SwarmCode.Domain.LLM.ProviderCaps,
      SwarmCode.Domain.Engine.Questions,
      SwarmCode.Domain.Engine.RunSupervisor,
      SwarmCode.Domain.Research.Supervisor,
      SwarmCode.Domain.MCP.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
