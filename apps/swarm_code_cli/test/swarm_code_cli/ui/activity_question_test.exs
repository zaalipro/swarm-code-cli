defmodule SwarmCodeCLI.UI.ActivityQuestionTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Activity, Question, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  test "custom answer stays scoped to its pending interaction and crosses the wire" do
    alias SwarmCodeCLI.UI.{Editor, FieldEditors, Intent}
    alias SwarmCodeCLI.UI.DataSource.{Request, Daemon.Codec}
    run = "11111111-1111-4111-8111-111111111111"
    node = "22222222-2222-4222-8222-222222222222"
    id = "33333333-3333-4333-8333-333333333333"

    item = %DTO.PendingInteraction{
      id: id,
      run_id: run,
      node_id: node,
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{options: [%DTO.QuestionOption{id: "one"}]}
    }

    state = %State{}
    {:ok, editor} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, "My own answer"})

    state = %{
      state
      | read_model: %{state.read_model | interactions: %{id => item}},
        field_editors: FieldEditors.put(state.field_editors, {:question_other, id, 7}, editor)
    }

    intent = Question.answer_intent(state, item, "other")

    assert {:answer_question, ^run, ^node, ^id, 7,
            %{option_ids: [], custom_text: "My own answer"}} = intent

    assert {:ok, ^intent} = Intent.validate(intent)

    request = %Request{
      request_id: "answer",
      kind: intent,
      scope: %SwarmCode.Protocol.Scope{kind: :run, id: run, generation: 2},
      generation: 2,
      origin: {:interaction, id, 7},
      deadline: 5_000,
      expected_response: :outcome
    }

    assert {:ok, message} = Codec.request(request, node, String.duplicate("A", 43), 0)
    assert message.body["op"] == "question.answer"
    assert message.body["answers"] == []
    assert message.body["custom_text"] == "My own answer"
  end

  test "Activity sorts unresolved deadlines before running then newest failures and completions" do
    items = [
      %DTO.ActivityItem{id: "complete", kind: :completion, created_at: 100},
      %DTO.ActivityItem{id: "late", kind: :question, deadline: 20, created_at: 1},
      %DTO.ActivityItem{id: "failure-old", kind: :failure, created_at: 20},
      %DTO.ActivityItem{id: "run", kind: :running, created_at: 20},
      %DTO.ActivityItem{id: "early", kind: :approval, deadline: 10, created_at: 2},
      %DTO.ActivityItem{id: "failure-new", kind: :failure, created_at: 30}
    ]

    assert Enum.map(Activity.sort(items), & &1.id) == [
             "early",
             "late",
             "run",
             "failure-new",
             "failure-old",
             "complete"
           ]
  end

  test "a deadline of 0 sorts after every timed item" do
    items = [
      %DTO.ActivityItem{id: "forever", kind: :question, deadline: 0, created_at: 1},
      %DTO.ActivityItem{id: "timed", kind: :question, deadline: 20, created_at: 2}
    ]

    assert Enum.map(Activity.sort(items), & &1.id) == ["timed", "forever"]

    fallback = %DTO.ActivityItem{
      id: "fallback",
      kind: :approval,
      deadline: nil,
      created_at: 3,
      interaction: %DTO.PendingInteraction{id: "i", state: :pending, deadline: 20}
    }

    early = %DTO.ActivityItem{id: "early", kind: :question, deadline: 10, created_at: 4}
    late = %DTO.ActivityItem{id: "late", kind: :question, deadline: 30, created_at: 0}

    assert Enum.map(Activity.sort([late, fallback | items] ++ [early]), & &1.id) ==
             ["early", "timed", "fallback", "late", "forever"]
  end

  test "question preserves exact identity and rejects stale, pending, resolved or unauthorized submission" do
    item = %DTO.PendingInteraction{
      id: "q1",
      run_id: "run-a2",
      node_id: "node-a2",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{options: [%DTO.QuestionOption{id: "option-2"}]}
    }

    state = %State{}
    state = %{state | read_model: %{state.read_model | interactions: %{item.id => item}}}
    intent = {:answer_question, "run-a2", "node-a2", "q1", 7, ["option-2"]}
    assert Question.answer_intent(state, item, "option-2") == intent
    assert Question.answer_intent(state, %{item | expected_revision: 6}, "option-2") == :ignore
    assert Question.answer_intent(state, item, "unknown") == :ignore
    pending = %{state | mutations: %{{:interaction, "q1", 7} => {:pending, "request", intent}}}
    assert Question.answer_intent(pending, item, "option-2") == :ignore

    for changed <- [%{item | state: :resolved}, %{item | allowed_actions: []}] do
      state = %{state | read_model: %{state.read_model | interactions: %{item.id => changed}}}
      assert Question.answer_intent(state, changed, "option-2") == :ignore
    end
  end

  test "question keymap to reducer sends one exact revisioned command and disables duplicate" do
    alias SwarmCodeCLI.UI.{Capabilities, Init, Input, Keymap, Projector, Reducer, Size}
    alias SwarmCodeCLI.UI.DataSource.Delivery
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch",
        destination: :activity
      })

    item = %DTO.PendingInteraction{
      id: "q1",
      run_id: "run-a2",
      node_id: "node-a2",
      conversation_id: "c",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: "Choose",
        options: [
          %DTO.QuestionOption{id: "option-1", label: "First"},
          %DTO.QuestionOption{id: "option-2", label: "Second"}
        ]
      }
    }

    activity = %DTO.ActivityItem{
      id: "a1",
      run_id: "run-a2",
      conversation_id: "c",
      kind: :question,
      interaction: item
    }

    watch = state.watches.activity

    delivery = %Delivery{
      request_id: nil,
      sequence: nil,
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      body: %DTO.ActivitySnapshot{items: [activity], counts: %DTO.Counts{}}
    }

    {state, []} = Reducer.update(state, {:data, delivery})

    state = %{
      state
      | read_model: %{
          state.read_model
          | runs: %{
              "run-a2" => %DTO.RunSummary{
                id: "run-a2",
                conversation_id: "c",
                state: :waiting_question
              }
            }
        }
    }

    # pass 75: the activity row opens its ask's note (keyed by the asking
    # node); Enter on the note confirms the ask, and a one-question ask sends
    # the focused option at once, as the map payload.
    {state, _} = Reducer.update(state, {:open_layer, {:question, "q1"}})
    assert [{:question, "node-a2"} | _] = state.layers
    {state, []} = Reducer.update(state, {:focus_region, "option-2"})
    {_, table} = Projector.project(state)

    assert {:ok, {:interview, {:confirm, "node-a2"}} = action} =
             Keymap.resolve(Input.key(:enter), state, table)

    intent =
      {:answer_question, "run-a2", "node-a2", "q1", 7,
       %{option_ids: ["option-2"], custom_text: ""}}

    {pending, [{:command, request}]} = Reducer.update(state, action)
    assert Question.interview(pending, "node-a2").sending == [request.request_id]
    assert request.origin == {:interaction, "q1", 7}
    assert request.kind == intent

    # While it is on its way a second Enter sends nothing.
    {_, table} = Projector.project(pending)
    assert {:ok, again} = Keymap.resolve(Input.key(:enter), pending, table)
    assert {_, []} = Reducer.update(pending, again)
    assert Reducer.update(pending, action) == {pending, []}
  end

  test "multiple question Space toggles an option and Enter submits only the ticks" do
    alias SwarmCodeCLI.UI.{Capabilities, Input, Keymap, Size}

    item = %DTO.PendingInteraction{
      id: "q",
      run_id: "r",
      node_id: "n",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        multiple: true,
        options: [%DTO.QuestionOption{id: "one"}, %DTO.QuestionOption{id: "two"}]
      }
    }

    size = %Size{columns: 120, rows: 40}

    # pass 75: the note of node "n"; there is no Submit control. Space ticks
    # the focused option, Enter confirms, and the answer is the ticks alone,
    # not the focused option.
    state = %State{
      size: size,
      capabilities: %Capabilities{size: size},
      layers: [{:question, "n"}],
      focus: "two",
      selection: %{{:question, "q"} => ["one"]}
    }

    state = %{state | read_model: %{state.read_model | interactions: %{"q" => item}}}

    assert {:ok, {:interview, {:toggle, "n", "two"}}} =
             Keymap.resolve(Input.text_fragment(:press, " ", []), state, %{})

    assert {:ok, {:interview, {:confirm, "n"}}} = Keymap.resolve(Input.key(:enter), state, %{})

    assert Question.intents(state, Question.ask(state, "n")) == [
             {:answer_question, "r", "n", "q", 7, %{option_ids: ["one"], custom_text: ""}}
           ]
  end

  test "accepted interaction cannot resubmit before its canonical resolution; other settlements preserve retry" do
    item = %DTO.PendingInteraction{
      id: "q",
      run_id: "r",
      node_id: "n",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{options: [%DTO.QuestionOption{id: "one"}]}
    }

    state = %State{}
    state = %{state | read_model: %{state.read_model | interactions: %{"q" => item}}}

    for outcome <- [
          :accepted,
          :needs_input,
          :rejected,
          :deadline_exceeded,
          :interrupted,
          :revision_conflict,
          :outcome_unknown
        ] do
      settled = %{state | mutations: %{{:interaction, "q", 7} => {:settled, "request", outcome}}}
      result = Question.answer_intent(settled, item, "one")

      if outcome == :accepted,
        do: assert(result == :ignore),
        else: assert(result == {:answer_question, "r", "n", "q", 7, ["one"]})

      assert settled.selection == state.selection
      assert settled.field_editors == state.field_editors
    end
  end
end
