defmodule SwarmCodeCLI.UI.ReducerAttemptPagingTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{ReadModel, ChunkDeque, Reducer, Init, ScrollMetrics, Size, Capabilities}
  alias SwarmCodeCLI.UI.{Input, Keymap}
  alias SwarmCodeCLI.UI.Projector.RunsDashboard
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delta, Delivery, AdmissionError}

  def model do
    item = %DTO.TranscriptItem{
      id: "item",
      run_id: "run",
      conversation_id: "c",
      node_id: "node",
      attempt_id: "initial",
      text: "old",
      reasoning: "old reasoning"
    }

    ReadModel.snapshot(%ReadModel{}, :workspace, %DTO.TranscriptWindow{items: [item]})
  end

  def delta(kind, channel, attempt, revision, text),
    do: %Delta{
      kind: kind,
      entity_id: "item",
      run_id: "run",
      conversation_id: "c",
      channel: channel,
      attempt_id: attempt,
      revision: revision,
      sequence: revision,
      text: text
    }

  test "repeated attempts retain only current text and reasoning chunk keys" do
    result =
      Enum.reduce(1..100, model(), fn n, current ->
        {:ok, reset, _, _} =
          ReadModel.delta(
            current,
            :workspace,
            delta(:stream_reset, :text, "attempt-#{n}", n * 2 - 1, "new")
          )

        assert ReadModel.transcript_item(reset, "item").reasoning == ""

        {:ok, streamed, _, _} =
          ReadModel.delta(
            reset,
            :workspace,
            delta(:stream_append, :reasoning, "attempt-#{n}", n * 2, "reason")
          )

        assert map_size(streamed.chunks.entries) == 2

        assert Enum.all?(Map.keys(streamed.chunks.entries), fn {_, _, attempt} ->
                 attempt == "attempt-#{n}"
               end)

        streamed
      end)

    assert ReadModel.transcript_item(result, "item").text == "new"
    assert ReadModel.transcript_item(result, "item").reasoning == "reason"
  end

  test "same attempt channel reset retains the other current channel and other entities" do
    {:ok, chunks} = ChunkDeque.append(ChunkDeque.new(), {"item", :reasoning, "current"}, "keep")
    {:ok, chunks} = ChunkDeque.append(chunks, {"other", :reasoning, "older"}, "other")
    {:ok, chunks} = ChunkDeque.reset(chunks, {"item", :text, "current"}, "new")
    assert ChunkDeque.materialize(chunks, {"item", :reasoning, "current"}) == "keep"
    {:ok, next} = ChunkDeque.reset(chunks, {"item", :text, "newer"}, "next")
    assert ChunkDeque.materialize(next, {"item", :reasoning, "current"}) == ""
    assert ChunkDeque.materialize(next, {"other", :reasoning, "older"}) == "other"
  end

  # The scrolling navigator that used to own this contract is gone; the Ctrl-G
  # dashboard that replaced it windows the same shell list, so the contract moved
  # onto it: one PageDown is one screenful, no more and no less.
  test "the runs dashboard pages by its visible capacity without skipping a run" do
    size = %Size{columns: 100, rows: 24}

    {state, _} =
      Reducer.init(%Init{size: size, capabilities: %Capabilities{size: size}, source_epoch: "e"})

    rows = for n <- 1..60, do: %DTO.RunSummary{id: "r#{n}", conversation_id: "c"}

    body = %DTO.ShellSnapshot{
      runs: rows,
      connection: %DTO.Connection{source_epoch: "e"},
      counts: %DTO.Counts{}
    }

    state = %{state | read_model: ReadModel.snapshot(state.read_model, :shell, body)}
    {dash, _} = Reducer.update(state, {:open_layer, {:runs_dashboard, "dash"}})

    ids = RunsDashboard.ids(dash)
    capacity = length(RunsDashboard.window(dash).shown)
    assert capacity > 1
    assert capacity < 60
    assert dash.focus == List.first(ids)

    {:ok, action} = Keymap.resolve(Input.key(:page_down), dash, %{})
    {page, _} = Reducer.update(dash, action)

    # Exactly one capacity on: the run after the last one the window held, so
    # nothing between the two pages is stepped over.
    assert page.focus == Enum.at(ids, capacity)
    window = RunsDashboard.window(page)
    assert page.focus in Enum.map(window.shown, & &1.id)
    assert window.first + length(window.shown) == capacity + 1

    {:ok, back_action} = Keymap.resolve(Input.key(:page_up), page, %{})
    {back, _} = Reducer.update(page, back_action)
    assert back.focus == List.first(ids)
    assert RunsDashboard.window(back).first == 0
  end

  test "failed recovery clears correlation and explicit page retry admits a new watch resync" do
    size = %Size{columns: 100, rows: 24}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"}
      })

    watch = state.watches.workspace

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    ready = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: body
    }

    {state, []} = Reducer.update(state, {:data, ready})

    gap = %{
      ready
      | kind: :delta,
        revision: 2,
        sequence: 2,
        body: %Delta{kind: :snapshot_required, revision: 2, sequence: 2}
    }

    {pending, [{:query, request}]} = Reducer.update(state, {:data, gap})
    error = %{ready | kind: :error, revision: nil, body: AdmissionError.new(:source_unavailable)}
    {failed, []} = Reducer.update(pending, {:data, error})
    assert failed.watches.workspace.status == :error
    assert failed.watches.workspace.resync_request_id == nil
    refute Map.has_key?(failed.requests, request.request_id)
    {retry, [{:query, next}]} = Reducer.update(failed, {:retry_page, :workspace, :after})
    assert next.kind == {:resync_watch, watch.watch_ref}
    assert next.request_id != request.request_id
    assert retry.watches.workspace.status == :resyncing
    assert Reducer.update(retry, {:retry_page, :workspace, :after}) == {retry, []}
  end

  test "Main PageDown starts at the first row after the projected transcript window" do
    size = %Size{columns: 100, rows: 24}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"}
      })

    run = %DTO.RunSummary{id: "run", conversation_id: "c"}

    rows =
      for n <- 1..60,
          do: %DTO.TranscriptItem{
            id: "row#{n}",
            run_id: "run",
            conversation_id: "c",
            node_id: "n#{n}",
            attempt_id: "a",
            text: "line #{n}"
          }

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      runs: [run],
      transcript: %DTO.TranscriptWindow{items: rows},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    state = %{state | read_model: ReadModel.snapshot(state.read_model, :workspace, body)}
    {first, []} = Reducer.update(state, {:scroll, "main", :first})
    {scene, _} = SwarmCodeCLI.UI.Projector.project(first)
    region = Enum.find(scene.regions, &(&1.id == "main"))
    visible = Enum.find(region.blocks, &is_struct(&1, SwarmCodeCLI.UI.Scene.Block.VirtualList))
    assert length(visible.items) > 0

    # PageDown advances by exactly one viewport of RENDERED rows: no skipped row and no
    # repeated row. Editorial turn labels make each item 3 rows here (blank + role label +
    # text), so the landing point is derived from real measured heights rather than from the
    # visible item count, which no longer equals the row count.
    height = ScrollMetrics.content_height(first, :main)

    {expected_id, expected_offset} =
      Enum.reduce_while(rows, height, fn row, left ->
        rendered = ScrollMetrics.height(first, :main, row.id)
        if left < rendered, do: {:halt, {row.id, left}}, else: {:cont, left - rendered}
      end)

    {next, []} = Reducer.update(first, {:scroll, "main", {:page, 1}})
    assert next.scrolls.main.anchor == {expected_id, expected_offset, :top}
    {scene, _} = SwarmCodeCLI.UI.Projector.project(next)
    region = Enum.find(scene.regions, &(&1.id == "main"))

    next_window =
      Enum.find(region.blocks, &is_struct(&1, SwarmCodeCLI.UI.Scene.Block.VirtualList))

    assert next_window.first_index == Enum.find_index(rows, &(&1.id == expected_id))

    # PageUp is the exact inverse, back to the very first row.
    {back, []} = Reducer.update(next, {:scroll, "main", {:page, -1}})
    assert back.scrolls.main.anchor == {"row1", 0, :top}
  end
end
