defmodule SwarmCode.Domain.Research.Sup do
  @moduledoc """
  One research's supervisor. The `Research.Server` is the significant child, so
  the whole subtree goes away with it (spec 24 §3).
  """
  use Supervisor

  def child_spec({id, mode}) do
    %{
      id: {:research_sup, id},
      start: {__MODULE__, :start_link, [{id, mode}]},
      restart: :temporary,
      type: :supervisor
    }
  end

  def start_link({id, mode}), do: Supervisor.start_link(__MODULE__, {id, mode})

  @impl true
  def init({id, mode}) do
    children = [
      %{
        id: :server,
        start: {SwarmCode.Domain.Research.Server, :start_link, [{id, mode}]},
        restart: :temporary,
        significant: true
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, auto_shutdown: :any_significant)
  end
end
