defmodule SwarmCodeCLI.UI.CommandFeedbackTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Projector, Reducer, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  test "accepted goal report is readable, closes to the composer, and consumes its command" do
    {state, request} = pending("/goal")

    {shown, []} =
      Reducer.update(state, {:data, response(request, :report, "Ship the CLI\nStatus: active")})

    {scene, _} = Projector.project(shown)
    assert scene.overlay != nil
    assert SafeText.value(scene.overlay.title) == "Conversation goal"

    assert Enum.any?(
             scene.overlay.blocks,
             &(Map.has_key?(&1, :text) and SafeText.value(&1.text) =~ "Ship the CLI")
           )

    assert Editor.text(Drafts.fetch(shown.drafts, {"c", :main}).editor) == ""
    {closed, []} = Reducer.update(shown, :close_top_layer)
    assert closed.focus == "composer"
  end

  test "rewind opens the real checkpoint query with conversation scope" do
    {state, request} = pending("/rewind")
    delivery = response(request, :navigate, "", :checkpoints)
    {shown, [{:query, query}]} = Reducer.update(state, {:data, delivery})
    assert shown.layers == [{:library, :checkpoints}]
    assert query.kind == {:feature_query, :checkpoints, nil, nil, 20, 262_144}
    assert query.scope == request.scope
    assert {^shown, []} = Reducer.update(shown, {:data, delivery})
  end

  test "late feedback settles the old command without opening a report over another conversation" do
    {state, request} = pending("/goal")
    {away, _} = Reducer.update(state, {:navigate, {:conversation, "other"}})
    {settled, []} = Reducer.update(away, {:data, response(request, :report, "old goal")})
    assert settled.layers == []
    assert settled.destination == {:conversation, "other"}
    refute Map.has_key?(settled.requests, request.request_id)
  end

  test "mode feedback is shown without interrupting composition" do
    {state, request} = pending("/plan")
    {shown, []} = Reducer.update(state, {:data, response(request, :notice, "Plan mode enabled")})
    assert shown.layers == []
    assert shown.notice == {:command_feedback, "Plan mode enabled"}
    [notice] = SwarmCodeCLI.UI.Projector.Status.notice(shown, 100)
    assert SafeText.value(notice.text) == "Plan mode enabled"
    assert notice.severity == :info
  end

  test "long goal reports wrap and keyboard paging reaches the end" do
    {state, request} = pending("/goal")
    text = String.duplicate("A complete goal must remain readable. ", 180) <> "REPORT END"
    {shown, []} = Reducer.update(state, {:data, response(request, :report, text)})
    {scene, table} = Projector.project(shown)
    assert scene.overlay.body_total_count > 30

    assert {:ok, action} =
             SwarmCodeCLI.UI.Keymap.resolve(SwarmCodeCLI.UI.Input.key(:end), shown, table)

    {last, []} = Reducer.update(shown, action)
    {scene, _} = Projector.project(last)

    assert Enum.any?(
             scene.overlay.blocks,
             &(Map.has_key?(&1, :text) and SafeText.value(&1.text) =~ "REPORT END")
           )
  end

  test "a new report starts at the top after an older report was scrolled" do
    {state, request} = pending("/goal")

    {shown, []} =
      Reducer.update(
        %{state | selection: %{"dialog_scroll" => 99}},
        {:data, response(request, :report, "first\nsecond")}
      )

    assert shown.selection["dialog_scroll"] == nil
    {scene, _} = Projector.project(shown)
    assert scene.overlay.body_scroll == 0
  end

  defp pending(text) do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch",
        destination: {:conversation, "c"}
      })

    watch = state.watches.workspace

    snapshot = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send],
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{},
      transcript: %DTO.TranscriptWindow{}
    }

    {state, []} =
      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :watch_ready,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: 0,
           sequence: nil,
           body: snapshot
         }}
      )

    {state, _} =
      Reducer.update(%{state | focus: "composer"}, {:editor, {"c", :main}, {:insert, text}})

    {state, [{:command, request}]} =
      Reducer.update(state, {:invoke, {:dispatch, :send, text, :main, []}, "command"})

    {state, request}
  end

  defp response(request, kind, text, feature \\ nil) do
    %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: %DTO.Outcome{
        request_id: request.request_id,
        status: :accepted,
        feedback: %DTO.Feedback{
          kind: kind,
          title: "Conversation goal",
          text: text,
          feature: feature,
          conversation_id: "c"
        }
      }
    }
  end
end
