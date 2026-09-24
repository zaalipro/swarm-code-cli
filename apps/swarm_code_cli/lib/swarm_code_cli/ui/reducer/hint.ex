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
  A run's agents in panel order: the ones the panel draws in its order, then
  the folded rest, the lead first and then by start.
  """
  def agents(state, run_id) do
    drawn =
      state
      |> entries()
      |> Enum.flat_map(fn
        {:agent, ^run_id, node, _} -> [node]
        _ -> []
      end)
      |> Enum.with_index()
      |> Map.new()

    state.read_model.agents
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run_id and &1.state != :superseded))
    |> Enum.sort_by(
      &{Map.get(drawn, &1.id, map_size(drawn)),
       if(&1.role == :lead or &1.parent_id == nil, do: 0, else: 1), &1.depth, &1.started_at || 0,
       &1.id}
    )
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
