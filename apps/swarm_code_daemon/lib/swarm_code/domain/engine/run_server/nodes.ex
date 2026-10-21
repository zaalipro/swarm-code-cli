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

  @typedoc """
  What one flush sends (pass 77 D-ARCH-2): the writes themselves, plus the exact column values
  it took from `unsaved` and the nodes it counted as not yet inserted, so the acknowledgment
  clears only what was sent.
  """
  @type batch :: %{
          inserts: [map()],
          updates: [{String.t(), keyword()}],
          uninserted: MapSet.t(),
          submitted: %{optional(String.t()) => map()}
        }

  @doc """
  pass 77 D-ARCH-2 (step 1): the flush as an immutable value. `inserts`/`updates` are exactly
  `pending_writes/1`; `submitted` is a copy of the `unsaved` columns of the nodes in
  `persist_pending`, `uninserted` the set as it was. Nothing in it refers to the state again,
  so the write can be done by another process later and acknowledged with `ack_batch/2`.
  """
  @spec build_batch(state()) :: batch()
  def build_batch(state) do
    {inserts, updates} = pending_writes(state)

    %{
      inserts: inserts,
      updates: updates,
      uninserted: state.uninserted,
      submitted: Map.take(state.unsaved, MapSet.to_list(state.persist_pending))
    }
  end

  @doc """
  pass 77 D-ARCH-2 (step 1): the batch landed. A column is dropped from `unsaved` only when
  its value is still the one that was sent; one that changed since stays, and so does its node
  in `persist_pending`. A node that was first marked `uninserted` after the batch was built
  stays `uninserted`. With nothing changed in between (today's synchronous flush) this is
  exactly "drop what was pending and clear both sets".
  """
  @spec ack_batch(state(), batch()) :: state()
  def ack_batch(state, batch) do
    unsaved =
      Enum.reduce(batch.submitted, state.unsaved, fn {id, sent}, acc ->
        case Map.get(acc, id) do
          nil ->
            acc

          current ->
            left =
              Map.reject(current, fn {key, value} ->
                Map.has_key?(sent, key) and Map.get(sent, key) == value
              end)

            if left == %{}, do: Map.delete(acc, id), else: Map.put(acc, id, left)
        end
      end)

    %{
      state
      | unsaved: unsaved,
        persist_pending: MapSet.filter(state.persist_pending, &Map.has_key?(unsaved, &1)),
        uninserted: MapSet.difference(state.uninserted, batch.uninserted)
    }
  end

  @doc false
  def node_attrs(node), do: node |> Map.from_struct() |> Map.drop([:__meta__, :run, :pid])
end
