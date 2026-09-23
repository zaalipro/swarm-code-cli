defmodule SwarmCode.Domain.Research.Events do
  @moduledoc """
  PubSub for deep research (spec 24 §2.3): `"research"` carries every change so
  the list page and the rail badge stay live; `"research:<id>"` carries only
  `{:research_report, id, outcome}` for the page showing that research.

  spec 73 T85: `broadcast/3` used to publish every event on both topics, and
  the detail page subscribes to both — so the research it showed ran every
  step and row handler twice per event.
  """

  @all "research"

  def topic, do: @all
  def topic(id), do: @all <> ":" <> to_string(id)

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, @all)
  def subscribe(id), do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, topic(id))

  # spec 73 T93: `unsubscribe/0` had no caller.
  def unsubscribe(id), do: SwarmCode.Domain.PubSub.unsubscribe(SwarmCode.Domain.PubSub, topic(id))

  @doc """
  Sends `event` to the all-researches topic and — unless `ui: false` — nudges
  the `"ui"` topic so every page's rail badge refreshes, the same route a
  workflow run's badge already takes.
  """
  def broadcast(_id, event, opts \\ []) do
    SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, @all, event)
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
