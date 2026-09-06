defmodule SwarmCodeCLI.UI.ReducerReviewRegressionTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Reducer, Init, Size, Capabilities, ReadModel, ChunkDeque, Keymap}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}

  def item(revision \\ 0, text \\ "old"),
    do: %DTO.TranscriptItem{
      id: "item",
      run_id: "run",
      conversation_id: "c",
      node_id: "node",
      attempt_id: "attempt",
      revision: revision,
      text: text
    }

  def window(rows), do: %DTO.TranscriptWindow{items: rows, before_cursor: "before"}

  def workspace(rows),
    do: %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      transcript: window(rows),
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

  def initial do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"}
      })

    watch = state.watches.workspace

    ready = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: workspace([item()])
    }

    {state, []} = Reducer.update(state, {:data, ready})
    {state, ready}
  end

  def append_delta do
    %Delta{
      kind: :stream_append,
      entity_id: "item",
      run_id: "run",
      conversation_id: "c",
      attempt_id: "attempt",
      channel: :text,
      text: "+new",
      revision: 1,
      sequence: 1
    }
  end

  test "older overlapping before page cannot replace a newer streamed row" do
    {state, ready} = initial()
    {pending, [{:query, request}]} = Reducer.update(state, {:scroll, "main", :first})

    {streamed, []} =
      Reducer.update(
        pending,
        {:data, %{ready | kind: :delta, revision: 1, sequence: 1, body: append_delta()}}
      )

    page = %{window([item()]) | request_id: request.request_id}

    response = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: page
    }

    {next, []} = Reducer.update(streamed, {:data, response})
    assert ReadModel.transcript_item(next.read_model, "item").text == "old+new"
    assert next.read_model.transcript["item"].revision == 1

    assert next.read_model.snapshots.workspace.transcript.items |> hd() |> Map.fetch!(:revision) ==
             1
  end

  test "older shared snapshots preserve retained newer chunks until superseded" do
    model = ReadModel.snapshot(%ReadModel{}, :workspace, workspace([item()]))
    detail = %DTO.RunDetailSnapshot{transcript: window([item()])}
    model = ReadModel.snapshot(model, :inspector, detail)
    {:ok, streamed, _, _} = ReadModel.delta(model, :workspace, append_delta())

    for slot <- [:workspace, :inspector] do
      body = if slot == :workspace, do: workspace([item()]), else: detail
      next = ReadModel.snapshot(streamed, slot, body)
      assert next.transcript["item"].revision == 1
      assert ReadModel.transcript_item(next, "item").text == "old+new"
      assert next.chunks == streamed.chunks

      body =
        if slot == :workspace,
          do: workspace([item(2, "replacement")]),
          else: %{detail | transcript: window([item(2, "replacement")])}

      replaced = ReadModel.snapshot(next, slot, body)
      assert ReadModel.transcript_item(replaced, "item").text == "replacement"
      assert replaced.chunks.entries == %{}
    end
  end

  test "empty appends are exact no-ops and empty reset clears an attempt" do
    deque = ChunkDeque.new()
    key = {"item", :text, "attempt"}
    assert {:ok, ^deque} = ChunkDeque.append(deque, key, "")
    {:ok, deque} = ChunkDeque.append(deque, key, "bytes")
    assert {:ok, ^deque} = ChunkDeque.append(deque, key, "")

    for n <- 1..100 do
      assert {:ok, ^deque} = ChunkDeque.append(deque, {"empty-#{n}", :text, "attempt"}, "")
    end

    {:ok, reset} = ChunkDeque.reset(deque, {"item", :text, "new"}, "")
    assert reset.entries == %{}
    model = ReadModel.snapshot(%ReadModel{}, :workspace, workspace([item()]))
    reset_delta = %{append_delta() | kind: :stream_reset, text: "", attempt_id: "new"}
    {:ok, model, _, _} = ReadModel.delta(model, :workspace, reset_delta)
    assert ReadModel.transcript_item(model, "item").text == ""
  end

  test "Navigator selects shell IDs and Enter opens the selected run without moving Main" do
    {state, _} = initial()

    runs =
      for id <- ["run-a", "run-b"], do: %DTO.RunSummary{id: id, conversation_id: "c", title: id}

    shell = %DTO.ShellSnapshot{
      runs: runs,
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"}
    }

    model = ReadModel.snapshot(state.read_model, :shell, shell)
    state = %{state | read_model: model, focus: "navigator"}
    {selected, []} = Reducer.update(state, {:move, :next})
    assert selected.selection["navigator"] == "run-a"
    assert selected.scrolls.main == state.scrolls.main
    assert selected.scrolls.navigator.anchor == {"run-a", 0, :top}
    table = %{"open" => {:local, {:navigate, {:run, "run-a"}}}}

    assert {:ok, {:navigate, {:run, "run-a"}}} =
             Keymap.resolve({:key, :press, :enter, []}, selected, table)

    {scrolled, []} = Reducer.update(selected, {:scroll, "navigator", {:line, 1}})
    assert scrolled.scrolls.navigator.anchor == {"run-b", 0, :top}
    assert scrolled.selection["navigator"] == "run-b"

    assert {:ok, {:navigate, {:run, "run-b"}}} =
             Keymap.resolve({:key, :press, :enter, []}, scrolled, %{
               "open" => {:local, {:navigate, {:run, "run-b"}}}
             })

    assert scrolled.scrolls.main == state.scrolls.main
  end

  test "Navigator unloaded edge queries shell once while Main page stays idle" do
    {state, _} = initial()
    run = %DTO.RunSummary{id: "run-a", conversation_id: "c", title: "run-a"}

    body = %DTO.ShellSnapshot{
      runs: [run],
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"},
      after_cursor: "shell-after"
    }

    watch = state.watches.shell

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
    state = %{state | focus: "navigator"}
    {pending, [{:query, request}]} = Reducer.update(state, {:scroll, "navigator", :last})
    assert request.kind == {:query, :shell, "shell-after", :after, 200, 1_048_576}
    assert request.scope == watch.scope
    assert pending.pages.shell.status == :loading_after
    assert pending.pages.workspace == state.pages.workspace
    assert pending.scrolls.main == state.scrolls.main
    assert Reducer.update(pending, {:scroll, "navigator", :last}) == {pending, []}
  end

  test "same-slot stale snapshots preserve newer rows without relying on shared coverage" do
    model = ReadModel.snapshot(%ReadModel{}, :workspace, workspace([item()]))
    {:ok, streamed, _, _} = ReadModel.delta(model, :workspace, append_delta())
    next = ReadModel.snapshot(streamed, :workspace, workspace([item()]))
    assert next.transcript["item"].revision == 1
    assert next.chunks == streamed.chunks
    assert ReadModel.transcript_item(next, "item").text == "old+new"
  end
end
