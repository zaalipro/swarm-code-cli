defmodule SwarmCode.Domain.MCP.Supervisor do
  @moduledoc "Owns the MCP tool tables and one client process per enabled server."
  use Supervisor

  alias SwarmCode.Domain.MCP

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    MCP.ensure_tables()

    children = [
      {DynamicSupervisor, name: SwarmCode.Domain.MCP.ClientSup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
