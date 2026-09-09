defmodule SwarmCode.Domain.Research.Supervisor do
  @moduledoc "Top-level DynamicSupervisor: one `Research.Sup` per running research (spec 24 §3)."
  use DynamicSupervisor

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_research(integer(), :full | :report) :: {:ok, pid()} | {:error, term()}
  def start_research(id, mode \\ :full) do
    case DynamicSupervisor.start_child(__MODULE__, {SwarmCode.Domain.Research.Sup, {id, mode}}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end
