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
    # cli020 L1: the live runtime's capability table is the synced one,
    # `SwarmCode.Domain.LLM.ProviderCaps`, started by `Domain.Runtime`.
    #
    # C-ARCH-5: the dev live runtime (`Daemon.Runtime.Run`, `LiveBackend`) owns
    # its own run supervisor; the product starts none of it, so this tree is the
    # domain's runtime alone. `Runtime.RunSupervisor` is for tests and tools that
    # want a supervised `Runtime.Run` and start it themselves.
    children = [
      SwarmCode.Domain.Runtime
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: SwarmCode.Daemon.Supervisor
    )
  end
end
