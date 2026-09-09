defmodule SwarmCode.Domain.Notifications do
  @moduledoc "Semantic notifications for attached terminal clients."
  alias SwarmCode.Domain.PubSub
  def notify(message), do: publish(:info, message)
  def notify_waiting(message), do: publish(:waiting, message)
  def notify_finished(message), do: publish(:finished, message)

  defp publish(kind, message),
    do:
      PubSub.broadcast(
        PubSub,
        "notifications",
        {:notification, kind, String.slice(to_string(message), 0, 1024)}
      )
end
