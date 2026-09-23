defmodule SwarmCodeCLI.UI.ReducerNavigationTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    FieldEditors,
    Init,
    Paint,
    Reducer,
    Scene,
    Scroll,
    Size,
    State
  }

  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Request}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Scene.Rect

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

    run = %DTO.RunSummary{
      id: "r",
      conversation_id: "c",
      state: :failed,
      revision: 3,
      allowed_actions: [:retry]
    }

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send],
      runs: [run],
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

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
    state
  end

  test "pending dispatch is synchronous, duplicate blocked, accepted offscreen settles exact draft" do
    state = initial()
    {state, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, "hello"}})
    intent = {:dispatch, :send, "hello", :main, []}
    {pending, [{:command, request}]} = Reducer.update(state, {:invoke, intent, "command"})
    assert pending.mutations[{:draft, {"c", :main}}] == {:pending, "command", intent}
    assert Reducer.update(pending, {:invoke, intent, "command-2"}) == {pending, []}
    {away, effects} = Reducer.update(pending, {:navigate, {:conversation, "other"}})
    refute {:cancel_request, "command"} in effects

    response = %Delivery{
      kind: :response,
      request_id: "command",
      watch_ref: nil,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: %DTO.Outcome{request_id: "command", status: :accepted}
    }

    {settled, []} = Reducer.update(away, {:data, response})
    assert Editor.text(Drafts.fetch(settled.drafts, {"c", :main}).editor) == ""
    assert settled.destination == {:conversation, "other"}
    assert settled.mutations[request.origin] == {:settled, "command", :accepted}
    assert Reducer.update(settled, {:data, response}) == {settled, []}
  end

  test "accepted retry never alters canonical run or draft and stale retry is refused" do
    state = initial()
    {state, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, "unsent"}})
    {rejected, []} = Reducer.update(state, {:invoke, {:retry_run, "r", 2}, "bad"})
    assert rejected.requests == %{}

    {pending, [{:command, request}]} =
      Reducer.update(state, {:invoke, {:retry_run, "r", 3}, "retry"})

    for status <- [
          :accepted,
          :needs_input,
          :rejected,
          :deadline_exceeded,
          :interrupted,
          :revision_conflict,
          :outcome_unknown
        ] do
      response = %Delivery{
        kind: :response,
        request_id: "retry",
        watch_ref: nil,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: outcome(status)
      }

      {settled, []} = Reducer.update(pending, {:data, response})
      assert settled.read_model.runs == state.read_model.runs
      assert settled.drafts == state.drafts
      assert settled.mutations[request.origin] == {:settled, "retry", status}
    end
  end

  test "run workspace refresh installs run detail and clears its pending request" do
    {state, _} = Reducer.update(initial(), {:navigate, {:run, "r"}})
    watch = state.watches.workspace

    request = %Request{
      request_id: "refresh-run",
      kind: {:query, :workspace, nil, :after, 20, 65_536},
      scope: watch.scope,
      generation: watch.generation,
      origin: {:query, :workspace},
      deadline: 30_000,
      expected_response: :workspace_snapshot
    }

    state = %{
      state
      | requests: %{request.request_id => request},
        pages: %{
          workspace: %SwarmCodeCLI.UI.PageState{
            status: :loading_after,
            request_id: request.request_id,
            direction: :after
          }
        }
    }

    run = %DTO.RunSummary{
      id: "r",
      conversation_id: "c",
      title: "Refreshed run",
      kind: :chat,
      state: :running,
      allowed_actions: [:pause]
    }

    body = %DTO.RunDetailSnapshot{
      request_id: request.request_id,
      run: run,
      transcript: %DTO.TranscriptWindow{
        state: :idle,
        presence: :covered,
        items: [],
        covered_ids: []
      }
    }

    delivery = %Delivery{
      kind: :response,
      request_id: request.request_id,
      watch_ref: nil,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: body
    }

    {state, []} = Reducer.update(state, {:data, delivery})
    refute Map.has_key?(state.requests, request.request_id)
    assert state.pages.workspace.status == :idle
    assert state.read_model.snapshots.workspace == body
  end

  defp outcome(status) do
    interaction = %DTO.PendingInteraction{
      id: "i",
      run_id: "r",
      node_id: "n",
      conversation_id: "c",
      kind: :approval,
      allowed_actions: [:approve]
    }

    %DTO.Outcome{
      request_id: "retry",
      status: status,
      interaction: if(status == :needs_input, do: interaction, else: nil),
      error:
        if(status == :rejected,
          do: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed),
          else: nil
        )
    }
  end

  test "navigation cancels queries first and Back restores Activity context" do
    state = initial()
    {activity, _} = Reducer.update(state, {:navigate, :activity})

    activity = %{
      activity
      | filters: %{activity: :unread},
        selection: %{"main" => "selected"},
        focus: "main"
    }

    query = %Request{
      request_id: "query",
      kind: {:query, :activity, nil, :after, 20, 1000},
      scope: activity.watches.activity.scope,
      generation: activity.watches.activity.generation,
      origin: {:query, :activity},
      deadline: 30,
      expected_response: :activity_snapshot
    }

    activity = %{activity | requests: %{"query" => query}}

    {away, [{:cancel_request, "query"}, {:unwatch, _}, {:watch, _}]} =
      Reducer.update(activity, {:navigate, {:run, "r"}})

    {back, _} = Reducer.update(away, :back)
    assert back.destination == :activity
    assert back.filters == activity.filters
    assert back.selection == activity.selection
    assert back.scrolls == activity.scrolls
  end

  test "dirty exit uses complete predicate with safe Cancel; clean whitespace exits" do
    state = initial()
    {clean, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, "  "}})
    assert {_closed, [{:detach, 0}]} = Reducer.update(clean, {:quit_requested, :detach})
    {dirty, []} = Reducer.update(state, {:draft_target, {"c", :main}, {:thread, "node"}})
    {confirm, []} = Reducer.update(dirty, {:presenter_handoff_requested, :plain})
    assert confirm.layers == [{:unsent_changes, :plain}]
    assert confirm.focus == "cancel"
    assert State.dirty?(confirm)
    assert Reducer.update(confirm, {:quit_confirmed, :detach}) == {confirm, []}

    assert {_closed, [{:presenter_handoff, :plain}]} =
             Reducer.update(confirm, {:presenter_handoff_confirmed, :plain})

    fields =
      FieldEditors.put(
        state.field_editors,
        {:region_filter, "search"},
        elem(Editor.apply(Editor.new(max_bytes: 16_384), {:insert, " "}), 1)
      )

    {confirm, []} = Reducer.update(%{state | field_editors: fields}, {:quit_requested, :detach})
    assert confirm.focus == "cancel"
  end

  test "stale terminal events and undo boundaries preserve exact state" do
    state = initial()

    {edited, [{:start_timer, id, 1000, boundary}]} =
      Reducer.update(state, {:editor, {"c", :main}, {:insert, "a"}})

    {continued, [{:cancel_timer, ^id}, {:start_timer, id2, 1000, _}]} =
      Reducer.update(edited, {:editor, {"c", :main}, {:insert, "b"}})

    assert Reducer.update(continued, {:timer_fired, id}) == {continued, []}
    assert id2 != id
    assert Reducer.update(continued, boundary) == {continued, []}
    {closed, _} = Reducer.update(continued, {:timer_fired, id2})
    assert Editor.undo_group_id(Drafts.fetch(closed.drafts, {"c", :main}).editor) == nil
    caps = %{state.capabilities | size: %Size{columns: 60, rows: 20}, ambiguous_width: :wide}
    {new, []} = Reducer.update(continued, {:terminal_capabilities, 3, caps})
    assert new.drafts == continued.drafts
    assert new.scrolls == continued.scrolls
    assert new.size == caps.size
    assert Reducer.update(new, {:terminal_focus, :lost, 2}) == {new, []}
    assert Reducer.update(new, {:terminal_capabilities, 2, state.capabilities}) == {new, []}
  end

  test "max length seeds still emit valid deterministic effects" do
    state = initial()

    init = %Init{
      size: state.size,
      capabilities: state.capabilities,
      source_epoch: String.duplicate("e", 256),
      id_prefix: String.duplicate("p", 256)
    }

    assert {first, effects} = Reducer.init(init)
    assert {^first, ^effects} = Reducer.init(init)
    assert Enum.all?(effects, &match?({:ok, _}, SwarmCodeCLI.UI.Effect.validate(&1)))
  end

  test "nested layers restore each exact opener focus" do
    state = %{initial() | focus: "composer"}
    {help, []} = Reducer.update(state, {:open_layer, :help})
    {nested, []} = Reducer.update(help, {:open_layer, :help})
    {help_again, []} = Reducer.update(nested, :close_top_layer)
    assert help_again.focus == help.focus
    {back, []} = Reducer.update(help_again, :close_top_layer)
    assert back.focus == "composer"
  end

  test "wrong response DTO keeps page request and exact state" do
    state = initial()
    page = %SwarmCodeCLI.UI.PageState{before_cursor: "before"}
    state = %{state | pages: %{workspace: page}}
    {state, [{:query, request}]} = Reducer.update(state, {:retry_page, :workspace, :before})
    wrong = %DTO.ActivitySnapshot{counts: %DTO.Counts{}, request_id: request.request_id}

    delivery = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: wrong
    }

    assert Reducer.update(state, {:data, delivery}) == {state, []}
  end

  test "rejected draft command becomes retryable without clearing its payload" do
    state = initial()
    {state, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, "retain"}})
    intent = {:dispatch, :send, "retain", :main, []}
    {pending, [{:command, request}]} = Reducer.update(state, {:invoke, intent, "send-rejected"})

    body = %DTO.Outcome{
      request_id: request.request_id,
      status: :rejected,
      error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
    }

    delivery = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: body
    }

    {settled, []} = Reducer.update(pending, {:data, delivery})
    assert settled.drafts.pending == %{}
    assert Editor.text(Drafts.fetch(settled.drafts, {"c", :main}).editor) == "retain"
    assert {_, [{:command, _}]} = Reducer.update(settled, {:invoke, intent, "send-retry"})
  end

  test "unavailable shutdown produces a safe announcement" do
    {_, [{:announce, text}]} = Reducer.update(initial(), {:quit_requested, :daemon_shutdown})
    assert SwarmCodeCLI.UI.SafeText.value(text) =~ "unavailable"
  end

  test "agent Stop checks exact identity and revision without optimistic state or draft edits" do
    state = initial()

    agent = %DTO.AgentSummary{
      id: "agent",
      run_id: "r",
      state: :running,
      revision: 4,
      allowed_actions: [:stop_agent]
    }

    state = %{state | read_model: %{state.read_model | agents: %{"agent" => agent}}}
    {state, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, "keep"}})

    assert {_, []} =
             Reducer.update(state, {:invoke, {:stop_agent, "r", "agent", 3}, "stale-agent"})

    assert {_, []} =
             Reducer.update(state, {:invoke, {:stop_agent, "wrong", "agent", 4}, "wrong-agent"})

    {pending, [{:command, request}]} =
      Reducer.update(state, {:invoke, {:stop_agent, "r", "agent", 4}, "agent-stop"})

    assert pending.read_model == state.read_model

    response = %Delivery{
      kind: :response,
      watch_ref: nil,
      request_id: request.request_id,
      scope: request.scope,
      generation: request.generation,
      revision: nil,
      sequence: nil,
      body: %DTO.Outcome{request_id: request.request_id, status: :accepted}
    }

    {settled, []} = Reducer.update(pending, {:data, response})
    assert settled.read_model == state.read_model
    assert settled.drafts == state.drafts
    assert settled.mutations[request.origin] == {:settled, "agent-stop", :accepted}
  end

  # The navigator region was deleted. A session saved while it was focused comes
  # back naming a region the layout no longer draws, and that must be inert, not
  # fatal: Tab has to re-enter the ring on a region that exists, the stale scroll
  # and selection entries have to survive being read, and nothing may crash.
  describe "a session restored onto the deleted navigator" do
    defp stale_navigator_session do
      state = initial()

      %{
        state
        | focus: "navigator",
          hidden_focus: "navigator",
          selection: Map.put(state.selection, "navigator", "r"),
          scrolls:
            Map.put(state.scrolls, :navigator, %Scroll{anchor: {"r", 0, :top}, follow?: false})
      }
    end

    test "Tab no longer offers a region that does not exist" do
      state = stale_navigator_session()
      graph = Reducer.focus_graph(state)

      refute "navigator" in graph
      assert graph == ["main", "inspector", "composer"]
    end

    test "Tab from the stale focus lands on the first region that does exist" do
      state = stale_navigator_session()
      {next, []} = Reducer.update(state, {:focus_cycle, :next})
      assert next.focus == "main"

      {previous, []} = Reducer.update(state, {:focus_cycle, :previous})
      assert previous.focus == "main"

      # And from there Tab keeps walking the real ring.
      {second, []} = Reducer.update(next, {:focus_cycle, :next})
      assert second.focus == "inspector"
    end

    test "focusing the vanished region by name is refused" do
      state = stale_navigator_session()
      assert {^state, []} = Reducer.update(state, {:focus_region, "navigator"})
      assert state.focus == "navigator"
    end

    test "a resize moves the stale focus onto main and keeps the stale entries" do
      state = stale_navigator_session()
      {resized, _} = Reducer.update(state, {:resize, %Size{columns: 100, rows: 24}})

      assert resized.focus == "main"
      assert resized.selection["navigator"] == "r"
      assert resized.scrolls.navigator.anchor == {"r", 0, :top}
    end

    test "the stale state still projects and paints with no navigator region" do
      state = stale_navigator_session()
      {scene, _actions} = SwarmCodeCLI.UI.Projector.project(state)

      assert Scene.validate(scene) == :ok
      refute Enum.any?(scene.regions, &(&1.role == :navigator))

      # Main's band still starts at column 0: the stale navigator reserves
      # nothing. Main centres its 96-cell reading measure inside the 107 columns
      # the 42-cell inspector and its gap leave, so nothing sits to its left.
      main = Enum.find(scene.regions, &(&1.role == :main))
      inspector = Enum.find(scene.regions, &(&1.role == :inspector))
      assert inspector.rect.x - 1 == 107
      assert main.rect == %Rect{x: 0, y: 1, width: 107, height: 34}
      assert main.rect.x == div(107 - main.rect.width, 2)

      docked =
        for region <- scene.regions,
            region.role not in [:title, :tabline, :status],
            region.rect.x < main.rect.x,
            do: {region.role, region.rect}

      assert docked == [], "a pane is docked to the left of main: #{inspect(docked)}"
      assert Enum.find(scene.regions, &(&1.role == :title)).rect.y == 0

      assert {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})
      assert :ok = Plan.validate(plan)
    end

    test "scrolling the vanished region is inert rather than fatal" do
      state = stale_navigator_session()

      # Inert means inert: the stale anchor and selection the sibling test says
      # must survive a resize have to survive a scroll too, and a region drawn
      # nowhere must not page the shell in behind the user's back. Asserting a
      # two-tuple comes back proves nothing — every Reducer.update returns one.
      for operation <- [:first, :last, {:line, 1}, {:page, 1}, {:page, -1}] do
        assert {next, []} = Reducer.update(state, {:scroll, "navigator", operation})

        assert next == state,
               "#{inspect(operation)} changed the state of a region that is drawn nowhere"

        assert %Scroll{anchor: {"r", 0, :top}, follow?: false} = next.scrolls.navigator
        assert next.selection["navigator"] == "r"
      end
    end
  end

  test "select_agent remembers the agent whose operations the inspector shows" do
    state = initial()
    {state, []} = Reducer.update(state, {:select_agent, "agent-2"})
    assert state.tabs.agent == "agent-2"
    assert SwarmCodeCLI.UI.Action.validate({:select_agent, ""}) == {:error, :invalid_action}
  end
end
