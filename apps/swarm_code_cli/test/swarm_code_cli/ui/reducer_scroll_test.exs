defmodule SwarmCodeCLI.UI.ReducerScrollTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Reducer, Init, Size, Capabilities, ReadModel, Scroll, OrderedIdSet}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}

  def initial do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"}
      })

    items =
      for id <- ["a", "b", "c"],
          do: %DTO.TranscriptItem{
            id: id,
            node_id: id,
            run_id: "r",
            conversation_id: "c",
            attempt_id: "attempt"
          }

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      transcript: %DTO.TranscriptWindow{
        items: items,
        before_cursor: "before",
        after_cursor: "after"
      },
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    watch = state.watches.workspace

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: body
    }

    {state, []} = Reducer.update(state, {:data, delivery})
    {state, delivery}
  end

  test "page sentinel deduplicates edge queries and preserves logical anchor on history" do
    {state, ready} = initial()
    {state, [{:query, request}]} = Reducer.update(state, {:scroll, "main", :first})
    assert state.pages.workspace.status == :loading_before
    assert state.scrolls.main.anchor == {"a", 0, :top}
    {same, []} = Reducer.update(state, {:scroll, "main", :first})
    assert same == state
    new_item = %{hd(ready.body.transcript.items) | id: "old", node_id: "old"}

    page = %DTO.TranscriptWindow{
      items: [new_item],
      request_id: request.request_id,
      after_cursor: "after"
    }

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

    {loaded, []} = Reducer.update(state, {:data, response})
    assert loaded.scrolls.main.anchor == state.scrolls.main.anchor

    assert Enum.map(ReadModel.items(loaded.read_model, :workspace), & &1.id) == [
             "old",
             "a",
             "b",
             "c"
           ]
  end

  test "off-window preserves anchor but confirmed removal repairs successor" do
    {state, ready} = initial()

    state = %{
      state
      | scrolls: %{state.scrolls | main: %Scroll{anchor: {"b", 2, :cursor}, follow?: false}},
        selection: %{"main" => "b"}
    }

    off = %{
      ready
      | revision: 1,
        body: %{
          ready.body
          | presence: :off_window,
            transcript: %{ready.body.transcript | items: []}
        }
    }

    {offscreen, []} = Reducer.update(state, {:data, off})
    assert offscreen.scrolls.main.anchor == {"b", 2, :cursor}
    assert offscreen.selection["main"] == "b"

    remove = %Delta{
      kind: :transcript_remove,
      entity_id: "b",
      run_id: "r",
      conversation_id: "c",
      sequence: 1,
      revision: 1
    }

    {removed, []} =
      Reducer.update(
        state,
        {:data, %{ready | kind: :delta, sequence: 1, revision: 1, body: remove}}
      )

    assert removed.scrolls.main.anchor == {"c", 2, :cursor}
    assert removed.selection["main"] == "c"
  end

  test "repeated changes count one stable ID while Inspector remains independent" do
    {state, ready} = initial()
    {state, []} = Reducer.update(state, {:scroll, "main", :detach})

    state =
      Enum.reduce(1..3, state, fn sequence, state ->
        delta = %Delta{
          kind: :stream_append,
          entity_id: "b",
          run_id: "r",
          conversation_id: "c",
          channel: :text,
          attempt_id: "attempt",
          text: "x",
          sequence: sequence,
          revision: sequence
        }

        {state, []} =
          Reducer.update(
            state,
            {:data, %{ready | kind: :delta, sequence: sequence, revision: sequence, body: delta}}
          )

        state
      end)

    assert OrderedIdSet.to_list(state.scrolls.main.unseen) == ["b"]
    assert OrderedIdSet.size(state.scrolls.inspector.unseen) == 0
    assert ReadModel.transcript_item(state.read_model, "b").text == "xxx"
    {following, _} = Reducer.update(state, {:scroll, "main", :follow})
    assert following.scrolls.main.follow?
    assert OrderedIdSet.size(following.scrolls.main.unseen) == 0
  end

  test "an unrelated shell snapshot cannot erase already admitted stream chunks" do
    {state, ready} = initial()

    delta = %Delta{
      kind: :stream_append,
      entity_id: "b",
      run_id: "r",
      conversation_id: "c",
      channel: :text,
      attempt_id: "attempt",
      text: "valuable",
      sequence: 1,
      revision: 1
    }

    {state, []} =
      Reducer.update(
        state,
        {:data, %{ready | kind: :delta, sequence: 1, revision: 1, body: delta}}
      )

    shell = state.watches.shell

    body = %DTO.ShellSnapshot{
      connection: %DTO.Connection{source_epoch: "e"},
      counts: %DTO.Counts{}
    }

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: shell.watch_ref,
      request_id: nil,
      scope: shell.scope,
      generation: shell.generation,
      revision: 1,
      sequence: nil,
      body: body
    }

    {state, []} = Reducer.update(state, {:data, delivery})
    assert ReadModel.transcript_item(state.read_model, "b").text == "valuable"
  end

  test "page failure retains visible rows and a retry admits exactly one new query" do
    {state, _} = initial()
    {state, [{:query, request}]} = Reducer.update(state, {:scroll, "main", :first})
    error = SwarmCodeCLI.UI.DataSource.AdmissionError.new(:source_unavailable)
    page = %DTO.TranscriptWindow{state: :error, request_id: request.request_id, error: error}

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

    {failed, []} = Reducer.update(state, {:data, response})
    assert failed.pages.workspace.status == :error
    assert Enum.map(ReadModel.items(failed.read_model, :workspace), & &1.id) == ["a", "b", "c"]
    {retry, [{:query, next}]} = Reducer.update(failed, {:retry_page, :workspace, :before})
    assert next.request_id != request.request_id
    assert elem(next.kind, 2) == elem(request.kind, 2)
    assert Reducer.update(retry, {:retry_page, :workspace, :before}) == {retry, []}
  end

  test "navigation replacement prunes old per-slot ancillary identities" do
    {state, ready} = initial()
    run = %DTO.RunSummary{id: "old-run", conversation_id: "c"}

    {state, []} =
      Reducer.update(state, {:data, %{ready | revision: 1, body: %{ready.body | runs: [run]}}})

    {state, _} = Reducer.update(state, {:navigate, {:conversation, "next"}})
    watch = state.watches.workspace

    next = %{
      ready
      | scope: watch.scope,
        generation: watch.generation,
        watch_ref: watch.watch_ref,
        body: %{
          ready.body
          | conversation_id: "next",
            runs: [],
            transcript: %DTO.TranscriptWindow{}
        }
    }

    {state, []} = Reducer.update(state, {:data, next})
    assert state.read_model.runs == %{}
    assert state.read_model.transcript == %{}
  end

  test "overflowing a complete bounded window preserves rows and requests one resync" do
    {state, _} = initial()
    template = hd(ReadModel.items(state.read_model, :workspace))
    rows = for number <- 1..512, do: %{template | id: "item-#{number}", node_id: "node-#{number}"}
    window = %DTO.TranscriptWindow{items: rows, after_cursor: "next"}
    model = ReadModel.snapshot(state.read_model, :workspace, window)

    state = %{
      state
      | read_model: model,
        pages: %{workspace: %SwarmCodeCLI.UI.PageState{after_cursor: "next"}}
    }

    {pending, [{:query, request}]} = Reducer.update(state, {:retry_page, :workspace, :after})

    page = %DTO.TranscriptWindow{
      items: [%{template | id: "overflow", node_id: "overflow"}],
      request_id: request.request_id
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

    {resync, [{:query, query}]} = Reducer.update(pending, {:data, delivery})
    assert query.kind == {:resync_watch, state.watches.workspace.watch_ref}
    assert resync.read_model == state.read_model
    assert Reducer.update(resync, {:data, delivery}) == {resync, []}
  end

  test "overlapping watches apply a canonical stream revision only once" do
    {state, _} = initial()

    delta = %Delta{
      kind: :stream_append,
      entity_id: "b",
      run_id: "r",
      conversation_id: "c",
      channel: :text,
      attempt_id: "attempt",
      text: "one",
      sequence: 1,
      revision: 1
    }

    assert {:ok, model, ["b"], []} = ReadModel.delta(state.read_model, :workspace, delta)
    assert {:ok, next, ["b"], []} = ReadModel.delta(model, :inspector, %{delta | sequence: 20})
    assert ReadModel.transcript_item(next, "b").text == "one"
  end

  test "line scroll traverses wrapped lines before changing stable item and resize keeps bias" do
    {state, _} = initial()
    item = %{state.read_model.transcript["a"] | text: "first\nsecond\nthird"}

    state = %{
      state
      | read_model: %{
          state.read_model
          | transcript: Map.put(state.read_model.transcript, "a", item)
        },
        scrolls: %{state.scrolls | main: %Scroll{anchor: {"a", 0, :cursor}, follow?: false}}
    }

    {line, []} = Reducer.update(state, {:scroll, "main", {:line, 1}})
    assert line.scrolls.main.anchor == {"a", 1, :cursor}
    # +2 label rows (blank + role label) added by editorial turn labels
    {boundary, []} = Reducer.update(line, {:scroll, "main", {:line, 4}})
    assert boundary.scrolls.main.anchor == {"b", 0, :cursor}
    {back, []} = Reducer.update(boundary, {:scroll, "main", {:line, -1}})
    assert back.scrolls.main.anchor == {"a", 4, :cursor}
    {resized, []} = Reducer.update(back, {:resize, %Size{columns: 60, rows: 20}})
    assert resized.scrolls.main.anchor == back.scrolls.main.anchor
  end
end
