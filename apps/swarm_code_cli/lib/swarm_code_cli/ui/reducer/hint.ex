defmodule SwarmCodeCLI.UI.Reducer.Hint do
  @moduledoc """
  Hint mode's state (pass 72, P7): entering it computes the badges from the
  side panel's visible entries, a typed key resolves against them.

  The panel's order is owner P's `Projector.PanelOrder.entries/1`: an entry
  exists exactly when its row is on screen (the strip's, under 120 columns).
  """

  alias SwarmCodeCLI.UI.Hint
  alias SwarmCodeCLI.UI.Projector.PanelOrder

  @waiting_states [:waiting_approval, :waiting_question]

  @doc "The panel's visible entries in display order (owner P's `PanelOrder.entries/1`)."
  @spec entries(map()) :: [Hint.entry()]
  def entries(state), do: PanelOrder.entries(state)

  @doc """
  A run's agents in the panel's run-block order (K5: "with the Lead first"):
  the lead, then each agent followed by the agents it spawned, siblings by
  start. pass72 G2 (QA Q2): the needs-you band's rows no longer lead the
  order, so the Lead stays first and the order does not move as requests
  come and go.
  """
  def agents(state, run_id) do
    agents =
      state.read_model.agents
      |> Map.values()
      |> Enum.filter(&(&1.run_id == run_id and &1.state != :superseded))
      |> Enum.sort_by(&{root_rank(&1), &1.depth || 0, &1.started_at || 0, &1.id})

    ids = MapSet.new(agents, & &1.id)

    # The returned agents carry the resolved parent, so the overlay's tree
    # draws the same nesting this order follows.
    children =
      agents
      |> Enum.map(&%{&1 | parent_id: parent_in(&1, ids, agents)})
      |> Enum.group_by(& &1.parent_id)

    children
    |> Map.get(nil, [])
    |> Enum.flat_map(&subtree(&1, children, MapSet.new()))
  end

  defp root_rank(agent), do: if(agent.role == :lead or agent.parent_id == nil, do: 0, else: 1)

  # An agent whose parent is not in the run (or is itself) hangs from the root.
  # pass72 G21: a worker's persisted parent_id names the Lead's spawn_agent
  # operation, not the Lead, so it falls back to depth: the latest agent one
  # level up that started no later than it (the panel nests by depth too).
  defp parent_in(%{parent_id: parent, id: id} = agent, ids, agents) do
    cond do
      parent != id and MapSet.member?(ids, parent) -> parent
      (agent.depth || 0) > 0 -> by_depth(agent, agents)
      true -> nil
    end
  end

  defp by_depth(agent, agents) do
    up = Enum.filter(agents, &((&1.depth || 0) == agent.depth - 1 and &1.id != agent.id))
    started = agent.started_at || 0

    case Enum.filter(up, &((&1.started_at || 0) <= started)) do
      [] -> up |> List.first() |> then(&(&1 && &1.id))
      before -> List.last(before).id
    end
  end

  defp subtree(agent, children, seen) do
    if MapSet.member?(seen, agent.id) do
      []
    else
      seen = MapSet.put(seen, agent.id)
      [agent | Enum.flat_map(Map.get(children, agent.id, []), &subtree(&1, children, seen))]
    end
  end

  @doc "Whether something of `agent`'s waits on the user."
  def needs_you?(state, agent) do
    agent.state in @waiting_states or pending(state, agent.run_id, agent.id) != []
  end

  @doc "The pending requests of one agent, oldest first."
  def pending(state, run_id, node_id) do
    state.read_model.interactions
    |> Map.values()
    |> Enum.filter(fn item ->
      item.state == :pending and item.run_id == run_id and
        (item.node_id == node_id or agent_of(item) == node_id)
    end)
    |> Enum.sort_by(&{&1.created_at || 0, &1.id})
  end

  defp agent_of(%{approval: %{} = approval}), do: Map.get(approval, :agent_id)
  defp agent_of(%{question: %{} = question}), do: Map.get(question, :agent_id)
  defp agent_of(_item), do: nil

  @doc "The hint state for `state`, or nil when the panel shows nothing to open."
  def open(state) do
    labels = Hint.labels(entries(state))
    if labels == %{}, do: nil, else: %{labels: labels, typed: ""}
  end
end
