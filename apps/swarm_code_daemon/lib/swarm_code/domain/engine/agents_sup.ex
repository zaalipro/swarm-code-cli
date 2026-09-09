defmodule SwarmCode.Domain.Engine.AgentsSup do
  @moduledoc "Per-run DynamicSupervisor holding one AgentSup per agent."
  use DynamicSupervisor

  def start_link(run_id), do: DynamicSupervisor.start_link(__MODULE__, [], name: via(run_id))

  @impl true
  def init([]), do: DynamicSupervisor.init(strategy: :one_for_one)

  def via(run_id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:agents_sup, run_id}}}

  @spec start_agent(String.t(), map()) :: DynamicSupervisor.on_start_child()
  def start_agent(run_id, args),
    do: DynamicSupervisor.start_child(via(run_id), {SwarmCode.Domain.Engine.AgentSup, args})

  @spec stop_agent(String.t(), pid()) :: :ok | {:error, :not_found}
  def stop_agent(run_id, pid), do: DynamicSupervisor.terminate_child(via(run_id), pid)
end
