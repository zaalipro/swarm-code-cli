defmodule SwarmCodeCLI.UI.Pass72OverlayKeysTest do
  @moduledoc """
  Pass 72 owner O: hint mode (P7, K1-K4), the agent overlay (P8, K5) and the
  panel's modes (P6, K6). Every key goes through `Keymap.resolve/3` and
  `Reducer.update/2`, as it does in the session.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.{Projector, Scene}
  alias SwarmCodeCLI.UI.Reducer.Overlay
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  @main {"c", :main}

  # ------------------------------------------------------------------ fixtures

  defp run(id, state, opts \\ []) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "c",
      state: state,
      revision: 3,
      kind: Keyword.get(opts, :kind, :swarm),
      title: Keyword.get(opts, :title, "architecture review"),
      started_at: 1_000,
      allowed_actions: Keyword.get(opts, :actions, [:stop, :pause, :steer])
    }
  end

  defp agent(id, run, opts) do
    %DTO.AgentSummary{
      id: id,
      run_id: run,
      revision: 1,
      state: Keyword.get(opts, :state, :running),
      panel_state: Keyword.get(opts, :panel_state, :working),
      name: Keyword.get(opts, :name, id),
      role: Keyword.get(opts, :role, :worker),
      parent_id: Keyword.get(opts, :parent, "lead"),
      depth: if(Keyword.get(opts, :role) == :lead, do: 0, else: 1),
      started_at: Keyword.get(opts, :started_at, 2_000),
      allowed_actions: [:stop_agent]
    }
  end

  defp approval(id, run, agent) do
    %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: run,
      node_id: "op-" <> id,
      conversation_id: "c",
      expected_revision: 5,
      created_at: 10,
      allowed_actions: [:approve, :deny, :always_allow],
      approval: %DTO.Approval{
        tool: "run_command",
        permission: :execute,
        arguments_preview: "mix test test/web",
        command: "mix test test/web",
        command_family: "mix test",
        agent_id: agent,
        allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
      }
    }
  end

  defp swarm_agents do
    [
      agent("lead", "r1", role: :lead, parent: nil, name: "Lead", started_at: 1_000),
      agent("engine", "r1", name: "engine-lifecycle", started_at: 2_000),
      agent("data", "r1", name: "data-persistence", started_at: 3_000),
      agent("web", "r1", name: "web-ui-desktop", started_at: 4_000)
    ]
  end

  defp ready(opts \\ []) do
    size = Keyword.get(opts, :size, %Size{columns: 160, rows: 45})

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    watch = state.watches.workspace

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send, :queue],
      runs: Keyword.get(opts, :runs, [run("r1", :running)]),
      agents: Keyword.get(opts, :agents, swarm_agents()),
      interactions: Keyword.get(opts, :interactions, []),
      transcript: %DTO.TranscriptWindow{items: Keyword.get(opts, :items, [])},
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

    {state, _} = Reducer.update(state, {:data, delivery})
    state
  end

  defp press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  defp press!(state, input), do: elem(press(state, input), 0)
  defp letter(text, mods \\ []), do: Input.text_fragment(:press, text, mods)
  defp ctrl(text), do: letter(text, [:control])
  defp key(code), do: Input.key(code)
  defp text(state, key), do: Editor.text(Drafts.fetch(state.drafts, key).editor)

  defp type(state, text),
    do: text |> String.graphemes() |> Enum.reduce(state, &press!(&2, letter(&1)))

  defp send_draft(state, text) do
    state = type(state, text)
    intent = {:dispatch, :send, text, :main, []}
    {:ok, action} = Keymap.activate({:intent, intent}, state, %{"send" => {:intent, intent}})
    Reducer.update(state, action)
  end

  defp screen_rows(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = SwarmCodeCLI.UI.Paint.build(scene)

    for y <- 0..(state.size.rows - 1) do
      for x <- 0..(state.size.columns - 1), reduce: "" do
        acc ->
          case SwarmCodeCLI.UI.Paint.Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp commands(effects), do: for({:command, request} <- effects, do: request.kind)

  # ------------------------------------------------------------------ hints

  describe "hint mode" do
    test "Ctrl-F badges the panel; a letter opens that agent's overlay" do
      state = ready() |> press!(ctrl("f"))

      assert %{labels: labels, typed: ""} = state.hint
      assert labels["1"] == {:run, "r1"}
      assert labels["s"] == {:agent, "r1", "lead"}
      assert labels["f"] == {:agent, "r1", "engine"}

      state = press!(state, letter("f"))
      assert state.hint == nil
      assert %{run_id: "r1", node_id: "engine", focus: :activity} = state.overlay
    end

    test "the draft's undo boundary, a second after typing, does not end hint mode" do
      state = ready()
      {state, effects} = press(state, letter("h"))

      {:start_timer, _id, _ms, boundary} =
        Enum.find(effects, &match?({:start_timer, _, _, _}, &1))

      state = press!(state, ctrl("f"))
      {state, _} = Reducer.update(state, boundary)
      assert state.hint != nil
      assert press!(state, letter("f")).overlay.node_id == "engine"
    end

    test "Ctrl-Space (NUL) is the same leader" do
      state = ready()
      assert {:ok, {:hint, :open}} = Keymap.resolve(Input.key(:null), state, %{})
    end

    test "agents that need you get the first letters" do
      agents =
        Enum.map(swarm_agents(), fn
          %{id: "web"} = web -> %{web | state: :waiting_approval, panel_state: :needs_you}
          other -> other
        end)

      state =
        ready(agents: agents, interactions: [approval("a1", "r1", "web")])
        |> Map.put(:layers, [])
        |> press!(ctrl("f"))

      assert state.hint.labels["s"] == {:agent, "r1", "web"}
    end

    test "approval letters never answer in hint mode; Esc cancels" do
      state = ready(interactions: [approval("a1", "r1", "web")]) |> Map.put(:layers, [])
      state = press!(state, ctrl("f"))

      for key <- ~w(y a Y A d D n) do
        {next, effects} = press(state, letter(key))
        assert commands(effects) == []
        assert next.hint == nil
        assert next.overlay == nil
      end

      assert press!(state, key(:escape)).hint == nil
    end

    test "Ctrl-F again is Ctrl-N: the next request waiting on you" do
      state = ready(interactions: [approval("a1", "r1", "web")]) |> Map.put(:layers, [])
      state = state |> press!(ctrl("f")) |> press!(ctrl("f"))
      assert state.hint == nil
      assert [{:approval, "a1"} | _] = state.layers
    end

    test "a digit shows its run in the chat; 0 opens the runs dashboard" do
      items =
        for {id, run} <- [{"t1", "r1"}, {"t2", "r2"}, {"t3", "r2"}] do
          %DTO.TranscriptItem{
            id: id,
            run_id: run,
            conversation_id: "c",
            node_id: "n-" <> id,
            attempt_id: "at",
            text: id
          }
        end

      state = ready(runs: [run("r1", :running), run("r2", :running, title: "api")], items: items)
      state = press!(state, ctrl("f"))
      label = Enum.find_value(state.hint.labels, fn {l, t} -> if t == {:run, "r2"}, do: l end)
      shown = press!(state, letter(label))

      # pass72 G1 (QA Q1): the chat stays the destination and scrolls to the
      # run's first item; a run view would leave Enter with nothing to send.
      assert shown.destination == {:conversation, "c"}
      assert shown.hint == nil
      assert {"t2", 0, :top} = shown.scrolls.main.anchor
      refute shown.scrolls.main.follow?

      typed = type(shown, "still sends")
      {_, table} = Projector.project(typed)
      {:ok, action} = Keymap.resolve(key(:enter), typed, table)
      {_, effects} = Reducer.update(typed, action)
      assert [{:dispatch, :send, "still sends", :main, []}] = commands(effects)

      assert [{:runs_dashboard, _} | _] = state |> press!(letter("0")) |> Map.get(:layers)
    end

    test "Enter in a run view says why nothing was sent" do
      # A run view watches the run, not the conversation: no Send target.
      state = %{ready() | destination: {:run, "r1"}}
      state = update_in(state.read_model.snapshots, &Map.delete(&1, :workspace))
      state = type(state, "hello")
      {_, table} = Projector.project(state)
      {:ok, action} = Keymap.resolve(key(:enter), state, table)
      {state, _} = Reducer.update(state, action)
      assert {:command_feedback, text} = state.notice
      assert text =~ "Alt-Left"
    end

    test "past fifteen agents a label takes two letters; Backspace takes one back" do
      agents = for i <- 1..20, do: agent("a#{i}", "r1", started_at: i)
      state = ready(agents: agents) |> press!(ctrl("f"))
      assert state.hint.labels["pf"] != nil

      state = press!(state, letter("p"))
      assert state.hint.typed == "p"
      assert press!(state, key(:backspace)).hint.typed == ""

      state = press!(state, letter("f"))
      assert state.hint == nil
      assert {:agent, "r1", state.overlay.node_id} == {:agent, "r1", "a16"}
    end
  end

  # ---------------------------------------------------------------- overlay

  describe "the agent overlay" do
    test "Esc gives back the exact chat scroll and draft, even after a steer" do
      state = ready() |> type("half a thought")

      state = %{
        state
        | scrolls: %{
            state.scrolls
            | main: %{state.scrolls.main | follow?: false, anchor: {"x", 3}}
          }
      }

      before = {state.scrolls.main, text(state, @main), state.focus}

      state = state |> press!(ctrl("f")) |> press!(letter("f"))
      assert state.overlay.node_id == "engine"

      state = type(state, "check the flyout too")
      {state, effects} = press(state, key(:enter))

      assert [{:steer, "r1", "engine", "check the flyout too", []}] = commands(effects)
      # The steer made the chat follow its tail, underneath the overlay.
      assert state.scrolls.main.follow? == true

      state = press!(state, key(:escape))
      assert state.overlay == nil
      assert {state.scrolls.main, text(state, @main), state.focus} == before
      assert Keymap.draft_text(state) == "half a thought"
    end

    test "regression (QA Q12): a steer is echoed in the overlay and marked in the chat" do
      state = ready() |> Reducer.update({:overlay_open, "r1", "engine"}) |> elem(0)
      state = type(state, "check the flyout too")
      {state, effects} = press(state, key(:enter))
      assert [{:steer, "r1", "engine", "check the flyout too", []}] = commands(effects)

      rows = screen_rows(state) |> Enum.join("\n")
      assert rows =~ "you: “check the flyout too.”" or rows =~ "you: “check the flyout too”"

      # The daemon records it as a plain user message of the run.
      message = %DTO.TranscriptItem{
        id: "steer-1",
        run_id: "r1",
        conversation_id: "c",
        node_id: "m1",
        attempt_id: "at",
        role: :user,
        kind: :text,
        text: "check the flyout too"
      }

      state = press!(state, key(:escape))
      state = put_in(state.read_model.transcript["steer-1"], message)
      state = update_in(state.read_model.order[:workspace], &((&1 || []) ++ ["steer-1"]))
      assert screen_rows(state) |> Enum.join("\n") =~ "steered to engine-lifecycle"
    end

    test "regression (QA Q14, Q25): a long run title gives way; the name, state and run clock stay" do
      title =
        "/review-changes base= dimensions=correctness,security,performance,maintainability " <>
          "focus= scope=the whole project and everything around it"

      for columns <- [160, 100] do
        state =
          ready(
            size: %Size{columns: columns, rows: 36},
            runs: [run("r1", :running, title: title)]
          )
          |> Reducer.update({:overlay_open, "r1", "data"})
          |> elem(0)

        [header, meta | _] = screen_rows(state)
        assert header =~ "data-persistence  ● working", "#{columns}: " <> header
        assert header =~ "…"
        refute header =~ "base="
        assert meta =~ ~r/run \d+:\d\d/, meta
      end
    end

    test "typed text types; the overlay's draft is its own" do
      state = ready() |> Reducer.update({:overlay_open, "r1", "data"}) |> elem(0)
      # From the activity `o` is the raw operations; any other letter types.
      assert press!(state, letter("o")).overlay.raw_ops?
      state = type(state, "check the flush path")
      assert text(state, {"c", {:agent, "data"}}) == "check the flush path"
      assert text(state, @main) == ""
      assert state.overlay.focus == :composer
    end

    test "[ and ] walk the run's agents in panel order and wrap" do
      state = ready() |> Reducer.update({:overlay_open, "r1", "lead"}) |> elem(0)
      state = press!(state, letter("]"))
      assert state.overlay.node_id == "engine"
      state = state |> press!(letter("]")) |> press!(letter("]")) |> press!(letter("]"))
      assert state.overlay.node_id == "lead"
      assert press!(state, letter("[")).overlay.node_id == "web"
    end

    test "a request does not move the Lead: [ ] and the tree keep the Lead first" do
      agents =
        Enum.map(swarm_agents(), fn
          %{id: "web"} = web -> %{web | state: :waiting_approval, panel_state: :needs_you}
          other -> other
        end)

      state =
        ready(agents: agents, interactions: [approval("a1", "r1", "web")])
        |> Map.put(:layers, [])
        |> Reducer.update({:overlay_open, "r1", "web"})
        |> elem(0)

      assert Enum.map(Overlay.neighbours(state), & &1.id) == ~w(lead engine data web)
      assert press!(state, letter("]")).overlay.node_id == "lead"

      rows = screen_rows(state)
      lead = Enum.find_index(rows, &(&1 =~ ~r/[●◐◌] Lead/u))
      assert lead, "the Lead is the tree's root:\n" <> Enum.join(rows, "\n")
      assert Enum.at(rows, lead + 1) =~ ~r/├ . engine/u
      assert Enum.at(rows, lead + 3) =~ ~r/╰ ! web.*you are here/u
    end

    test "the approval grammar answers only while the composer is empty" do
      state =
        ready(runs: [run("r1", :waiting_approval)], interactions: [approval("a1", "r1", "web")])
        |> Map.put(:layers, [])
        |> Reducer.update({:overlay_open, "r1", "web"})
        |> elem(0)

      assert state.overlay.focus == :band
      {_, effects} = press(state, letter("A"))

      assert [{:resolve_approval, "r1", "op-a1", "a1", 5, :always_prefix}] = commands(effects)

      {_, effects} = press(state, letter("y"))
      assert [{:resolve_approval, "r1", "op-a1", "a1", 5, :approve}] = commands(effects)

      typed = press!(state, letter("w"))
      {typed, effects} = press(typed, letter("y"))
      assert commands(effects) == []
      assert Keymap.draft_text(typed) == "wy"
    end

    test "o shows the raw operations; Tab walks band, activity and composer" do
      state =
        ready(interactions: [approval("a1", "r1", "web")])
        |> Map.put(:layers, [])
        |> Reducer.update({:overlay_open, "r1", "web"})
        |> elem(0)

      state = press!(state, key(:tab))
      assert state.overlay.focus == :activity
      assert press!(state, letter("o")).overlay.raw_ops?
      state = press!(state, key(:tab))
      assert state.overlay.focus == :composer
      # In the composer `o` types.
      assert Keymap.draft_text(press!(state, letter("o"))) == "o"
      assert press!(state, key(:tab)).overlay.focus == :band
    end

    test "under 120 columns the columns are Tab pages" do
      state =
        ready(size: %Size{columns: 100, rows: 30})
        |> Reducer.update({:overlay_open, "r1", "lead"})
        |> elem(0)

      assert {state.overlay.focus, state.overlay.page} == {:activity, 0}
      state = press!(state, key(:tab))
      assert {state.overlay.focus, state.overlay.page} == {:activity, 1}
      state = press!(state, key(:tab))
      assert {state.overlay.focus, state.overlay.page} == {:activity, 2}
      state = press!(state, key(:tab))
      assert state.overlay.focus == :composer
    end

    test "Ctrl-C closes the overlay like a layer" do
      state = ready() |> Reducer.update({:overlay_open, "r1", "lead"}) |> elem(0)
      state = press!(state, ctrl("c"))
      assert state.overlay == nil
      assert state.quit_armed == nil
    end

    test "the overlay covers the whole screen and the scene stays valid" do
      for size <- [%Size{columns: 160, rows: 45}, %Size{columns: 100, rows: 28}] do
        state =
          ready(size: size, interactions: [approval("a1", "r1", "web")])
          |> Map.put(:layers, [])
          |> Reducer.update({:overlay_open, "r1", "web"})
          |> elem(0)

        layout = SwarmCodeCLI.UI.Layout.calculate(size, state.preferences)
        {[region], _cursor} = Projector.Overlay.project(state, layout)
        assert region.rect.width == size.columns and region.rect.height == size.rows

        scene = %Scene{
          size: size,
          revision: 1,
          layout_class: layout.class,
          regions: [region]
        }

        assert Scene.validate(scene) == :ok
        assert {:ok, _plan} = SwarmCodeCLI.UI.Paint.build(scene)
      end
    end
  end

  # ------------------------------------------------------------------ panel

  describe "the panel's mode" do
    test "Ctrl-B cycles full, compact, hidden and asks the session to remember it" do
      state = ready()
      assert state.panel_mode == :full
      {state, effects} = press(state, ctrl("b"))
      assert state.panel_mode == :compact
      assert {:save_preferences, %{panel_mode: :compact}} in effects
      state = press!(state, ctrl("b"))
      assert state.panel_mode == :hidden
      assert press!(state, ctrl("b")).panel_mode == :full
    end

    test "under 120 columns Ctrl-B is strip or off" do
      state = ready(size: %Size{columns: 100, rows: 30})
      state = press!(state, ctrl("b"))
      assert state.panel_mode == :hidden
      assert press!(state, ctrl("b")).panel_mode == :full
    end

    test "/panel compact sets it and clears the command" do
      {state, effects} = send_draft(ready(), "/panel compact")
      assert state.panel_mode == :compact
      assert {:save_preferences, %{panel_mode: :compact}} in effects
      assert Keymap.draft_text(state) == ""

      {state, effects} = send_draft(ready(), "/panel sideways")
      assert state.panel_mode == :full
      refute Enum.any?(effects, &match?({:save_preferences, _}, &1))
    end

    test "the mode the preferences file held arrives without being written back" do
      {state, effects} = Reducer.update(ready(), {:panel_preferences_loaded, :compact})
      assert state.panel_mode == :compact
      assert effects == []
    end
  end

  # ------------------------------------------------------------- the detail

  describe "the agent detail (owner S)" do
    defp screen(state) do
      layout = SwarmCodeCLI.UI.Layout.calculate(state.size, state.preferences)
      {[region], _} = Projector.Overlay.project(state, layout)

      region.blocks
      |> Enum.map_join("\n", fn block ->
        Enum.map_join(block.spans, &SwarmCodeCLI.UI.SafeText.value(&1.text))
      end)
    end

    test "regression (QA Q5): a request whose answer cannot arrive does not block the next" do
      run_id = "7d0f2f9e-3b1c-4c55-9a55-2f1c0e6a0001"
      node = "7d0f2f9e-3b1c-4c55-9a55-2f1c0e6a0002"

      {state, effects} =
        ready(
          runs: [run(run_id, :running)],
          agents: [agent(node, run_id, role: :lead, parent: nil, name: "Lead")]
        )
        |> Reducer.update({:overlay_open, run_id, node})

      assert [{:query, %{kind: {:agent_detail, ^run_id, ^node}}}] = effects
      first = state.overlay.detail_request

      # In flight and fresh: no second request.
      later = %{state | now: state.now + 3_000}
      assert {_, []} = Overlay.request_detail(later, false)

      # The watch resynced: the first answer will be dropped as stale.
      watch = later.watches.workspace
      generation = watch.generation + 1
      watch = %{watch | generation: generation, scope: %{watch.scope | generation: generation}}
      resynced = %{later | watches: %{later.watches | workspace: watch}}
      {next, [{:query, request}]} = Overlay.request_detail(resynced, false)
      assert request.generation == watch.generation
      refute Map.has_key?(next.requests, first)

      # Past the deadline, even in the same generation.
      old = %{state | now: state.now + 11_000}
      assert {_, [{:query, _}]} = Overlay.request_detail(old, false)
    end

    test "regression (QA Q8): without a detail, a command waiting on you is asked, not ran" do
      tool = fn id, name, title, status, at ->
        %DTO.TranscriptItem{
          id: id,
          run_id: "r1",
          conversation_id: "c",
          node_id: "op-" <> id,
          agent_id: "web",
          attempt_id: "at",
          kind: :tool,
          role: :assistant,
          at: at,
          tool: %DTO.ToolCall{name: name, title: title, status: status}
        }
      end

      items = [
        tool.("t1", "find_files", "find *.ex", :done, 1),
        tool.("t2", "list_dir", "list .", :done, 2),
        tool.("t3", "run_command", "run: MIX_TEST_PARTITION=2 mix test", :failed, 3),
        tool.("t4", "run_command", "run: mix test test/web", :waiting_approval, 4)
      ]

      state = ready(items: items) |> Reducer.update({:overlay_open, "r1", "web"}) |> elem(0)
      titles = state |> Projector.Overlay.groups() |> Enum.map(& &1.title)

      assert titles == [
               "searched 1 pattern",
               "looked around: the project",
               "failed: MIX_TEST_PARTITION=2 mix test",
               "asked to run mix test test/web"
             ]

      refute Enum.any?(titles, &(&1 =~ "run:" or &1 =~ "find_files"))
    end

    test "only the answer to the overlay's own request is kept, and it is what the overlay shows" do
      state = ready() |> Reducer.update({:overlay_open, "r1", "web"}) |> elem(0)
      overlay = %{state.overlay | detail_request: "req-1"}
      state = %{state | overlay: overlay}

      detail = %DTO.AgentDetail{
        agent_id: "web",
        run_id: "r1",
        brief: "Review the web UI for focus problems.",
        findings: [
          %DTO.Finding{n: 1, severity: :high, text: "Esc fires twice", ref: "lib/frame.ex:88"}
        ],
        activity: [
          %DTO.ActivityGroup{kind: :read, title: "read 14 files", items: ["chat.ex"], count: 14}
        ],
        life: [:think, :tools, :wait_you],
        files_read: ["chat.ex"],
        context_used: 12_000,
        context_window: 128_000
      }

      stale = %{request_id: "req-0"}
      {kept, []} = Overlay.detail_response(state, stale, detail)
      assert kept.overlay.detail == nil

      own = %{request_id: "req-1"}
      {state, []} = Overlay.detail_response(state, own, detail)
      assert state.overlay.detail == detail

      text = screen(state)
      assert text =~ "Review the web UI for focus problems."
      assert text =~ "Esc fires twice"
      assert text =~ "lib/frame.ex:88"
      assert text =~ "read 14 files"
      assert text =~ "12k of 128k"
      assert text =~ "▂▅▒"
    end
  end
end
