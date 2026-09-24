defmodule SwarmCodeCLI.UI.Pass72FinisherTest do
  @moduledoc """
  Pass 72 finisher: the seams between owners S (wire), P (panel) and O (keys,
  overlay), each as a regression. Keys go through `Keymap.resolve/3` with the
  projector's real action table and `Reducer.update/2`, as in the session.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Init, Input, Keymap, Layout, Projector, Reducer, Size}
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  defp run(id, state) do
    %DTO.RunSummary{
      id: id,
      conversation_id: "c",
      state: state,
      revision: 3,
      kind: :swarm,
      title: "architecture review",
      started_at: 1_000,
      allowed_actions: [:stop, :pause, :steer]
    }
  end

  defp agent(id, opts) do
    %DTO.AgentSummary{
      id: id,
      run_id: "r1",
      revision: 1,
      state: :running,
      panel_state: :working,
      now: Keyword.get(opts, :now, "reading lib/a.ex"),
      name: Keyword.get(opts, :name, id),
      role: Keyword.get(opts, :role, :worker),
      parent_id: Keyword.get(opts, :parent, "lead"),
      depth: if(Keyword.get(opts, :role) == :lead, do: 0, else: 1),
      started_at: 2_000,
      allowed_actions: [:stop_agent]
    }
  end

  defp agents do
    [
      agent("lead", role: :lead, parent: nil, name: "Lead"),
      agent("engine", name: "engine-lifecycle"),
      agent("web", name: "web-ui-desktop")
    ]
  end

  defp approval(agent_id) do
    %DTO.PendingInteraction{
      id: "a1",
      kind: :approval,
      run_id: "r1",
      node_id: "op-a1",
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
        agent_id: agent_id,
        allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
      }
    }
  end

  defp question do
    %DTO.PendingInteraction{
      id: "q1",
      kind: :question,
      run_id: "r1",
      node_id: "op-q1",
      conversation_id: "c",
      expected_revision: 7,
      created_at: 10,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: "Which store should the cache use?",
        options: [
          %DTO.QuestionOption{id: "option-1", label: "ETS"},
          %DTO.QuestionOption{id: "option-2", label: "SQLite"}
        ]
      }
    }
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
      runs: [run("r1", Keyword.get(opts, :run_state, :running))],
      agents: agents(),
      interactions: Keyword.get(opts, :interactions, []),
      transcript: %DTO.TranscriptWindow{items: []},
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

  defp open(state, node), do: state |> Reducer.update({:overlay_open, "r1", node}) |> elem(0)

  defp texts(regions) do
    for region <- regions, block <- region.blocks, line <- block_texts(block), do: line
  end

  defp block_texts(%{spans: spans}), do: [Enum.map_join(spans, &SafeText.value(&1.text))]
  defp block_texts(%{items: items}), do: Enum.flat_map(items, &block_texts/1)
  defp block_texts(%{text: %SafeText{} = text}), do: [SafeText.value(text)]
  defp block_texts(_), do: []

  test "an open overlay is what the projector draws, over the whole screen" do
    state = open(ready(), "engine")
    {scene, _table} = Projector.project(state)

    assert Enum.any?(scene.regions, &(&1.id == "agent-overlay"))
    refute Enum.any?(scene.regions, &(&1.role == :inspector))
    assert Enum.join(texts(scene.regions), "\n") =~ "engine-lifecycle"
  end

  test "x in the overlay stops the agent it shows, and asks first" do
    state = open(ready(), "web")
    assert state.overlay.focus != :composer
    {_scene, table} = Projector.project(state)

    assert {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "x", []), state, table)
    {next, _effects} = Reducer.update(state, action)

    assert Enum.any?(next.layers, fn layer ->
             match?({:confirm, _}, layer) or
               inspect(layer) =~ "stop_agent"
           end)

    assert inspect(next.layers) =~ "\"web\""
  end

  test "x with a draft in the overlay composer types, it never stops" do
    state = open(ready(), "web")
    {state, _} = Reducer.update(state, {:overlay, {:focus, :composer}})

    state =
      Enum.reduce(String.graphemes("fi"), state, fn g, acc ->
        {:ok, action} = Keymap.resolve(Input.text_fragment(:press, g, []), acc, %{})
        acc |> Reducer.update(action) |> elem(0)
      end)

    {_scene, table} = Projector.project(state)
    {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "x", []), state, table)
    {next, _} = Reducer.update(state, action)
    assert Keymap.draft_text(next) == "fix"
    assert next.layers == state.layers
  end

  test "an agent the wire still calls working needs you once its request waits" do
    state = ready(interactions: [approval("web")]) |> Map.put(:layers, [])
    rect = Layout.for_state(state).rects.inspector
    {scene, _} = Projector.project(state)

    rows =
      for region <- scene.regions,
          region.rect.x >= rect.x,
          block <- region.blocks,
          do: Enum.map_join(block.spans, &SafeText.value(&1.text))

    assert Enum.any?(rows, &(&1 =~ "! web-ui-desktop"))
    refute Enum.any?(rows, &(&1 =~ "● web-ui-desktop"))
  end

  test "a question dialog is centred over the chat, clear of the docked panel" do
    state = ready(interactions: [question()])
    layout = Layout.for_state(state)
    main = layout.rects.main
    panel = layout.rects.inspector
    assert panel.x >= main.x + main.width

    state = %{state | layers: [{:question, "q1"}]}
    {scene, _} = Projector.project(state)
    dialog = scene.overlay
    assert dialog
    assert dialog.rect.x + dialog.rect.width <= panel.x
    assert abs(dialog.rect.x - (main.x + div(main.width - dialog.rect.width, 2))) <= 1
  end

  test "the palette's side-panel entry shows the key that cycles it" do
    state = ready()
    # Colour, so the palette draws its decorated rows (the key at the right).
    state = %{state | capabilities: %{state.capabilities | color_mode: :truecolor}}
    state = press(state, Input.text_fragment(:press, "p", [:control]))
    assert [{:switcher, _} | _] = state.layers

    state =
      "Side panel"
      |> String.graphemes()
      |> Enum.reduce(state, &press(&2, Input.text_fragment(:press, &1, [])))

    row = state |> painted() |> Enum.find(&(&1 =~ "Side panel: next shape"))
    assert row, "the palette has no side-panel row"
    assert row =~ ~r/(\^|Ctrl-)B/
  end

  # Live run (pass72 F): the approval card a worker raises is a layer, so
  # Ctrl-F read the dialog's keys and did nothing; O's tests cleared the layer.
  test "Ctrl-F over the approval card: badges, the letter opens the overlay, y answers" do
    state = ready(interactions: [approval("web")], run_state: :waiting_approval)
    assert [{:approval, "a1"} | _] = state.layers

    state = press(state, Input.text_fragment(:press, "f", [:control]))
    assert state.hint.labels["s"] == {:agent, "r1", "web"}
    # After the card's typing grace, from the dialog context itself.
    later =
      press(
        %{state | hint: nil, interaction_grace: nil},
        Input.text_fragment(:press, "f", [:control])
      )

    assert later.hint == state.hint

    state = press(state, Input.text_fragment(:press, "s", []))
    assert state.hint == nil
    assert state.overlay.node_id == "web"
    refute Enum.any?(state.layers, &match?({:approval, _}, &1))
    assert Keymap.Context.of(state) == :overlay

    {_scene, table} = Projector.project(state)
    {:ok, action} = Keymap.resolve(Input.text_fragment(:press, "y", []), state, table)
    {_state, effects} = Reducer.update(state, action)

    assert [{:resolve_approval, "r1", "op-a1", "a1", 5, :approve}] =
             for({:command, request} <- effects, do: request.kind)
  end

  test "Ctrl-F stays inert over a dialog that is not a request card" do
    {state, _} = Reducer.update(ready(), {:open_layer, :help})
    assert [layer | _] = state.layers
    assert Keymap.Context.of(state) == :dialog, inspect(layer)
    next = press(state, Input.text_fragment(:press, "f", [:control]))
    assert next.hint == nil
    assert next.layers == state.layers
  end

  defp painted(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      SwarmCodeCLI.UI.Paint.build(scene, %SwarmCodeCLI.UI.Paint.Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

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

  defp press(state, input) do
    {_scene, table} = Projector.project(state)

    case Keymap.resolve(input, state, table) do
      {:ok, action} -> state |> Reducer.update(action) |> elem(0)
      :ignore -> state
    end
  end
end
