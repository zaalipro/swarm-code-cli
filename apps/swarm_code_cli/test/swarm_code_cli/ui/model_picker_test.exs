defmodule SwarmCodeCLI.UI.ModelPickerTest do
  @moduledoc """
  The `/model` and `/swarm_model` picker end to end inside the pure UI: the
  composer's bare command opens it, typing filters it, Enter sends the exact
  `<provider_id>|<model>` command through the draft and closes it, Esc closes
  it, and the palette offers it twice.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    ActionTarget,
    Capabilities,
    Drafts,
    Editor,
    Fixtures,
    Init,
    Input,
    Keymap,
    ModelPicker,
    Paint,
    Projector,
    Reducer,
    Size,
    Switcher
  }

  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}
  alias SwarmCodeCLI.UI.Keymap.Context
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @alpha "11111111-1111-1111-1111-111111111111"
  @beta "22222222-2222-2222-2222-222222222222"

  defp models do
    [
      %DTO.ModelOption{provider_id: @alpha, provider: "Alpha", model: "gpt-5.5"},
      %DTO.ModelOption{provider_id: @alpha, provider: "Alpha", model: "shared-model"},
      %DTO.ModelOption{provider_id: @beta, provider: "Beta", model: "shared-model"},
      %DTO.ModelOption{provider_id: @beta, provider: "Beta", model: "beta-mini"}
    ]
  end

  defp snapshot(models) do
    %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send],
      chat_model: "gpt-5.5",
      swarm_model: "beta-mini",
      models: models,
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }
  end

  # A conversation whose workspace watch is ready, the composer focused.
  defp ready(models \\ models()) do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    watch = state.watches.workspace

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: snapshot(models)
    }

    {state, []} = Reducer.update(state, {:data, delivery})
    state
  end

  defp draft_text(state), do: Editor.text(Drafts.fetch(state.drafts, {"c", :main}).editor)

  defp type(state, text) do
    {state, _} = Reducer.update(state, {:editor, {"c", :main}, {:insert, text}})
    state
  end

  # Enter in the composer, resolved against the table the projector built, the
  # way the session runtime does it.
  defp press(state, code) do
    {_scene, table} = Projector.project(state)
    Keymap.resolve(Input.key(code), state, table)
  end

  defp open_picker(state, text) do
    state = type(state, text)
    assert {:ok, {:open_layer, {:model_picker, _, _} = layer} = action} = press(state, :enter)
    {state, []} = Reducer.update(state, action)
    {state, layer}
  end

  # ── reducer ──────────────────────────────────────────────────────────────

  describe "reducer" do
    test "a bare /model in the composer opens the chat picker and clears the draft" do
      {state, {:model_picker, :chat, id}} = open_picker(ready(), "/model")

      assert [{:model_picker, :chat, ^id}] = state.layers
      assert state.focus == "query"
      assert draft_text(state) == ""
      assert Context.of(state) == :picker

      assert Enum.map(ModelPicker.rows(state, hd(state.layers)), & &1.model) ==
               ["gpt-5.5", "shared-model", "shared-model", "beta-mini"]

      assert Enum.map(ModelPicker.rows(state, hd(state.layers)), & &1.current?) ==
               [true, false, false, false]
    end

    test "/swarm_model opens the swarm picker with the swarm model marked" do
      {state, layer} = open_picker(ready(), "  /swarm_model ")
      assert {:model_picker, :swarm, _} = layer
      rows = ModelPicker.rows(state, layer)
      # The model in use's provider (Beta) is listed first (pass70 Q5).
      assert Enum.map(rows, & &1.current?) == [false, true, false, false]

      assert hd(rows).intent ==
               {:dispatch, :send, "/swarm_model " <> @beta <> "|shared-model", :main, []}
    end

    test "/model with an argument is sent as an ordinary command, not intercepted" do
      state = type(ready(), "/model gpt-5.5")

      assert {:ok, {:invoke, {:dispatch, :send, "/model gpt-5.5", :main, []}, _}} =
               press(state, :enter)
    end

    test "typing filters by model or provider, case-insensitively, and Esc closes" do
      {state, layer} = open_picker(ready(), "/model")

      assert {:ok, {:field_editor, key, {:insert, "B"}}} =
               Keymap.resolve(Input.text_fragment(:press, "B", []), state, %{})

      assert key == ModelPicker.field_key(layer)
      {state, _} = Reducer.update(state, {:field_editor, key, {:insert, "B"}})

      assert Enum.map(ModelPicker.rows(state, layer), &{&1.provider, &1.model}) ==
               [{"Beta", "shared-model"}, {"Beta", "beta-mini"}]

      {state, _} = Reducer.update(state, {:field_editor, key, {:insert, "eta-m"}})
      assert Enum.map(ModelPicker.rows(state, layer), & &1.model) == ["beta-mini"]
      assert Reducer.focus_graph(state) == ["query", @beta <> "|beta-mini", "cancel"]

      assert {:ok, :close_top_layer} = Keymap.resolve(Input.key(:escape), state, %{})
      {closed, []} = Reducer.update(state, :close_top_layer)
      assert closed.layers == []
      assert closed.focus == "composer"
      refute SwarmCodeCLI.UI.FieldEditors.dirty?(closed.field_editors)
    end

    test "Enter on a row sends the exact provider|model command and closes the picker" do
      {state, layer} = open_picker(ready(), "/model")
      row = @beta <> "|shared-model"
      {state, []} = Reducer.update(state, {:focus_region, row})
      assert state.focus == row

      command = "/model " <> @beta <> "|shared-model"

      assert {:ok, {:invoke, {:dispatch, :send, ^command, :main, []} = intent, id}} =
               press(state, :enter)

      {sent, [{:command, request}]} = Reducer.update(state, {:invoke, intent, id})
      assert sent.layers == []
      assert sent.focus == "composer"
      assert draft_text(sent) == command
      assert sent.mutations[{:draft, {"c", :main}}] == {:pending, id, intent}
      assert request.kind == intent

      response = %Delivery{
        kind: :response,
        request_id: id,
        watch_ref: nil,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: %DTO.Outcome{request_id: id, status: :accepted}
      }

      {settled, []} = Reducer.update(sent, {:data, response})
      assert draft_text(settled) == ""
      assert settled.mutations[{:draft, {"c", :main}}] == {:settled, id, :accepted}
      assert ModelPicker.field_key(layer) not in Map.keys(settled.field_editors.entries)
    end

    test "the provider of the model in use is listed first" do
      {state, layer} = open_picker(ready(), "/swarm_model")

      assert [%{provider: "Beta", current?: false}, %{provider: "Beta", current?: true} | rest] =
               ModelPicker.rows(state, layer)

      assert Enum.map(rest, & &1.provider) == ["Alpha", "Alpha"]
      assert Enum.filter(rest, & &1.first_in_group?) |> length() == 1
    end

    test "Enter on the query picks the first row the filter leaves" do
      {state, layer} = open_picker(ready(), "/model")
      key = ModelPicker.field_key(layer)
      {state, _} = Reducer.update(state, {:field_editor, key, {:insert, "mini"}})
      command = "/model " <> @beta <> "|beta-mini"
      assert {:ok, {:invoke, {:dispatch, :send, ^command, :main, []}, _}} = press(state, :enter)
    end

    test "a snapshot with no models leaves one line and nothing to pick" do
      {state, layer} = open_picker(ready([]), "/model")
      assert ModelPicker.rows(state, layer) == []
      assert Reducer.focus_graph(state) == ["query", "cancel"]
      assert press(state, :enter) == :ignore
    end

    test "the palette opens the picker over unsent work and a pick refuses to replace it" do
      state = type(ready(), "keep me")
      entry = Enum.find(Switcher.catalogue(state), &(&1.label == "Switch model…"))
      assert {:local, {:open_layer, {:model_picker, :chat, _} = layer} = action} = entry.target
      {state, []} = Reducer.update(state, action)
      assert hd(state.layers) == layer
      assert draft_text(state) == "keep me"

      assert {:ok, {:invoke, intent, id}} = press(state, :enter)
      {refused, []} = Reducer.update(state, {:invoke, intent, id})
      assert refused.layers == []
      assert draft_text(refused) == "keep me"
      assert {:command_feedback, text} = refused.notice
      assert text =~ "draft"
      assert refused.mutations == %{}
    end

    test "a pick from the palette closes the palette beneath it" do
      state = ready()
      {state, []} = Reducer.update(state, {:open_layer, Switcher.open(state, "composer")})
      entry = Enum.find(Switcher.catalogue(state), &(&1.label == "Switch sub-agent model…"))
      {:local, action} = entry.target
      {state, []} = Reducer.update(state, action)
      assert [{:model_picker, :swarm, _}, {:switcher, _}] = state.layers

      assert {:ok, {:invoke, intent, id}} = press(state, :enter)
      {sent, [{:command, _}]} = Reducer.update(state, {:invoke, intent, id})
      assert sent.layers == []
      assert {:dispatch, :send, "/swarm_model " <> _, :main, []} = intent
    end
  end

  # ── projector ────────────────────────────────────────────────────────────

  defp painted(ascii?) do
    size = %Size{columns: 120, rows: 40}
    caps = %Capabilities{size: size, ambiguous_width: :narrow, ascii?: ascii?}
    state = Fixtures.representative(:chat, size, caps)

    state = %{
      state
      | layers: [{:model_picker, :chat, "layer-1"}],
        focus: "query",
        read_model: %{state.read_model | snapshots: %{workspace: snapshot(models())}}
    }

    {scene, table} = Projector.project(state)
    options = %Options{color_mode: state.capabilities.color_mode, ascii?: ascii?}
    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)
    {scene, table, plan}
  end

  defp row(plan, y) do
    for column <- 0..(plan.size.columns - 1), reduce: "" do
      text ->
        case Plan.cell(plan, column, y) do
          {:glyph, glyph, _, _} -> text <> glyph
          _ -> text
        end
    end
  end

  defp screen(plan), do: Enum.map_join(0..(plan.size.rows - 1), "\n", &row(plan, &1))

  describe "dialog" do
    test "paints every model with its provider, the current one marked" do
      {scene, table, plan} = painted(false)
      assert row(plan, scene.overlay.rect.y) =~ " Model: "
      full = screen(plan)
      assert full =~ "✓ gpt-5.5  Alpha"
      assert full =~ "  shared-model  Alpha"
      assert full =~ "  shared-model  Beta"
      assert full =~ "  beta-mini  Beta"
      assert full =~ "1 of 4 · Enter chooses · Esc closes"

      assert Enum.any?(Map.values(table), fn target ->
               target ==
                 {:intent, {:dispatch, :send, "/model " <> @beta <> "|beta-mini", :main, []}}
             end)
    end

    test "the current mark is one ASCII cell when the terminal has no glyphs" do
      {_scene, _table, plan} = painted(true)
      full = screen(plan)
      assert full =~ "+ gpt-5.5  Alpha"
      refute full =~ "✓"
    end

    test "with no models the body says so" do
      size = %Size{columns: 120, rows: 40}
      caps = %Capabilities{size: size, ambiguous_width: :narrow}
      state = Fixtures.representative(:swarm, size, caps)

      state = %{
        state
        | layers: [{:model_picker, :swarm, "layer-1"}],
          focus: "query",
          read_model: %{state.read_model | snapshots: %{workspace: snapshot([])}}
      }

      {scene, _table} = Projector.project(state)
      {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor, ascii?: false})
      full = screen(plan)
      assert row(plan, scene.overlay.rect.y) =~ " Sub-agent model: "
      assert full =~ "No provider lists any model."
    end
  end

  # ── palette ──────────────────────────────────────────────────────────────

  describe "palette" do
    test "offers both pickers as local actions the reducer accepts" do
      state = ready()
      entries = Switcher.catalogue(state)

      for {label, target} <- [{"Switch model…", :chat}, {"Switch sub-agent model…", :swarm}] do
        assert entry = Enum.find(entries, &(&1.label == label))
        assert entry.kind == :action
        assert {:local, {:open_layer, {:model_picker, ^target, id}}} = entry.target
        assert SwarmCodeCLI.UI.Intent.valid_id?(id)
        assert {:ok, _} = ActionTarget.validate(entry.target)
        assert {:ok, _} = SwarmCodeCLI.UI.Action.validate(elem(entry.target, 1))
      end

      query = elem(Editor.apply(Editor.new(), {:insert, ">switch"}), 1)
      ranked = Switcher.rank(query, entries)
      assert Enum.count(ranked, &String.starts_with?(&1.label, "Switch")) == 2
    end
  end
end
