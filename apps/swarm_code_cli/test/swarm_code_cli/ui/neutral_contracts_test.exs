defmodule SwarmCodeCLI.UI.NeutralContractsTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.TestSupport.ContractFixtures

  alias SwarmCodeCLI.UI.{
    Action,
    ActionTarget,
    Capabilities,
    Destination,
    DraftKey,
    Effect,
    FieldKey,
    Input,
    Intent,
    LayerSpec,
    RequestResolver,
    ScrollOperation,
    Size
  }

  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Request, Watch}
  alias SwarmCodeCLI.UI.Editor.Operation
  alias SwarmCodeCLI.UI.RequestResolver.Context

  test "terminal lifecycle and draw settlement remain renderer neutral" do
    caps =
      Capabilities.explicit(%Size{columns: 120, rows: 40},
        stdin_tty?: true,
        stdout_tty?: true,
        controlling_tty?: true
      )

    assert {:terminal_capabilities, 4, ^caps} =
             Action.validate!({:terminal_capabilities, 4, caps})

    assert {:draw_result, "draw-8", 17, :ok} =
             Action.validate!({:draw_result, "draw-8", 17, :ok})

    assert {:terminal_focus, :lost, 4} = Action.validate!({:terminal_focus, :lost, 4})
    assert {:terminal_control, :suspend} = Effect.validate!({:terminal_control, :suspend})
    assert :back = Action.validate!(:back)

    assert {:layout_adjust, :navigator, {:nudge, -2}} =
             Action.validate!({:layout_adjust, :navigator, {:nudge, -2}})

    assert {:presenter_handoff, :plain} = Effect.validate!({:presenter_handoff, :plain})
  end

  test "TUI and plain intents resolve to the same request bytes" do
    context =
      ContractFixtures.q1_resolution_context(allowed_actions: [:answer_question, :always_allow])

    intent = {:answer_question, "run-a2", "node-a2", "q1", 7, ["option-2"]}

    assert {:ok, request} =
             RequestResolver.resolve(intent, context, "request-42", 1_788_438_400_000)

    assert ContractFixtures.canonical_request_bytes(request) ==
             ContractFixtures.expected_q1_request_bytes()
  end

  test "resolver does not infer always-allow or repair a mismatched context" do
    context = ContractFixtures.approval_context(allowed_actions: [:approve, :deny])
    always = {:resolve_approval, "run-a2", "node-a2", "approval-1", 4, :always_allow}

    assert {:error, :not_allowed} =
             RequestResolver.resolve(always, context, "request-43", 1_788_438_400_000)

    mismatched = {:run_control, :stop, "other-run"}

    assert {:error, :invalid_origin} =
             RequestResolver.resolve(mismatched, context, "request-44", 1_788_438_400_000)
  end

  test "retry and agent Stop remain authorized revisioned target kinds" do
    retry_context =
      ContractFixtures.failed_run_context("run-f", 12, allowed_actions: [:retry])

    assert {:ok,
            %Request{
              kind: {:retry_run, "run-f", 12},
              origin: {:run_revision, "run-f", 12}
            }} =
             RequestResolver.resolve(
               {:retry_run, "run-f", 12},
               retry_context,
               "request-45",
               1_788_438_400_000
             )

    agent_context =
      ContractFixtures.agent_context("run-s", "agent-2", 9, allowed_actions: [:stop_agent])

    assert {:ok, %Request{kind: {:stop_agent, "run-s", "agent-2", 9}}} =
             RequestResolver.resolve(
               {:stop_agent, "run-s", "agent-2", 9},
               agent_context,
               "request-46",
               1_788_438_400_000
             )

    assert {:error, :not_allowed} =
             RequestResolver.resolve(
               {:stop_agent, "run-s", "agent-2", 9},
               ContractFixtures.run_context("run-s", allowed_actions: [:stop]),
               "request-47",
               1_788_438_400_000
             )

    assert {:error, :stale_revision} =
             RequestResolver.resolve(
               {:retry_run, "run-f", 11},
               retry_context,
               "request-48",
               1_788_438_400_000
             )
  end

  test "random external input strings do not grow the atom table" do
    samples = StreamData.binary(length: 1..64) |> Enum.take(1_000)
    Input.from_external_code("Enter")
    Input.from_external_modifier("Control")
    Input.from_external_mouse_kind("Down")
    Input.from_external_mouse_button("Left")
    before_count = :erlang.system_info(:atom_count)

    Enum.each(samples, fn value ->
      Input.from_external_code(value)
      Input.from_external_modifier(value)
      Input.from_external_mouse_kind(value)
      Input.from_external_mouse_button(value)
    end)

    assert :erlang.system_info(:atom_count) == before_count
  end

  test "input is a bounded closed union and has no lifecycle tuple" do
    assert {:key, :press, :enter, [:control]} = Input.key(:enter, [:control])
    assert {:key, :press, {:function, 12}, []} = Input.key({:function, 12})

    assert {:text_fragment, :repeat, "👩🏽‍🚒", [:shift]} =
             Input.text_fragment(:repeat, "👩🏽‍🚒", [:shift])

    maximum_paste = String.duplicate("p", 262_144)
    assert {:paste, ^maximum_paste} = Input.paste(maximum_paste)

    assert {:rejected, :text_fragment_too_large} =
             Input.text_fragment(:press, String.duplicate("x", 4_097), [])

    assert {:rejected, :paste_too_large} = Input.paste(String.duplicate("x", 262_145))
    assert {:rejected, :invalid_utf8} = Input.paste(<<255>>)

    assert {:ok, {:resize, %Size{columns: 80, rows: 24}}} =
             Input.validate({:resize, %Size{columns: 80, rows: 24}})

    assert {:ok, :focus_gained} = Input.validate(:focus_gained)

    assert {:ok, {:mouse, :press, :left, 0, 1, []}} =
             Input.validate({:mouse, :press, :left, 0, 1, []})

    assert {:error, :invalid_input} = Input.validate({:terminal_lifecycle, :suspended})

    assert {:text_fragment, :press, "z", [:control]} =
             Input.text_fragment(:press, "z", [:control])
  end

  test "external input lookup uses only closed compile-time tables" do
    assert {:ok, :enter} = Input.from_external_code("Enter")
    assert {:ok, {:function, 7}} = Input.from_external_code("F7")
    assert :ignore = Input.from_external_code("F13")
    assert :ignore = Input.from_external_code("future-renderer-key")
    assert {:ok, :control} = Input.from_external_modifier("Control")
    assert :ignore = Input.from_external_modifier("CommandOrControl")
    assert {:ok, :wheel_up} = Input.from_external_mouse_kind("ScrollUp")
    assert {:ok, :left} = Input.from_external_mouse_button("Left")
  end

  test "intent validates every exact variant and rejects aliases and bound violations" do
    valid = [
      {:dispatch, :send, "hello", :main, []},
      {:dispatch, :queue, "hello", {:reply, "message-1"}, ["attachment-1"]},
      {:dispatch, :send, "hello", {:thread, "thread-1"}, []},
      {:dispatch, :send, "hello", {:revise, "message-1"}, []},
      {:dispatch, :send, "hello", {:chip, :research, "research-1"}, []},
      {:steer, "run-1", "node-1", "change course", []},
      {:run_control, :pause, "run-1"},
      {:run_control, :continue, "run-1"},
      {:run_control, :resume, "run-1"},
      {:run_control, :stop, "run-1"},
      {:retry_run, "run-1", 3},
      {:stop_agent, "run-1", "agent-1", 5},
      {:answer_question, "run-1", "node-1", "question-1", 7, ["option-1"]},
      {:resolve_approval, "run-1", "node-1", "approval-1", 8, :approve},
      {:resolve_approval, "run-1", "node-1", "approval-1", 8, :deny},
      {:resolve_approval, "run-1", "node-1", "approval-1", 8, :always_allow},
      {:mark_seen, :conversation, "conversation-1", 1},
      {:mark_seen, :run, "run-1", 2},
      {:mark_seen, :activity, "activity-1", 3}
    ]

    for intent <- valid do
      assert {:ok, ^intent} = Intent.validate(intent)
      assert intent == Intent.validate!(intent)
    end

    invalid = [
      {:send, "hello"},
      {:dispatch, :steer, "hello", :main, []},
      {:dispatch, :send, " \n\t", :main, []},
      {:dispatch, :send, <<255>>, :main, []},
      {:dispatch, :send, String.duplicate("x", 262_145), :main, []},
      {:dispatch, :send, "hello", {:reply, "bad\e"}, []},
      {:dispatch, :send, "hello", :main, List.duplicate("same", 2)},
      {:dispatch, :send, "hello", :main, Enum.map(1..17, &"attachment-#{&1}")},
      {:retry_run, "run-1", -1},
      {:answer_question, "run-1", "node-1", "question-1", 7, ["same", "same"]},
      {:resolve_approval, "run-1", "node-1", "approval-1", 8, :allow},
      {:mark_seen, :message, "message-1", 1},
      {:dispatch, :send, "hello", :plain, []}
    ]

    for intent <- invalid do
      assert {:error, :invalid_intent} = Intent.validate(intent)
      assert_raise ArgumentError, "invalid intent", fn -> Intent.validate!(intent) end
    end
  end

  test "identifier validation is UTF-8, control-free, and exactly 1 through 256 bytes" do
    assert Intent.valid_id?("é")
    assert Intent.valid_id?(String.duplicate("a", 256))

    for invalid <- [
          "",
          String.duplicate("a", 257),
          <<255>>,
          "line\nfeed",
          "escape\e",
          "delete\u007F",
          "c1\u0085"
        ] do
      refute Intent.valid_id?(invalid)
    end
  end

  test "draft, field, destination, layer, scroll, and editor vocabularies stay separate and closed" do
    assert {:ok, {"conversation-1", :main}} = DraftKey.validate({"conversation-1", :main})

    assert {:ok, {"conversation-1", {:thread, "thread-1"}}} =
             DraftKey.validate({"conversation-1", {:thread, "thread-1"}})

    assert {:ok, {"conversation-1", {:edit, "message-1"}}} =
             DraftKey.validate({"conversation-1", {:edit, "message-1"}})

    assert {:ok, {:layer_query, "layer-1", :switcher}} =
             FieldKey.validate({:layer_query, "layer-1", :switcher})

    assert {:ok, {:region_filter, "main"}} = FieldKey.validate({:region_filter, "main"})
    assert {:ok, {:question_other, "q1", 7}} = FieldKey.validate({:question_other, "q1", 7})
    assert {:error, :invalid_field_key} = FieldKey.validate({"conversation-1", :main})
    assert {:error, :invalid_draft_key} = DraftKey.validate({:region_filter, "main"})

    assert {:conversation, "conversation-1"} = Destination.conversation("conversation-1")
    assert {:run, "run-1"} = Destination.run("run-1")
    assert :activity = Destination.activity()
    assert :help = LayerSpec.help()
    assert {:run_inspector, "run-1", :changes} = LayerSpec.run_inspector("run-1", :changes)

    for operation <- [{:line, -2}, {:page, 1}, :first, :last, :follow, :detach] do
      assert {:ok, ^operation} = ScrollOperation.validate(operation)
    end

    for operation <- [
          {:insert, "x"},
          {:paste, "multi\nline"},
          :delete_backward,
          :delete_forward,
          :delete_word_backward,
          :delete_word_forward,
          {:move, :left},
          {:move, :buffer_end},
          {:extend_selection, :word_right},
          :select_all,
          :undo,
          :redo,
          :newline,
          {:undo_boundary, "boundary-1"}
        ] do
      assert {:ok, ^operation} = Operation.validate(operation)
    end

    for forbidden <- [:copy, :cut, {:clipboard, "x"}, {:composition_update, "x"}] do
      assert {:error, :invalid_editor_operation} = Operation.validate(forbidden)
    end
  end

  test "context enforces exact struct shape, closed permissions, and canonical bounded fields" do
    context = ContractFixtures.dispatch_context()
    assert {:ok, ^context} = Context.validate(context)

    duplicate_permissions = %{context | allowed_actions: [:send, :send]}
    assert {:error, :invalid_context} = Context.validate(duplicate_permissions)

    assert {:error, :invalid_context} =
             Context.validate(%{context | allowed_actions: [:send, :unknown]})

    assert {:error, :invalid_context} =
             Context.validate(%{context | attachment_refs: ["same", "same"]})

    assert {:error, :invalid_context} = Context.validate(%{context | scope_generation: -1})

    forged =
      Map.put(Map.from_struct(context), :__struct__, Context) |> Map.put(:label, "forbidden")

    assert {:error, :invalid_context} = Context.validate(forged)
  end

  test "resolver accepts all exact intent forms and preserves their origins" do
    assert {:ok, %Request{kind: {:dispatch, :send, "ship it", :main, ["attachment-1"]}}} =
             RequestResolver.resolve(
               {:dispatch, :send, "ship it", :main, ["attachment-1"]},
               ContractFixtures.dispatch_context(),
               "request-d",
               100
             )

    assert {:ok, %Request{kind: {:steer, "run-a2", "node-a2", "focus tests", []}}} =
             RequestResolver.resolve(
               {:steer, "run-a2", "node-a2", "focus tests", []},
               ContractFixtures.steer_context(),
               "request-s",
               101
             )

    assert {:ok, %Request{origin: {:run, "run-1"}}} =
             RequestResolver.resolve(
               {:run_control, :stop, "run-1"},
               ContractFixtures.run_context("run-1", allowed_actions: [:stop]),
               "request-r",
               102
             )

    assert {:ok, %Request{origin: {:interaction, "approval-1", 4}}} =
             RequestResolver.resolve(
               {:resolve_approval, "run-a2", "node-a2", "approval-1", 4, :always_allow},
               ContractFixtures.approval_context(allowed_actions: [:always_allow]),
               "request-a",
               103
             )

    assert {:ok, %Request{origin: {:seen, :activity, "activity-1", 5}}} =
             RequestResolver.resolve(
               {:mark_seen, :activity, "activity-1", 5},
               ContractFixtures.seen_context(:activity, "activity-1", 5),
               "request-m",
               104
             )
  end

  test "resolver applies invalid, permission, revision, then origin precedence" do
    approval = ContractFixtures.approval_context(allowed_actions: [])

    assert {:error, :invalid_intent} =
             RequestResolver.resolve(
               {:resolve_approval, "run", "node", "id", -1, :approve},
               approval,
               "request",
               1
             )

    stale_without_permission =
      ContractFixtures.approval_context(
        origin: {:interaction, "approval-1", 3},
        interaction: {:approval, "run-a2", "node-a2", "approval-1", 3},
        allowed_actions: []
      )

    assert {:error, :not_allowed} =
             RequestResolver.resolve(
               {:resolve_approval, "run-a2", "node-a2", "approval-1", 4, :approve},
               stale_without_permission,
               "request",
               1
             )

    stale = %{stale_without_permission | allowed_actions: [:approve]}

    assert {:error, :stale_revision} =
             RequestResolver.resolve(
               {:resolve_approval, "run-a2", "node-a2", "approval-1", 4, :approve},
               stale,
               "request",
               1
             )

    mismatched =
      ContractFixtures.approval_context(active_node_id: "other-node", allowed_actions: [:approve])

    assert {:error, :invalid_origin} =
             RequestResolver.resolve(
               {:resolve_approval, "run-a2", "node-a2", "approval-1", 4, :approve},
               mismatched,
               "request",
               1
             )
  end

  test "retry requires both failed state and its own permission" do
    intent = {:retry_run, "run-f", 12}

    assert {:error, :not_allowed} =
             RequestResolver.resolve(
               intent,
               ContractFixtures.failed_run_context("run-f", 12, allowed_actions: []),
               "request",
               1
             )

    assert {:error, :not_allowed} =
             RequestResolver.resolve(
               intent,
               ContractFixtures.failed_run_context("run-f", 12,
                 active_run_state: :stopped,
                 allowed_actions: [:retry]
               ),
               "request",
               1
             )
  end

  test "resolver rejects noncanonical unused context and invalid request metadata" do
    context = ContractFixtures.run_context("run-1", allowed_actions: [:stop])
    intent = {:run_control, :stop, "run-1"}

    for changed <- [
          %{context | active_node_id: "node-1"},
          %{context | active_agent_id: "agent-1"},
          %{context | subject_revision: 1},
          %{context | interaction: {:question, "run-1", "node-1", "q1", 1}},
          %{context | editor_text: "payload"},
          %{context | dispatch_target: {:reply, "message-1"}},
          %{context | attachment_refs: ["attachment-1"]},
          %{context | scope_generation: 4}
        ] do
      assert {:error, :invalid_origin} = RequestResolver.resolve(intent, changed, "request", 1)
    end

    assert {:error, :invalid_intent} = RequestResolver.resolve(intent, context, "", 1)
    assert {:error, :invalid_intent} = RequestResolver.resolve(intent, context, "request", 1.0)
  end

  test "data source shells have final correlation fields and reject arbitrary bodies" do
    scope = %Scope{kind: :conversation, id: "conversation-a", generation: 3}

    watch = %Watch{
      watch_ref: "watch-1",
      slot: :workspace,
      scope: scope,
      generation: 3,
      page_size: 200,
      byte_limit: 1_048_576
    }

    assert {:ok, ^watch} = Watch.validate(watch)
    assert {:error, :invalid_watch} = Watch.validate(%{watch | page_size: 201})
    assert {:error, :invalid_watch} = Watch.validate(%{watch | byte_limit: 1_048_577})

    request = %Request{
      request_id: "request-1",
      kind: {:run_control, :stop, "run-1"},
      scope: %Scope{kind: :run, id: "run-1", generation: 3},
      generation: 3,
      origin: {:run, "run-1"},
      deadline: 100,
      expected_response: :outcome
    }

    assert {:ok, ^request} = Request.validate(request)

    delivery = %Delivery{
      kind: :closed,
      watch_ref: "watch-1",
      request_id: nil,
      scope: scope,
      generation: 3,
      revision: nil,
      sequence: nil,
      body: nil
    }

    assert {:ok, ^delivery} = Delivery.validate(delivery)
    assert {:error, :invalid_delivery} = Delivery.validate(%{delivery | body: %{arbitrary: true}})

    assert %AdmissionError{code: :not_bound, message: "data source owner is not bound"} =
             AdmissionError.new(:not_bound)

    assert {:ok, %AdmissionError{code: :closed}} =
             AdmissionError.validate(AdmissionError.new(:closed))

    assert {:error, :invalid_admission_error} =
             AdmissionError.validate(%AdmissionError{code: :closed, message: "untrusted detail"})

    assert_raise FunctionClauseError, fn -> apply(AdmissionError, :new, [:invented]) end
  end

  test "action is exhaustive, deeply validates semantic values, and rejects unsafe terms" do
    scope = %Scope{kind: :conversation, id: "conversation-a", generation: 3}

    delivery = %Delivery{
      kind: :closed,
      watch_ref: "watch-1",
      request_id: nil,
      scope: scope,
      generation: 3,
      revision: nil,
      sequence: nil,
      body: nil
    }

    intent = {:run_control, :stop, "run-1"}

    valid = [
      :boot,
      {:resize, %Size{columns: 80, rows: 24}},
      {:terminal_lifecycle, :suspend_requested, 2, :keyboard},
      {:terminal_lifecycle, :suspended, 2, :launcher},
      {:terminal_lifecycle, :resumed, 3, :runtime},
      {:terminal_lifecycle, :closing, 3, :runtime},
      {:terminal_failed, 3, :draw_failed},
      {:draw_result, "draw-1", 8, {:error, :draw_failed}},
      {:terminal_focus, :gained, 3},
      {:input_rejected, :paste_too_large},
      :back,
      {:focus_cycle, :next},
      {:focus_region, "main"},
      {:move, :first},
      {:expand, "message-1", true},
      {:invoke, intent, "request-1"},
      {:scroll, "main", :follow},
      {:editor, {"conversation-a", :main}, {:insert, "x"}},
      {:field_editor, {:region_filter, "main"}, {:move, :left}},
      {:layout_adjust, :inspector, :reset},
      {:layout_adjust, :navigator, {:preset, :wide}},
      {:composer_height, {:nudge, 1}},
      {:presenter_handoff_requested, :plain},
      {:presenter_handoff_confirmed, :plain},
      :open_companion,
      {:navigate, Destination.activity()},
      {:open_layer, LayerSpec.help()},
      :close_top_layer,
      {:data, delivery},
      {:timer_fired, "timer-1"},
      {:quit_requested, :daemon_shutdown},
      {:quit_confirmed, :detach}
    ]

    for action <- valid do
      assert {:ok, ^action} = Action.validate(action)
      assert action == Action.validate!(action)
    end

    for action <- [
          {:terminal_lifecycle, :resumed, 1, :renderer},
          {:draw_result, "draw-1", -1, :ok},
          {:terminal_failed, 0, :native_term_with_secret},
          {:invoke, intent, self()},
          {:start_process, fn -> :ok end},
          {:open_layer, %{arbitrary: true}},
          {:data, %{arbitrary: true}},
          {:composer_height, {:nudge, 2}},
          {:layout_adjust, :main, :reset},
          {:open_companion, :now}
        ] do
      assert {:error, :invalid_action} = Action.validate(action)
      assert_raise ArgumentError, "invalid action", fn -> Action.validate!(action) end
    end
  end

  test "ActionTarget and Effect admit only their exact renderer-neutral unions" do
    intent = {:run_control, :stop, "run-1"}
    assert {:local, :back} = ActionTarget.validate!({:local, :back})
    assert {:intent, ^intent} = ActionTarget.validate!({:intent, intent})

    request =
      %Request{
        request_id: "request-1",
        kind: intent,
        scope: %Scope{kind: :run, id: "run-1", generation: 3},
        generation: 3,
        origin: {:run, "run-1"},
        deadline: 100,
        expected_response: :outcome
      }

    watch = %Watch{
      watch_ref: "watch-1",
      slot: :workspace,
      scope: %Scope{kind: :conversation, id: "conversation-a", generation: 3},
      generation: 3,
      page_size: 20,
      byte_limit: 100_000
    }

    for effect <- [
          {:watch, watch},
          {:unwatch, "watch-1"},
          {:command, request},
          {:cancel_request, "request-1"},
          {:start_timer, "timer-1", 1_000, {:timer_fired, "timer-1"}},
          {:cancel_timer, "timer-1"},
          {:terminal_control, :resume},
          {:announce, SwarmCodeCLI.UI.SafeText.chrome(:help)},
          {:bell, :needs_you},
          {:presenter_handoff, :plain},
          {:companion, :open},
          {:detach, 0}
        ] do
      assert {:ok, ^effect} = Effect.validate(effect)
      assert effect == Effect.validate!(effect)
    end

    assert {:error, :invalid_effect} = Effect.validate({:query, request})

    assert_raise ArgumentError, "invalid effect", fn ->
      Effect.validate!({:query, request})
    end

    for unsafe <- [
          {:watch, self()},
          {:start_timer, "timer-1", 1, fn -> :ok end},
          {:terminal_control, :sigstop},
          {:announce, "raw"},
          {:detach, -1},
          {:clipboard, "secret"},
          {:companion, :close}
        ] do
      assert {:error, :invalid_effect} = Effect.validate(unsafe)
      assert_raise ArgumentError, "invalid effect", fn -> Effect.validate!(unsafe) end
    end
  end

  test "request validation correlates every mutation kind with its exact origin" do
    request = %Request{
      request_id: "request-1",
      kind: {:run_control, :stop, "run-1"},
      scope: %Scope{kind: :run, id: "run-1", generation: 3},
      generation: 3,
      origin: {:run, "run-1"},
      deadline: 100,
      expected_response: :outcome
    }

    assert {:ok, ^request} = Request.validate(request)

    for origin <- [
          {:draft, {"conversation-1", :main}},
          {:run_revision, "run-1", 9},
          {:agent, "run-1", "agent-9", 99},
          {:interaction, "question-1", 7},
          {:seen, :run, "run-1", 3}
        ] do
      assert {:error, :invalid_request} = Request.validate(%{request | origin: origin})
    end

    correlated = [
      {{:dispatch, :send, "text", :main, []}, {:draft, {"conversation-1", :main}}},
      {{:steer, "run-1", "node-1", "text", []}, {:draft, {"conversation-1", :main}}},
      {{:run_control, :pause, "run-1"}, {:run, "run-1"}},
      {{:retry_run, "run-1", 9}, {:run_revision, "run-1", 9}},
      {{:stop_agent, "run-1", "agent-9", 99}, {:agent, "run-1", "agent-9", 99}},
      {{:answer_question, "run-1", "node-1", "question-1", 7, ["option-1"]},
       {:interaction, "question-1", 7}},
      {{:resolve_approval, "run-1", "node-1", "approval-1", 8, :approve},
       {:interaction, "approval-1", 8}},
      {{:mark_seen, :run, "run-1", 3}, {:seen, :run, "run-1", 3}}
    ]

    for {kind, origin} <- correlated do
      candidate = %{request | kind: kind, origin: origin}
      assert {:ok, ^candidate} = Request.validate(candidate)
    end

    mismatched = [
      {{:dispatch, :send, "text", :main, []}, {:run, "run-1"}},
      {{:steer, "run-1", "node-1", "text", []}, {:interaction, "question-1", 7}},
      {{:run_control, :pause, "run-1"}, {:run, "other-run"}},
      {{:retry_run, "run-1", 9}, {:run_revision, "run-1", 8}},
      {{:retry_run, "run-1", 9}, {:run_revision, "other-run", 9}},
      {{:stop_agent, "run-1", "agent-9", 99}, {:agent, "run-1", "agent-8", 99}},
      {{:stop_agent, "run-1", "agent-9", 99}, {:agent, "run-1", "agent-9", 98}},
      {{:answer_question, "run-1", "node-1", "question-1", 7, ["option-1"]},
       {:interaction, "question-2", 7}},
      {{:answer_question, "run-1", "node-1", "question-1", 7, ["option-1"]},
       {:interaction, "question-1", 6}},
      {{:resolve_approval, "run-1", "node-1", "approval-1", 8, :approve},
       {:interaction, "approval-2", 8}},
      {{:resolve_approval, "run-1", "node-1", "approval-1", 8, :approve},
       {:interaction, "approval-1", 7}},
      {{:mark_seen, :run, "run-1", 3}, {:seen, :conversation, "run-1", 3}},
      {{:mark_seen, :run, "run-1", 3}, {:seen, :run, "other-run", 3}},
      {{:mark_seen, :run, "run-1", 3}, {:seen, :run, "run-1", 2}}
    ]

    for {kind, origin} <- mismatched do
      assert {:error, :invalid_request} =
               Request.validate(%{request | kind: kind, origin: origin})
    end
  end

  test "query cannot carry a current mutation request, while resolver commands can" do
    {:ok, request} =
      RequestResolver.resolve(
        {:run_control, :stop, "run-1"},
        ContractFixtures.run_context("run-1", allowed_actions: [:stop]),
        "request-command",
        100
      )

    assert {:ok, {:command, ^request}} = Effect.validate({:command, request})
    assert {:error, :invalid_effect} = Effect.validate({:query, request})
  end

  test "delivery validation enforces a kind-coherent correlation matrix" do
    scope = %Scope{kind: :conversation, id: "conversation-1", generation: 3}

    ready = %Delivery{
      kind: :watch_ready,
      watch_ref: "watch-1",
      request_id: nil,
      scope: scope,
      generation: 3,
      revision: 4,
      sequence: nil,
      body: %SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow{}
    }

    delta = %{
      ready
      | kind: :delta,
        revision: 4,
        sequence: 9,
        body: %SwarmCodeCLI.UI.DataSource.Delta{
          kind: :snapshot_required,
          revision: 4,
          sequence: 9
        }
    }

    resyncing = %{ready | kind: :resyncing, revision: nil, sequence: nil, body: nil}

    watch_error = %{
      ready
      | kind: :error,
        revision: nil,
        sequence: nil,
        body: AdmissionError.new(:source_unavailable)
    }

    closed = %{ready | kind: :closed, revision: nil, sequence: nil, body: nil}

    response = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: "request-1",
      scope: scope,
      generation: 3,
      revision: nil,
      sequence: nil,
      body: %SwarmCodeCLI.UI.DataSource.DTO.Outcome{status: :accepted, request_id: "request-1"}
    }

    for delivery <- [ready, delta, resyncing, watch_error, closed, response] do
      assert {:ok, ^delivery} = Delivery.validate(delivery)
      assert {:ok, {:data, ^delivery}} = Action.validate({:data, delivery})
    end

    invalid = [
      %{ready | body: nil},
      %{delta | body: nil},
      %{response | body: nil},
      %{response | request_id: nil},
      %{response | watch_ref: "watch-1"},
      %{response | scope: nil},
      %{response | generation: 4},
      %{response | revision: 1},
      %{response | sequence: 1},
      %{ready | request_id: "request-1"},
      %{ready | watch_ref: nil},
      %{ready | scope: nil},
      %{ready | revision: nil},
      %{ready | sequence: 8},
      %{delta | request_id: "request-1"},
      %{delta | watch_ref: nil},
      %{delta | scope: nil},
      %{delta | generation: 4},
      %{delta | revision: nil},
      %{delta | sequence: nil},
      %{resyncing | request_id: "request-1"},
      %{resyncing | watch_ref: nil},
      %{resyncing | scope: nil},
      %{resyncing | revision: 1},
      %{resyncing | sequence: 1},
      %{watch_error | request_id: "request-1"},
      %{watch_error | watch_ref: nil},
      %{watch_error | scope: nil},
      %{watch_error | revision: 1},
      %{watch_error | sequence: 1},
      %{closed | request_id: "request-1"},
      %{closed | watch_ref: nil},
      %{closed | scope: nil}
    ]

    for delivery <- invalid do
      assert {:error, :invalid_delivery} = Delivery.validate(delivery)
      assert {:error, :invalid_action} = Action.validate({:data, delivery})
    end
  end

  test "capability validation rejects oversized forged maps before key traversal" do
    capabilities =
      Capabilities.explicit(%Size{columns: 80, rows: 24},
        stdin_tty?: true,
        stdout_tty?: true,
        controlling_tty?: true
      )

    forged =
      capabilities
      |> Map.from_struct()
      |> Map.merge(Enum.into(1..128, %{}, fn index -> {index, index} end))
      |> Map.put(:__struct__, Capabilities)

    assert {:error, :invalid_action} =
             Action.validate({:terminal_capabilities, 1, forged})
  end
end
