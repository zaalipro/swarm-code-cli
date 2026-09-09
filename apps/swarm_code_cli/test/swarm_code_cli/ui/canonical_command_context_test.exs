defmodule SwarmCodeCLI.UI.CanonicalCommandContextTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Init, Reducer, Projector, Size, State}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Fake}
  alias Fake.{Script, Source}

  defp source_state do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "e"})
    client = start_supervised!({Fake, source: source, source_epoch: "e", client_id: "canonical"})
    assert {:ok, "bind"} = Fake.bind_owner(client, self(), "bind")
    size = %Size{columns: 120, rows: 30}

    {state, effects} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, Script.id(:a)},
        now: Script.clock_ms()
      })

    for {:watch, watch} <- effects, do: assert(:ok == Fake.watch(client, watch))

    state =
      Enum.reduce(Enum.filter(effects, &match?({:watch, _}, &1)), state, fn _, acc ->
        # Watch admission is asynchronous and its source deadline is 1 second.
        # This helper checks command context, not sub-100ms delivery latency.
        assert_receive {:swarm_code_ui_data, "e", %Delivery{kind: :watch_ready} = delivery}, 2_000
        {next, _} = Reducer.update(acc, {:data, delivery})
        next
      end)

    {state, _} =
      Reducer.update(state, {:editor, State.current_draft_key(state), {:insert, "focus tests"}})

    {source, client, state}
  end

  test "real canonical run permission exposes and executes one exact Steer command" do
    {source, client, state} = source_state()
    run = state.read_model.runs[Script.id(:a1)]
    node = Enum.find(Map.values(state.read_model.transcript), &(&1.run_id == run.id))
    assert :steer in run.allowed_actions
    refute :steer in node.allowed_actions
    intent = {:steer, run.id, node.node_id, "focus tests", []}
    state = %{state | selection: Map.put(state.selection, "main", node.id)}
    {_, table} = Projector.project(state)
    assert {:intent, intent} in Map.values(table)
    {pending, [{:command, request}]} = Reducer.update(state, {:invoke, intent, "steer-request"})
    assert request.kind == intent
    assert request.origin == {:draft, {Script.id(:a), :main}}
    assert :ok = Fake.command(client, request)

    assert_receive {:swarm_code_ui_data, "e",
                    %Delivery{
                      kind: :response,
                      request_id: "steer-request",
                      body: %{status: :accepted}
                    }},
                   2_000

    assert Enum.any?(Source.snapshot(source).transcript, fn {_, item} ->
             item.text == "focus tests" and item.target_kind == :steer
           end)

    assert Reducer.update(pending, {:invoke, intent, "duplicate"}) == {pending, []}
    {_, table} = Projector.project(pending)
    refute {:intent, intent} in Map.values(table)
  end

  test "Steer rejects absent run permission, inactive run, superseded node and wrong-run node" do
    {_, _, state} = source_state()
    run = state.read_model.runs[Script.id(:a1)]
    node = Enum.find(Map.values(state.read_model.transcript), &(&1.run_id == run.id))
    state = %{state | selection: Map.put(state.selection, "main", node.id)}
    intent = {:steer, run.id, node.node_id, "focus tests", []}

    variants = [
      put_in(state.read_model.runs[run.id].allowed_actions, []),
      put_in(state.read_model.runs[run.id].state, :paused),
      put_in(state.read_model.transcript[node.id].state, :superseded),
      put_in(state.read_model.transcript[node.id].run_id, Script.id(:b1))
    ]

    for changed <- variants do
      {next, effects} = Reducer.update(changed, {:invoke, intent, "denied"})
      assert effects == []
      assert next.requests == state.requests
      {_, table} = Projector.project(changed)
      refute {:intent, intent} in Map.values(table)
    end
  end

  defp activity_state do
    size = %Size{columns: 120, rows: 30}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: :activity
      })

    interaction = %DTO.PendingInteraction{
      id: "question",
      run_id: "off-page-run",
      node_id: "node",
      conversation_id: "c",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{options: [%DTO.QuestionOption{id: "option-2", label: "Second"}]}
    }

    item = %DTO.ActivityItem{
      id: "activity",
      run_id: interaction.run_id,
      conversation_id: "c",
      kind: :question,
      state: :waiting_question,
      interaction: interaction
    }

    watch = state.watches.activity

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: %DTO.ActivitySnapshot{items: [item], counts: %DTO.Counts{}}
    }

    {state, []} = Reducer.update(state, {:data, delivery})
    {state, item, interaction}
  end

  test "fresh Activity-only question supplies exact command facts without a cached run" do
    {state, _, item} = activity_state()
    assert state.read_model.runs == %{}
    intent = {:answer_question, item.run_id, item.node_id, item.id, 7, ["option-2"]}
    {_, [{:command, request}]} = Reducer.update(state, {:invoke, intent, "activity-answer"})
    assert request.kind == intent
    assert request.origin == {:interaction, item.id, 7}
    assert request.scope == state.watches.activity.scope
  end

  test "Activity fallback rejects stale identity, state and cached run contradictions" do
    {state, activity, item} = activity_state()
    intent = {:answer_question, item.run_id, item.node_id, item.id, 7, ["option-2"]}

    for changed <- [
          %{activity | state: :running},
          %{activity | run_id: "other"},
          %{activity | conversation_id: "other"},
          %{activity | interaction: %{item | expected_revision: 6}},
          %{activity | interaction: %{item | node_id: "other"}},
          %{activity | interaction: %{item | state: :resolved}}
        ] do
      bad = put_in(state.read_model.activity[activity.id], changed)
      {next, effects} = Reducer.update(bad, {:invoke, intent, "bad"})
      assert effects == []
      assert next.requests == %{}
    end

    known =
      put_in(state.read_model.runs[item.run_id], %DTO.RunSummary{
        id: item.run_id,
        conversation_id: "c",
        state: :stopped
      })

    assert {_, []} = Reducer.update(known, {:invoke, intent, "known-stopped"})
  end

  test "fresh Activity-only approval preserves exact decision authority" do
    {state, activity, question} = activity_state()

    approval = %{
      question
      | kind: :approval,
        question: nil,
        allowed_actions: [:deny, :always_allow]
    }

    activity = %{activity | kind: :approval, state: :waiting_approval, interaction: approval}

    state = %{
      state
      | read_model: %{
          state.read_model
          | interactions: %{approval.id => approval},
            activity: %{activity.id => activity}
        }
    }

    intent = {:resolve_approval, approval.run_id, approval.node_id, approval.id, 7, :always_allow}

    assert {_, [{:command, %{kind: ^intent, origin: {:interaction, "question", 7}}}]} =
             Reducer.update(state, {:invoke, intent, "always-allow"})

    unauthorized = put_in(state.read_model.interactions[approval.id].allowed_actions, [:deny])
    assert {_, []} = Reducer.update(unauthorized, {:invoke, intent, "denied"})
  end

  test "retained seen metadata cannot authorize or project commands in another scope" do
    {_, _, state} = source_state()
    alias SwarmCodeCLI.UI.Reducer.Commands
    run = state.read_model.runs[Script.id(:b1)]

    assert {:error, :invalid_origin} =
             Commands.context(state, {:mark_seen, :run, run.id, run.revision})

    activity = %DTO.ActivityItem{
      id: "outside",
      run_id: run.id,
      conversation_id: run.conversation_id,
      allowed_actions: [:mark_seen]
    }

    state = put_in(state.read_model.activity[activity.id], activity)

    assert {:error, :invalid_origin} =
             Commands.context(state, {:mark_seen, :activity, activity.id, 0})

    workspace = state.read_model.snapshots.workspace
    {away, _} = Reducer.update(state, {:navigate, :activity})
    watch = %{away.watches.activity | status: :ready}
    away = %{away | watches: Map.put(away.watches, :activity, watch)}
    intent = {:mark_seen, :conversation, workspace.conversation_id, workspace.revision}
    assert {:error, :invalid_origin} = Commands.context(away, intent)
    {_, table} = Projector.project(away)
    refute {:intent, intent} in Map.values(table)
  end
end
