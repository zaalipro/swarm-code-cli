defmodule SwarmCode.Domain.Engine.Notifier do
  @moduledoc """
  pass 77 D-ARCH-11: the engine's notification port. A run that starts waiting
  for the user or finishes tells the platform through this behaviour, not by
  naming `SwarmCode.Domain.Desktop` — the CLI copies engine files without the desktop
  and used to rewrite those two calls by path.

  The adapter is `config :swarm_code_daemon, :engine_notifier` (the desktop sets
  `SwarmCode.Domain.Desktop`, which keeps the focus filtering and the ordering of its
  OS notices); with none configured `SwarmCode.Domain.Engine.Notifier.Noop` does
  nothing. Callers run it as owned work (`RunServer.notify_async/1`), never in a
  state owner's callback.
  """

  @callback notify_waiting(String.t()) :: any()
  @callback notify_finished(String.t()) :: any()

  @doc "A run waits for the user's answer."
  @spec waiting(String.t()) :: any()
  def waiting(text), do: impl().notify_waiting(text)

  @doc "A run finished or failed."
  @spec finished(String.t()) :: any()
  def finished(text), do: impl().notify_finished(text)

  defp impl,
    do:
      Application.get_env(
        :swarm_code_daemon,
        :engine_notifier,
        SwarmCode.Domain.Engine.Notifier.Noop
      )
end
