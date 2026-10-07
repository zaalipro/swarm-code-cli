defmodule SwarmCode.Domain.MCP.Supervisor do
  @moduledoc "Owns the MCP tool tables and one client process per enabled server."
  use Supervisor

  alias SwarmCode.Domain.MCP

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    MCP.ensure_tables()

    children = [
      # pass74 (spec 74) UX-10: the login shell's PATH, read once at boot for
      # stdio servers; before the clients, which wait for it without blocking.
      SwarmCode.Domain.MCP.LoginPath,
      # pass74 (spec 74) BUGS-24: clients are independent. The default 3
      # restarts in 5 s let one crash-looping server take ClientSup down, and
      # it came back empty — every other server gone until the next boot.
      {DynamicSupervisor,
       name: SwarmCode.Domain.MCP.ClientSup,
       strategy: :one_for_one,
       max_restarts: 50,
       max_seconds: 5}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
