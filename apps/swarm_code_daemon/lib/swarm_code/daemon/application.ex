defmodule SwarmCode.Daemon.Application do
  @moduledoc """
  Owns process-local runtime infrastructure independently of any client.

  Canonical storage, migrations and the service listener must be started through
  the guarded foundation handoff. Starting this application alone opens no user
  database and admits no coding work.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SwarmCode.LLM.ProviderCaps,
      SwarmCode.Daemon.Runtime.RunSupervisor
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SwarmCode.Daemon.Supervisor
    )
  end
end
