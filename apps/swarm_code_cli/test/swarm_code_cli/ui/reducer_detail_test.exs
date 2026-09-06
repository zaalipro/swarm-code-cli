defmodule SwarmCodeCLI.UI.ReducerDetailTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Reducer, Init, Size, Capabilities}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  test "known detail uses exact run scope, pages returned offsets, retains content on failure" do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"}
      })

    ref = %DTO.DetailRef{id: "detail", total_bytes: 100_000}

    item = %DTO.TranscriptItem{
      id: "item",
      node_id: "node",
      conversation_id: "c",
      run_id: "run",
      attempt_id: "attempt",
      text: "preview",
      detail_ref: ref
    }

    state = %{state | read_model: %{state.read_model | transcript: %{"item" => item}}}
    assert Reducer.update(state, {:open_detail, "wrong", "detail"}) == {state, []}
    assert Reducer.update(state, {:open_detail, "run", "unknown"}) == {state, []}

    {opened, [{:watch, watch}, {:query, request}]} =
      Reducer.update(state, {:open_detail, "run", "detail"})

    assert watch.scope.kind == :run
    assert request.scope == watch.scope
    assert request.kind == {:query_detail, "detail", 0, 16_384}
    assert request.expected_response == :detail_window

    page = %DTO.DetailWindow{
      detail_ref: ref,
      request_id: request.request_id,
      text: String.duplicate("a", 16384),
      next_offset: 16384
    }

    delivery = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: page
    }

    {loaded, []} = Reducer.update(opened, {:data, delivery})
    assert loaded.detail.window == page
    {paging, [{:query, next}]} = Reducer.update(loaded, {:detail_page, :next})
    assert next.kind == {:query_detail, "detail", 16384, 16384}
    assert Reducer.update(paging, {:detail_page, :next}) == {paging, []}
    error = SwarmCodeCLI.UI.DataSource.AdmissionError.new(:source_unavailable)
    failed = %DTO.DetailWindow{request_id: next.request_id, state: :error, error: error}

    {failed_state, []} =
      Reducer.update(paging, {:data, %{delivery | request_id: next.request_id, body: failed}})

    assert failed_state.detail.status == :error
    assert failed_state.detail.window == page
    {closing, effects} = Reducer.update(failed_state, :close_top_layer)
    assert {:unwatch, watch.watch_ref} in effects
    assert closing.detail == nil
  end

  test "closing detail nested over an inspector restores the underlying watch and focus" do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{size: size, capabilities: %Capabilities{size: size}, source_epoch: "e"})

    {state, [{:watch, _}]} =
      Reducer.update(state, {:open_layer, {:run_inspector, "older", :agents}})

    ref = %DTO.DetailRef{id: "detail", total_bytes: 100_000}

    item = %DTO.TranscriptItem{
      id: "item",
      node_id: "node",
      conversation_id: "c",
      run_id: "run",
      attempt_id: "attempt",
      text: "preview",
      detail_ref: ref
    }

    state = %{state | read_model: %{state.read_model | transcript: %{"item" => item}}}
    {detail, _} = Reducer.update(state, {:open_detail, "run", "detail"})
    {back, effects} = Reducer.update(detail, :close_top_layer)
    assert [{:run_inspector, "older", :agents}] == back.layers
    assert back.focus == "inspector"
    assert back.watches.inspector.scope.id == "older"
    assert Enum.any?(effects, &match?({:watch, _}, &1))
  end
end
