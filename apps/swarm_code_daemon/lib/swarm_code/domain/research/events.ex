defmodule SwarmCode.Domain.Research.Events do
  @moduledoc """
  PubSub for deep research (spec 24 §2.3): `"research"` carries every change so
  the list page and the rail badge stay live, `"research:<id>"` carries the same
  events plus step updates for one detail page.
  """

  @all "research"

  def topic, do: @all
  def topic(id), do: @all <> ":" <> to_string(id)

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, @all)
  def subscribe(id), do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, topic(id))

  def unsubscribe, do: SwarmCode.Domain.PubSub.unsubscribe(SwarmCode.Domain.PubSub, @all)
  def unsubscribe(id), do: SwarmCode.Domain.PubSub.unsubscribe(SwarmCode.Domain.PubSub, topic(id))

  @doc """
  Sends `event` to the all-researches topic and to this research's own, and —
  unless `ui: false` — nudges the `"ui"` topic so every page's rail badge
  refreshes, the same route a workflow run's badge already takes.
  """
  def broadcast(id, event, opts \\ []) do
    SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, @all, event)
    SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, topic(id), event)
    # Spec 39 §1.7: the rail badge counts running researches; only a status
    # change can move it.
    if Keyword.get(opts, :ui, true),
      do: SwarmCode.Domain.Engine.Events.ui_broadcast({:research_runs_changed})

    :ok
  end

  @doc "Spec 39 §1.5: the HTML pass rebuilt from the page finished, one way or the other."
  def report_built(id, outcome) do
    SwarmCode.Domain.PubSub.broadcast(
      SwarmCode.Domain.PubSub,
      topic(id),
      {:research_report, id, outcome}
    )

    :ok
  end
end
