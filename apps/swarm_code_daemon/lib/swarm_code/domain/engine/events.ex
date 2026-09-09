defmodule SwarmCode.Domain.Engine.Events do
  @moduledoc "PubSub topics and helpers used by the engine."

  def topic(conversation_id), do: "conversation:" <> conversation_id

  def subscribe(conversation_id),
    do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, topic(conversation_id))

  def unsubscribe(conversation_id),
    do: SwarmCode.Domain.PubSub.unsubscribe(SwarmCode.Domain.PubSub, topic(conversation_id))

  def broadcast(conversation_id, event),
    do: SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, topic(conversation_id), event)

  # spec 55 T2: idempotent — the `UiTopic` hook and a page's own mount may both call it.
  def ui_subscribe do
    SwarmCode.Domain.PubSub.unsubscribe(SwarmCode.Domain.PubSub, "ui")
    SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "ui")
  end

  def ui_broadcast(event),
    do: SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, "ui", event)
end
