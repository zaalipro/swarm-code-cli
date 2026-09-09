defmodule SwarmCodeCLI.UI.ReducerWatchTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Reducer, Init, Size, Capabilities, OrderedIdSet, ChunkDeque}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}

  def initial do
    size = %Size{columns: 150, rows: 40}

    Reducer.init(
      struct(Init,
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch",
        destination: {:conversation, "c"},
        id_prefix: "test",
        now: 100
      )
    )
  end

  def ready(state) do
    watch = state.watches.workspace

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{},
      through_sequence: 10
    }

    %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 10,
      sequence: nil,
      body: body
    }
  end

  test "watch gaps emit one resync and replacement preserves presentation state" do
    {state, effects} = initial()
    assert length(effects) == 2
    {state, []} = Reducer.update(state, {:data, ready(state)})
    assert state.watches.workspace.sequence == 10

    gap = %{
      ready(state)
      | kind: :delta,
        revision: 12,
        sequence: 12,
        body: %Delta{kind: :snapshot_required, sequence: 12, revision: 12}
    }

    {next, [{:query, request}]} = Reducer.update(state, {:data, gap})
    assert request.kind == {:resync_watch, state.watches.workspace.watch_ref}
    assert next.watches.workspace.status == :resyncing
    assert Reducer.update(next, {:data, gap}) == {next, []}

    {replaced, []} =
      Reducer.update(
        next,
        {:data, %{ready(next) | revision: 13, body: %{ready(next).body | through_sequence: 13}}}
      )

    assert replaced.scrolls == state.scrolls
    assert replaced.drafts == state.drafts
    assert replaced.focus == state.focus
    assert replaced.watches.workspace.status == :ready
  end

  test "navigation invalidates generation and ignores late watch facts" do
    {state, _} = initial()
    old = ready(state)

    {next, [{:unwatch, _}, {:watch, watch}]} =
      Reducer.update(state, {:navigate, {:conversation, "b"}})

    assert watch.generation == state.watches.workspace.generation + 1
    assert next.watches.workspace.status == :frozen
    assert Reducer.update(next, {:data, old}) == {next, []}
  end

  test "workspace metadata advances without touching the draft or transcript and ignores stale revisions" do
    {state, _} = initial()
    {state, []} = Reducer.update(state, {:data, ready(state)})
    {state, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, "unsent work"}})
    body = struct(DTO.WorkspaceMetadata, conversation_id: "c", mode: :plan, chat_model: "planner")

    delta = %Delta{
      kind: :workspace_metadata,
      conversation_id: "c",
      sequence: 11,
      revision: 11,
      body: body
    }

    delivery = %{ready(state) | kind: :delta, sequence: 11, revision: 11, body: delta}
    {updated, []} = Reducer.update(state, {:data, delivery})
    assert updated.read_model.snapshots.workspace.mode == :plan
    assert updated.drafts == state.drafts
    assert updated.read_model.transcript == state.read_model.transcript
    stale_body = struct(DTO.WorkspaceMetadata, conversation_id: "c", mode: :build)

    stale = %{
      delivery
      | sequence: 12,
        revision: 9,
        body: %{delta | sequence: 12, revision: 9, body: stale_body}
    }

    {unchanged, []} = Reducer.update(updated, {:data, stale})
    assert unchanged.read_model.snapshots.workspace.mode == :plan
    assert unchanged.watches.workspace.sequence == 12
  end

  test "bounded ordered IDs and chunks do not silently drop bytes or identities" do
    ids =
      Enum.reduce(1..512, OrderedIdSet.new(), fn n, acc ->
        {:ok, result} = OrderedIdSet.put(acc, "#{n}")
        result
      end)

    assert {:ok, ^ids} = OrderedIdSet.put(ids, "1")
    assert {:error, :snapshot_required, ^ids} = OrderedIdSet.put(ids, "513")
    assert hd(OrderedIdSet.to_list(ids)) == "1"
    chunks = ChunkDeque.new(4)
    assert {:ok, chunks} = ChunkDeque.append(chunks, {"item", :text, "attempt"}, "abc")

    assert {:error, :snapshot_required, ^chunks} =
             ChunkDeque.append(chunks, {"item", :text, "attempt"}, "de")

    assert ChunkDeque.materialize(chunks, {"item", :text, "attempt"}) == "abc"
  end
end
