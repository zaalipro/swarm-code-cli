defmodule SwarmCode.Domain.Engine.RunServer.Nodes do
  @moduledoc """
  The pure fold over a RunServer's node maps (spec 55 T12, 55a A-P3 step 1): what one
  flush has to write. No process, no Repo.
  """

  @type state :: %{
          nodes: %{optional(String.t()) => struct()},
          unsaved: %{optional(String.t()) => map()},
          persist_pending: MapSet.t(),
          uninserted: MapSet.t()
        }

  @doc """
  `{inserts, updates}` for `Conversations.flush_run_writes/3`. An insert carries the
  node as the state holds it merged with its `unsaved` columns — a finished op that was
  swapped for `Node.light/1` before its INSERT landed keeps its whole result (55a A8).
  """
  @spec pending_writes(state()) :: {[map()], [{String.t(), keyword()}]}
  def pending_writes(state) do
    updates =
      for id <- state.persist_pending,
          not MapSet.member?(state.uninserted, id),
          set = Map.get(state.unsaved, id),
          set not in [nil, %{}],
          do: {id, Map.to_list(set)}

    inserts =
      for id <- state.uninserted,
          node = state.nodes[id],
          node != nil,
          do: Map.merge(node_attrs(node), Map.get(state.unsaved, id, %{}))

    {inserts, updates}
  end

  @doc false
  def node_attrs(node), do: node |> Map.from_struct() |> Map.drop([:__meta__, :run, :pid])
end
