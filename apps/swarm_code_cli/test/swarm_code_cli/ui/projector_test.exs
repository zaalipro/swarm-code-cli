defmodule SwarmCodeCLI.UI.ProjectorTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{ActionTarget, Capabilities, Fixtures, Projector, SafeText, Scene, Size}

  defp fixture(c \\ 150, r \\ 30),
    do: Fixtures.representative(:chat, %Size{columns: c, rows: r}, struct(Capabilities))

  defp texts(%SafeText{} = t), do: [SafeText.value(t)]
  defp texts(%{__struct__: _} = t), do: t |> Map.from_struct() |> texts()
  defp texts(m) when is_map(m), do: m |> Map.values() |> texts()
  defp texts(l) when is_list(l), do: Enum.flat_map(l, &texts/1)
  defp texts(t) when is_tuple(t), do: t |> Tuple.to_list() |> texts()
  defp texts(_), do: []

  test "every boundary projects valid scenes with opaque valid actions" do
    for {c, r} <- [
          {170, 34},
          {169, 34},
          {150, 30},
          {149, 30},
          {150, 29},
          {100, 24},
          {99, 24},
          {100, 23},
          {72, 20},
          {71, 20},
          {72, 19},
          {50, 16},
          {50, 15},
          {50, 14},
          {49, 14},
          {50, 13},
          {1, 1},
          {10, 3}
        ] do
      {scene, actions} = fixture(c, r) |> Projector.project()
      assert Scene.validate(scene) == :ok

      assert Enum.all?(actions, fn {id, target} ->
               is_binary(id) and ActionTarget.validate(target) == {:ok, target}
             end)

      assert Enum.all?(actions, fn {_id, target} ->
               not String.contains?(inspect(scene), inspect(target))
             end)

      if c >= 50 and r >= 14 do
        joined = Enum.join(texts(scene), " ")
        assert joined =~ "NO USER DATA"
        assert joined =~ "Build"
        refute joined =~ "NEEDS"
        refute joined =~ "Target: Main"
        refute joined =~ "Validation: none"
        refute joined =~ "Focus:"
      else
        assert length(scene.regions) == 1
        assert length(hd(scene.regions).blocks) <= min(r, 4)
        refute Enum.join(texts(scene), " ") =~ "FAKE"
        refute Enum.any?(Map.values(actions), &match?({:intent, _}, &1))
      end
    end
  end

  test "saved workspace metadata changes the title and exposes the selected model" do
    state = fixture()

    workspace =
      struct(SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot,
        mode: :plan,
        chat_model: "planner-fixture",
        allowed_actions: [:send]
      )

    state = put_in(state.read_model.snapshots[:workspace], workspace)
    {scene, _} = Projector.project(state)
    title = hd(Enum.filter(scene.regions, &(&1.role == :title)))
    status = hd(Enum.filter(scene.regions, &(&1.role == :status)))
    assert SafeText.value(title.label) == "Plan"
    rendered = Enum.join(texts(status.blocks), " ")
    assert rendered =~ "Plan"
    assert rendered =~ "planner-fixture"
    refute rendered =~ "Build"
    refute Enum.join(texts(scene), " ") =~ "Composer · Build"
  end

  test "run-detail workspace renders without inventing conversation send permission" do
    state = fixture()
    run = hd(Map.values(state.read_model.runs))

    detail = %SwarmCodeCLI.UI.DataSource.DTO.RunDetailSnapshot{
      run: run,
      transcript: %SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow{}
    }

    state = %{state | destination: {:run, run.id}}
    state = put_in(state.read_model.snapshots[:workspace], detail)
    {scene, actions} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    refute Enum.any?(Map.values(actions), &match?({:intent, {:dispatch, _, _, _, _}}, &1))
  end

  test "retry is exact failed revision permission and pending disables it" do
    state = fixture()
    run = hd(Map.values(state.read_model.runs))

    for {status, permissions, enabled} <- [
          {:failed, [:retry], true},
          {:failed, [], false},
          {:running, [:retry], false}
        ] do
      current = %{run | state: status, allowed_actions: permissions, revision: 7}
      next = put_in(state.read_model.runs[run.id], current)
      {_scene, actions} = Projector.project(next)
      target = {:intent, {:retry_run, run.id, 7}}
      assert target in Map.values(actions) == enabled

      {_, pending} =
        Projector.project(%{
          next
          | mutations: %{run.id => {:pending, "request", elem(target, 1)}}
        })

      refute target in Map.values(pending)
    end
  end

  test "agent and run stop permissions are independent" do
    state = Fixtures.representative(:swarm, %Size{columns: 170, rows: 34}, struct(Capabilities))
    run = hd(Map.values(state.read_model.runs))
    agent = hd(Map.values(state.read_model.agents))
    state = put_in(state.read_model.runs[run.id].allowed_actions, [])
    {_, actions} = Projector.project(state)
    assert {:intent, {:stop_agent, run.id, agent.id, agent.revision}} in Map.values(actions)
    refute {:intent, {:run_control, :stop, run.id}} in Map.values(actions)
  end

  test "compressed dialog cannot retain mutation targets and dirty tiny exit is clipped" do
    state = %{fixture(50, 14) | layers: [{:unsent_changes, :detach}], focus: "cancel"}
    {scene, actions} = Projector.project(state)
    assert scene.overlay
    refute {:local, {:quit_confirmed, :detach}} in Map.values(actions)
    {scene, _} = Projector.project(%{state | size: %Size{columns: 10, rows: 3}})
    assert texts(hd(scene.regions).blocks) == ["UNSENT CHA", "Esc CANCEL", "X CONFIRM "]
  end

  test "compressed surface retains only explicit survival actions" do
    {scene, actions} = fixture(50, 14) |> Projector.project()
    assert {:local, {:open_layer, :help}} in Map.values(actions)
    assert {:local, {:quit_requested, :detach}} in Map.values(actions)
    assert {:local, {:presenter_handoff_requested, :plain}} in Map.values(actions)
    status = Enum.find(scene.regions, &(&1.role == :status))
    assert Enum.join(texts(status.blocks), "") =~ "Build"
    refute Enum.any?(Map.values(actions), &match?({:intent, _}, &1))
  end

  test "workspace permission owns dispatch and exact pending text remains hidden" do
    alias SwarmCodeCLI.UI.{Drafts, Editor, State}
    alias SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot
    state = fixture()
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:insert, "private dispatch payload"})
    state = %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}

    state =
      put_in(state.read_model.snapshots[:workspace], %WorkspaceSnapshot{allowed_actions: [:send]})

    {scene, actions} = Projector.project(state)

    assert {:intent, {:dispatch, :send, "private dispatch payload", :main, []}} in Map.values(
             actions
           )

    refute inspect(scene) =~ "private dispatch payload"

    {_, actions} =
      Projector.project(put_in(state.read_model.snapshots[:workspace].allowed_actions, []))

    refute Enum.any?(Map.values(actions), &match?({:intent, {:dispatch, _, _, _, _}}, &1))
  end

  test "complete catalogue and superseded children preserve exact words" do
    for state <- Fixtures.catalogue(%Size{columns: 170, rows: 34}, struct(Capabilities)) do
      {scene, _} = Projector.project(state)
      assert Scene.validate(scene) == :ok
    end

    state = Fixtures.representative(:swarm, %Size{columns: 170, rows: 34}, struct(Capabilities))
    state = put_in(state.read_model.runs["fixture-run"].state, :superseded)

    state =
      update_in(state.read_model.agents, fn agents ->
        Map.new(agents, fn {id, a} -> {id, %{a | launched_by_superseded: true}} end)
      end)

    {scene, actions} = Projector.project(state)
    assert Enum.join(texts(scene), " ") =~ "LAUNCHED BY SUPERSEDED TURN"
    refute {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)
  end

  test "wrapped question auto reveals last focused option and removes background actions" do
    alias SwarmCodeCLI.UI.DataSource.DTO.{PendingInteraction, Question, QuestionOption}

    options =
      for i <- 1..20,
          do: %QuestionOption{id: "option-#{i}", label: String.duplicate("choice ", 15)}

    interaction = %PendingInteraction{
      id: "question",
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      expected_revision: 3,
      question: %Question{prompt: "Choose", options: options},
      allowed_actions: [:answer_question]
    }

    state = fixture(72, 20)
    state = put_in(state.read_model.interactions["question"], interaction)
    state = %{state | layers: [{:question, "question"}], focus: "option-20"}
    {scene, actions} = Projector.project(state)
    assert scene.overlay.body_scroll > 0
    assert scene.overlay.focused_control_id == "option-20"

    assert {:intent, {:answer_question, "fixture-run", "node", "question", 3, ["option-20"]}} in Map.values(
             actions
           )

    refute {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)
    assert Scene.validate(scene) == :ok
  end

  test "large transcript window preserves source order and emits bounded visible blocks" do
    alias SwarmCodeCLI.UI.Scene.Block.VirtualList
    state = fixture(100, 24)
    original = state.read_model.transcript["002"]
    items = for i <- 1..10_000, do: %{original | id: "item-#{i}", text: "row #{i}"}
    order = Enum.map(items, & &1.id)

    state = %{
      state
      | read_model: %{
          state.read_model
          | transcript: Map.new(items, &{&1.id, &1}),
            order: %{workspace: order}
        },
        scrolls: %{main: %{state.scrolls.main | follow?: false, anchor: {"item-9990", 0, :top}}}
    }

    {scene, _} = Projector.project(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, VirtualList))
    assert list.total_count == 10_000
    assert list.first_index == 9989
    assert length(list.items) <= main.rect.height
    # The anchored item is the first thing in the window: its words, with no
    # speaker line repeated above every item of the turn.
    content = list.items |> hd() |> texts() |> Enum.join() |> String.trim()
    assert String.starts_with?(content, "row 9990")
    refute texts(list) |> Enum.join() =~ "row 9989"
  end

  test "page errors expose scoped retry diagnostics while retaining content" do
    alias SwarmCodeCLI.UI.PageState

    state = %{
      fixture()
      | pages: %{
          workspace: %PageState{status: :error, direction: :before, before_cursor: "opaque"}
        }
    }

    {scene, actions} = Projector.project(state)
    assert {:local, {:retry_page, :workspace, :before}} in Map.values(actions)
    assert {:local, {:open_layer, :help}} in Map.values(actions)
    assert Enum.join(texts(scene), " ") =~ "older messages did not load"

    main = Enum.find(scene.regions, &(&1.role == :main))
    assert Enum.any?(main.blocks, &is_struct(&1, Scene.Block.VirtualList))
  end

  test "untrusted single-line labels cannot add rows and policy controls cell clipping" do
    alias SwarmCodeCLI.UI.{Width}
    alias SwarmCodeCLI.UI.Projector.Density
    state = fixture()

    for policy <- [:narrow, :wide] do
      state = %{state | capabilities: %{state.capabilities | ambiguous_width: policy}}
      text = Density.safe("界·界·界\nsecret\e[31m", state, 9)
      assert Width.cells(SafeText.value(text), policy) <= 9
      refute SafeText.value(text) =~ "\n"
      refute Density.safe("a\nb", state, 9) |> SafeText.value() =~ "\n"
      refute SafeText.value(text) =~ "\e"
      path = Density.safe("/long/project/path/final.ex", state, 18, :middle) |> SafeText.value()
      assert String.starts_with?(path, "/long")
      assert String.ends_with?(path, ".ex")
    end
  end

  test "multiple question toggles local choices and submits only explicit selected IDs" do
    alias SwarmCodeCLI.UI.DataSource.DTO.{PendingInteraction, Question, QuestionOption}

    item = %PendingInteraction{
      id: "multi",
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      expected_revision: 8,
      question: %Question{
        prompt: "Choose several",
        multiple: true,
        options: [
          %QuestionOption{id: "one", label: "First"},
          %QuestionOption{id: "two", label: "Second"}
        ]
      },
      allowed_actions: [:answer_question]
    }

    state = fixture()
    state = put_in(state.read_model.interactions[item.id], item)

    state = %{
      state
      | layers: [{:question, item.id}],
        focus: "submit",
        selection: %{{:question, item.id} => ["two"]}
    }

    {scene, actions} = Projector.project(state)
    assert scene.overlay.focused_control_id == "submit"
    assert {:local, {:select_option, "multi", "one"}} in Map.values(actions)

    assert {:intent, {:answer_question, "fixture-run", "node", "multi", 8, ["two"]}} in Map.values(
             actions
           )

    refute {:intent, {:answer_question, "fixture-run", "node", "multi", 8, ["one"]}} in Map.values(
             actions
           )
  end

  test "approval cancel focus and confirmation focus survive projection" do
    alias SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction

    item = %PendingInteraction{
      id: "approval",
      kind: :approval,
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      allowed_actions: [:approve]
    }

    state =
      fixture() |> put_in([Access.key(:read_model), Access.key(:interactions), "approval"], item)

    # The approval itself is drawn in the composer slot, not as a modal.
    {scene, _} = Projector.project(%{state | layers: [{:approval, "approval"}], focus: "cancel"})
    assert scene.overlay == nil
    composer = Enum.find(scene.regions, &(&1.role == :composer))
    assert Enum.join(texts(composer.blocks), "") =~ "once"

    {scene, _} =
      Projector.project(%{state | layers: [{:unsent_changes, :detach}], focus: "confirm"})

    assert scene.overlay.focused_control_id == "confirm"
  end

  test "long prose wraps into a viewport and logical line anchor reveals continuation" do
    state = fixture(72, 20)
    item = state.read_model.transcript["002"]
    item = %{item | text: String.duplicate("readable prose ", 100) <> "END"}

    state = %{
      state
      | read_model: %{
          state.read_model
          | transcript: %{item.id => item},
            order: %{workspace: [item.id]}
        },
        scrolls: %{main: %{state.scrolls.main | follow?: false, anchor: {item.id, 3, :top}}}
    }

    {scene, _} = Projector.project(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    list = Enum.find(main.blocks, &is_struct(&1, Scene.Block.VirtualList))
    prose = hd(list.items) |> texts() |> Enum.join()
    assert prose =~ "\n"
    refute prose =~ "…"
    assert length(String.split(prose, "\n")) <= main.rect.height
  end

  test "inspector focused last agent has its own exact Stop in the scrolling body" do
    state = Fixtures.representative(:swarm, %Size{columns: 72, rows: 20}, struct(Capabilities))
    agent = state.read_model.agents["agent-5"]
    state = %{state | layers: [{:run_inspector, "fixture-run", :agents}], focus: agent.id}
    {scene, actions} = Projector.project(state)
    assert {:intent, {:stop_agent, agent.run_id, agent.id, agent.revision}} in Map.values(actions)
    assert scene.overlay.focused_control_id == agent.id
    assert length(scene.overlay.footer) <= 3
  end

  test "switcher renders ranked query and exact authorized background actions" do
    alias SwarmCodeCLI.UI.{Editor, FieldEditors, Switcher}
    state = fixture()
    layer = {:action_menu, "actions"}
    {:ok, editor} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, ">Stop"})

    state = %{
      state
      | layers: [layer],
        focus: "query",
        field_editors: FieldEditors.put(state.field_editors, Switcher.field_key(layer), editor)
    }

    {scene, actions} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    assert scene.overlay.focused_control_id == "query"
    assert {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)
    assert Enum.join(texts(scene.overlay), " ") =~ ">Stop"
    {_, actions} = Projector.project(%{state | size: %Size{columns: 50, rows: 14}})
    refute Enum.any?(Map.values(actions), &match?({:intent, _}, &1))
  end

  test "steer uses canonical run permission and seen uses exact DTO revision" do
    alias SwarmCodeCLI.UI.{Drafts, Editor, State}
    alias SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot
    state = fixture()
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:insert, "focus tests"})
    state = %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}

    state = %{
      state
      | destination: {:conversation, "fixture-conversation"},
        selection: %{"main" => "002"}
    }

    state = put_in(state.read_model.transcript["002"].allowed_actions, [:inspect, :copy, :fork])
    state = put_in(state.read_model.runs["fixture-run"].allowed_actions, [:steer, :mark_seen])

    state =
      put_in(state.read_model.snapshots[:workspace], %WorkspaceSnapshot{
        conversation_id: "fixture-conversation",
        revision: 12,
        allowed_actions: [:mark_seen]
      })

    {_, actions} = Projector.project(state)

    assert {:intent, {:steer, "fixture-run", "node-002", "focus tests", []}} in Map.values(
             actions
           )

    assert {:intent, {:mark_seen, :run, "fixture-run", 4}} in Map.values(actions)

    assert {:intent, {:mark_seen, :conversation, "fixture-conversation", 12}} in Map.values(
             actions
           )

    intent = {:steer, "fixture-run", "node-002", "focus tests", []}

    forged =
      state
      |> put_in(
        [Access.key(:read_model), Access.key(:runs), "fixture-run", Access.key(:allowed_actions)],
        [:mark_seen]
      )

    forged = put_in(forged.read_model.transcript["002"].allowed_actions, [:steer])
    {_, denied} = Projector.project(forged)
    refute {:intent, intent} in Map.values(denied)
    pending = %{state | mutations: %{{:draft, key} => {:pending, "steer-pending", intent}}}
    {_, disabled} = Projector.project(pending)
    refute {:intent, intent} in Map.values(disabled)
  end

  test "Stop confirmation starts Cancel and rechecks current permission and compressed gate" do
    state = %{
      fixture()
      | layers: [{:confirm_intent, {:run_control, :stop, "fixture-run"}}],
        focus: "cancel"
    }

    {scene, actions} = Projector.project(state)
    assert scene.overlay.focused_control_id == "cancel"
    assert {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)

    {_, actions} =
      Projector.project(put_in(state.read_model.runs["fixture-run"].allowed_actions, []))

    refute {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)
    {_, actions} = Projector.project(%{state | size: %Size{columns: 50, rows: 14}})
    refute Enum.any?(Map.values(actions), &match?({:intent, _}, &1))
  end

  test "empty switcher reports no results without a phantom target" do
    alias SwarmCodeCLI.UI.{Editor, FieldEditors, Switcher}
    state = fixture()
    layer = {:switcher, "no-results"}
    {:ok, editor} = Editor.apply(Editor.new(max_bytes: 16_384), {:insert, "zzzzzz-no-match"})

    state = %{
      state
      | layers: [layer],
        focus: "query",
        field_editors: FieldEditors.put(state.field_editors, Switcher.field_key(layer), editor)
    }

    {scene, actions} = Projector.project(state)
    assert Enum.join(texts(scene.overlay), " ") =~ "NO RESULTS"
    assert Map.values(actions) == [{:local, :close_top_layer}]
  end

  test "canonical detail reference opens bounded inert page with next and retry" do
    alias SwarmCodeCLI.UI.DataSource.DTO.{DetailRef, DetailWindow}
    state = fixture()
    ref = %DetailRef{id: "detail-1", total_bytes: 30_000}
    state = put_in(state.read_model.transcript["002"].detail_ref, ref)
    {_, actions} = Projector.project(state)
    assert {:local, {:open_detail, "fixture-run", ref.id}} in Map.values(actions)

    detail = %{
      run_id: "fixture-run",
      ref: ref,
      window: %DetailWindow{
        detail_ref: ref,
        offset: 0,
        text: String.duplicate("canonical text ", 300),
        next_offset: 16_384,
        request_id: "detail-request"
      },
      status: :idle,
      request_id: nil,
      error: nil,
      history: []
    }

    state = %{state | detail: detail, layers: [{:detail, "fixture-run", ref.id}], focus: "dialog"}
    {scene, actions} = Projector.project(state)
    assert Scene.validate(scene) == :ok
    assert {:local, {:detail_page, :next}} in Map.values(actions)
    assert length(scene.overlay.blocks) <= scene.overlay.rect.height - 4
    assert Enum.join(texts(scene.overlay), " ") =~ "canonical"
    {scene, actions} = Projector.project(%{state | detail: %{detail | status: :error}})
    assert Enum.join(texts(scene.overlay), " ") =~ "Retry"
    assert {:local, {:detail_page, :next}} in Map.values(actions)
  end

  test "accepted interaction stays disabled until canonical revision changes" do
    alias SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction

    item = %PendingInteraction{
      id: "approval",
      kind: :approval,
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      expected_revision: 4,
      allowed_actions: [:approve]
    }

    state =
      fixture() |> put_in([Access.key(:read_model), Access.key(:interactions), "approval"], item)

    state = %{
      state
      | layers: [{:approval, item.id}],
        mutations: %{{:interaction, item.id, 4} => {:settled, "accepted", :accepted}}
    }

    {_, actions} = Projector.project(state)

    refute {:intent, {:resolve_approval, "fixture-run", "node", item.id, 4, :approve}} in Map.values(
             actions
           )

    state = put_in(state.read_model.interactions[item.id].expected_revision, 5)
    {_, actions} = Projector.project(state)

    assert {:intent, {:resolve_approval, "fixture-run", "node", item.id, 5, :approve}} in Map.values(
             actions
           )
  end

  test "pending agent stop does not disable independent run stop" do
    state = Fixtures.representative(:swarm, %Size{columns: 170, rows: 34}, struct(Capabilities))
    agent = state.read_model.agents["agent-1"]

    state = %{
      state
      | mutations: %{
          {:agent, agent.run_id, agent.id, agent.revision} =>
            {:pending, "stop-agent", {:stop_agent, agent.run_id, agent.id, agent.revision}}
        }
    }

    {_, actions} = Projector.project(state)
    assert {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)
    refute {:intent, {:stop_agent, agent.run_id, agent.id, agent.revision}} in Map.values(actions)
  end

  test "conversation projection cannot borrow another conversation's run actions" do
    state = %{fixture() | destination: {:conversation, "different"}}
    {scene, actions} = Projector.project(state)
    refute {:intent, {:run_control, :stop, "fixture-run"}} in Map.values(actions)
    assert Enum.join(texts(scene), " ") =~ "Ready to build"
    refute Enum.join(texts(scene), " ") =~ "EMPTY"
  end

  test "Activity destination projects retained activity and exact mark read revision" do
    alias SwarmCodeCLI.UI.DataSource.DTO.ActivityItem

    item = %ActivityItem{
      id: "activity-test",
      run_id: "fixture-run",
      conversation_id: "fixture-conversation",
      title: "Synthetic failure notice",
      state: :failed,
      revision: 9,
      allowed_actions: [:mark_seen]
    }

    state = fixture()

    state = %{
      state
      | destination: :activity,
        read_model: %{state.read_model | activity: %{item.id => item}}
    }

    {scene, actions} = Projector.project(state)
    assert Enum.join(texts(scene), " ") =~ item.title
    assert {:intent, {:mark_seen, :activity, item.id, 9}} in Map.values(actions)
    main = Enum.find(scene.regions, &(&1.role == :main))
    refute Enum.any?(main.blocks, &is_struct(&1, Scene.Block.RunCard))
  end

  test "operational error notice survives compressed projection" do
    state = %{fixture(50, 14) | notice: {:input_rejected, :paste_too_large}}
    {scene, _} = Projector.project(state)
    assert Enum.join(texts(scene), " ") =~ "Input rejected: paste too large"
  end

  test "resyncing watch keeps transcript with scoped recovery chrome" do
    state = %{fixture() | watches: %{workspace: %SwarmCodeCLI.UI.WatchState{status: :resyncing}}}
    {scene, actions} = Projector.project(state)
    assert Enum.join(texts(scene), " ") =~ "reconnecting"
    assert {:local, {:retry_page, :workspace, :after}} in Map.values(actions)

    assert Enum.any?(
             Enum.find(scene.regions, &(&1.role == :main)).blocks,
             &is_struct(&1, Scene.Block.VirtualList)
           )
  end

  test "focused option longer than dialog body retains one actionable visible portion" do
    alias SwarmCodeCLI.UI.DataSource.DTO.{PendingInteraction, Question, QuestionOption}

    item = %PendingInteraction{
      id: "long-question",
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      expected_revision: 3,
      question: %Question{
        prompt: "Choose",
        options: [%QuestionOption{id: "o", label: String.duplicate("long choice ", 100)}]
      },
      allowed_actions: [:answer_question]
    }

    state = fixture(50, 16)
    state = put_in(state.read_model.interactions[item.id], item)
    state = %{state | layers: [{:question, item.id}], focus: "o"}
    target = {:intent, {:answer_question, item.run_id, item.node_id, item.id, 3, ["o"]}}

    for {columns, rows} <- [{50, 16}, {72, 20}, {150, 30}] do
      {scene, actions} = Projector.project(%{state | size: %Size{columns: columns, rows: rows}})
      assert Scene.validate(scene) == :ok
      assert scene.overlay.focused_control_id == "o"

      if scene.overlay.body_total_count > scene.overlay.rect.height - 4,
        do: assert(scene.overlay.body_scroll > 0)

      assert Enum.count(actions, fn {_, value} -> value == target end) == 1

      assert Enum.any?(scene.overlay.blocks, fn block ->
               Map.get(actions, Map.get(block, :action_id)) == target
             end)

      assert length(scene.overlay.blocks) <= scene.overlay.rect.height - 4
    end

    {_, actions} =
      Projector.project(put_in(state.read_model.interactions[item.id].allowed_actions, []))

    refute target in Map.values(actions)
    {_, actions} = Projector.project(%{state | size: %Size{columns: 50, rows: 14}})
    refute target in Map.values(actions)
  end

  # The navigator used to own the shell run list: a VirtualList of every run in
  # `order.shell`, scrolled by `scrolls.navigator` and revealing
  # `selection["navigator"]`. The dock is gone, so this pins the two things that
  # replaced it — the tab row and the Ctrl-G dashboard — and, most importantly,
  # that a session restored onto the vanished region still projects.
  test "a session restored onto the deleted navigator projects, and its runs live on the tab row and in Ctrl-G" do
    alias SwarmCodeCLI.UI.{Input, Keymap, PageState, Reducer, Scroll, State}
    alias SwarmCodeCLI.UI.Projector.{RunsDashboard, Shell, Support}

    state = fixture(100, 24)
    original = state.read_model.runs["fixture-run"]
    runs = for i <- 1..60, do: %{original | id: "nav-#{i}", title: "Navigator run #{i}"}
    order = runs |> Enum.map(& &1.id) |> Enum.reverse()

    # Exactly what a saved session hands back: focus, selection and a scroll
    # anchor all naming a region that no longer exists.
    stale = %{
      state
      | focus: "navigator",
        read_model: %{
          state.read_model
          | runs: Map.new(runs, &{&1.id, &1}),
            order: %{shell: order}
        },
        selection: %{"navigator" => "nav-5"},
        scrolls:
          Map.put(state.scrolls, :navigator, %Scroll{anchor: {"nav-8", 0, :top}, follow?: false}),
        pages: %{shell: %PageState{before_cursor: "shell-before", after_cursor: "shell-after"}}
    }

    {scene, _actions} = Projector.project(stale)
    assert Scene.validate(scene) == :ok
    refute Enum.any?(scene.regions, &(&1.role == :navigator))

    # Main takes the columns the dock used to hold, at column 0.
    main = Enum.find(scene.regions, &(&1.role == :main))
    assert main.rect.x == 0
    assert main.rect.width == 100
    assert main.rect.y == 1

    # Every run is still accounted for on the one-line tab row: the ones that fit
    # are tabs, the rest are the +N remainder.
    title = Enum.find(scene.regions, &(&1.role == :title))
    assert title.rect == %SwarmCodeCLI.UI.Scene.Rect{x: 0, y: 0, width: 100, height: 1}
    {shown, overflow, _hint} = Shell.tabline_plan(stale, 100)
    assert shown != []
    assert length(shown) + overflow == 60

    # The row is in the order the data source sent, not in a map's hash order:
    # the run being looked at leads, then order[:shell] decides. A count alone
    # would hold for any permutation.
    active = with %{id: id} <- Support.run(stale), do: [id], else: (_ -> [])
    expected = active ++ Enum.reject(order, &(&1 in active))

    assert Enum.map(shown, & &1.id) == Enum.take(expected, length(shown))

    # The list itself moved to the Ctrl-G dashboard, which lists every run in
    # that same shell order.
    {layer_id, _} = State.next_id(stale, :layer)
    {dash, _} = Reducer.update(stale, {:open_layer, {:runs_dashboard, layer_id}})
    assert RunsDashboard.ids(dash) == order

    # It windows that list the way the scrolling VirtualList it replaced did, so
    # what it offers is what it draws: an action id for a row that was painted
    # nowhere is not reachability, it is a table entry nobody can reach.
    {scene, actions} = Projector.project(dash)
    assert Scene.validate(scene) == :ok
    targets = Map.values(actions)
    drawn = dash |> RunsDashboard.window() |> Map.fetch!(:shown) |> Enum.map(& &1.id)

    assert drawn == Enum.take(order, length(drawn))
    assert length(drawn) < 60

    for id <- drawn do
      assert {:local, {:navigate, {:run, id}}} in targets,
             "the dashboard drew #{id} without offering it"
    end

    for id <- order -- drawn do
      refute {:local, {:navigate, {:run, id}}} in targets,
             "the dashboard offered #{id}, which it painted nowhere"
    end

    # And the rows outside the window are reachable, because the window follows
    # the focus the keyboard moves. End lands on the oldest run — the one the
    # navigator could only reach by scrolling — draws it, and opens it.
    assert {:ok, action} = Keymap.resolve(Input.key(:end), dash, actions)
    {ended, _} = Reducer.update(dash, action)
    assert ended.focus == List.last(order)

    {scene, actions} = Projector.project(ended)
    assert Scene.validate(scene) == :ok
    assert scene.overlay.focused_control_id == "nav-1"

    assert {:local, {:navigate, {:run, "nav-1"}}} in Map.values(actions),
           "the dashboard did not draw the row the keyboard moved to"

    assert Keymap.resolve(Input.key(:enter), ended, actions) ==
             {:ok, {:navigate, {:run, "nav-1"}}}

    # Projection is pure: the stale keys are still exactly where they were.
    assert stale.selection["navigator"] == "nav-5"
    assert stale.scrolls.navigator.anchor == {"nav-8", 0, :top}
  end

  test "shared Main content height matches projected lines after chrome and notices" do
    alias SwarmCodeCLI.UI.{Layout, Scroll}
    alias SwarmCodeCLI.UI.Projector.Workspace

    for {columns, rows} <- [{170, 34}, {150, 30}, {100, 24}, {72, 20}, {50, 16}, {50, 14}],
        notice <- [nil, {:input_rejected, :paste_too_large}] do
      state = fixture(columns, rows)
      item = %{state.read_model.transcript["002"] | text: String.duplicate("line\n", 200)}

      state = %{
        state
        | notice: notice,
          read_model: %{
            state.read_model
            | transcript: %{item.id => item},
              order: %{workspace: [item.id]}
          },
          scrolls:
            Map.put(state.scrolls, :main, %Scroll{anchor: {item.id, 0, :top}, follow?: false})
      }

      layout = Layout.calculate(state.size, state.preferences)
      height = Workspace.content_height(state, layout.rects.main, layout.class)
      {scene, _} = Projector.project(state)
      main = Enum.find(scene.regions, &(&1.role == :main))
      list = Enum.find(main.blocks, &is_struct(&1, Scene.Block.VirtualList))

      lines =
        list.items
        |> Enum.map(fn block ->
          block |> texts() |> Enum.join() |> String.split("\n") |> length()
        end)
        |> Enum.sum()

      assert height == lines
      assert height <= layout.rects.main.height
      assert Scene.validate(scene) == :ok
    end
  end
end
