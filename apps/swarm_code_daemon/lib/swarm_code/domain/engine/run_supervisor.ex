defmodule SwarmCode.Domain.Engine.RunSupervisor do
  @moduledoc "Top-level DynamicSupervisor: one RunSup child per run."
  use DynamicSupervisor

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_run(map()) :: DynamicSupervisor.on_start_child()
  def start_run(args),
    do: DynamicSupervisor.start_child(__MODULE__, {SwarmCode.Domain.Engine.RunSup, args})
end
