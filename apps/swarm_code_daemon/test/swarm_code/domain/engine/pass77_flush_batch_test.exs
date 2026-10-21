defmodule SwarmCode.Domain.Engine.Pass77FlushBatchTest do
  @moduledoc """
  pass 77 D-ARCH-2 (step 1): a flush is an immutable batch, acknowledged by value.
  Pure, on synthetic state maps: what changed after the batch was built stays dirty,
  what was sent is cleared, and with nothing in between it is exactly the old
  "drop everything that was pending".
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Conversations.Node
  alias SwarmCode.Domain.Engine.RunServer.Nodes

  defp op_node(id, attrs \\ []),
    do:
      struct(
        %Node{id: id, run_id: "r", kind: "op", op_type: "read_file", status: "running"},
        attrs
      )

  defp state(attrs) do
    Map.merge(
      %{
        nodes: %{"a" => op_node("a"), "b" => op_node("b")},
        unsaved: %{},
        persist_pending: MapSet.new(),
        uninserted: MapSet.new()
      },
      Map.new(attrs)
    )
  end

  test "build_batch/1 carries the writes of pending_writes/1 and what it took" do
    s =
      state(
        unsaved: %{"a" => %{status: "done", progress: 100}, "b" => %{detail: "x"}},
        persist_pending: MapSet.new(["a"]),
        uninserted: MapSet.new(["b"])
      )

    batch = Nodes.build_batch(s)

    assert {batch.inserts, batch.updates} == Nodes.pending_writes(s)
    assert batch.uninserted == MapSet.new(["b"])
    # Only the nodes in `persist_pending` are acknowledged by value.
    assert batch.submitted == %{"a" => %{status: "done", progress: 100}}
  end

  test "with nothing changed in between, the ack drops everything that was pending" do
    s =
      state(
        unsaved: %{"a" => %{status: "done"}, "b" => %{detail: "x"}},
        persist_pending: MapSet.new(["a", "b"]),
        uninserted: MapSet.new()
      )

    acked = Nodes.ack_batch(s, Nodes.build_batch(s))

    assert acked.unsaved == %{}
    assert acked.persist_pending == MapSet.new()
    assert acked.uninserted == MapSet.new()
  end

  test "a column that changed after the build stays dirty and so does its node" do
    s =
      state(
        unsaved: %{"a" => %{status: "running", progress: 10}},
        persist_pending: MapSet.new(["a"])
      )

    batch = Nodes.build_batch(s)

    # While the write was out, the node moved on: progress changed, a new column appeared.
    s = %{s | unsaved: %{"a" => %{status: "running", progress: 40, detail: "later"}}}

    acked = Nodes.ack_batch(s, batch)

    # `status` was sent unchanged and is cleared; the other two are still owed.
    assert acked.unsaved == %{"a" => %{progress: 40, detail: "later"}}
    assert MapSet.member?(acked.persist_pending, "a")
  end

  test "an unchanged column is acknowledged even when its neighbour is not" do
    s =
      state(
        unsaved: %{"a" => %{status: "done"}, "b" => %{progress: 1}},
        persist_pending: MapSet.new(["a", "b"])
      )

    batch = Nodes.build_batch(s)

    s = %{s | unsaved: %{"a" => %{status: "done"}, "b" => %{progress: 2}}}
    acked = Nodes.ack_batch(s, batch)

    assert acked.unsaved == %{"b" => %{progress: 2}}
    assert acked.persist_pending == MapSet.new(["b"])
  end

  test "a node first marked uninserted after the build stays uninserted" do
    s =
      state(
        unsaved: %{"a" => %{status: "done"}},
        persist_pending: MapSet.new(["a"]),
        uninserted: MapSet.new(["a"])
      )

    batch = Nodes.build_batch(s)

    s = %{
      s
      | uninserted: MapSet.new(["a", "b"]),
        unsaved: Map.put(s.unsaved, "b", %{detail: "y"})
    }

    acked = Nodes.ack_batch(s, batch)

    assert acked.uninserted == MapSet.new(["b"])
    # `b` was never sent: nothing of it is acknowledged.
    assert acked.unsaved == %{"b" => %{detail: "y"}}
  end

  test "a node whose unsaved columns were dropped meanwhile is not resurrected" do
    s = state(unsaved: %{"a" => %{status: "done"}}, persist_pending: MapSet.new(["a"]))
    batch = Nodes.build_batch(s)

    s = %{s | unsaved: %{}}
    acked = Nodes.ack_batch(s, batch)

    assert acked.unsaved == %{}
    assert acked.persist_pending == MapSet.new()
  end

  test "an uninserted-only node keeps its unsaved row, exactly as the old flush left it" do
    s = state(unsaved: %{"b" => %{detail: "x"}}, uninserted: MapSet.new(["b"]))
    acked = Nodes.ack_batch(s, Nodes.build_batch(s))

    assert acked.uninserted == MapSet.new()
    assert acked.unsaved == %{"b" => %{detail: "x"}}
  end
end
