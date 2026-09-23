# spec 70 B3
defmodule SwarmCode.Domain.LSP.Supervisor do
  @moduledoc "Owns one LSP client process per {project, language}."
  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      {DynamicSupervisor, name: SwarmCode.Domain.LSP.ClientSup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
