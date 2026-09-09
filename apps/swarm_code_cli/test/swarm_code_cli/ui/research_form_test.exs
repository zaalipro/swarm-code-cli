defmodule SwarmCodeCLI.UI.ResearchFormTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Action,
    Capabilities,
    Drafts,
    Editor,
    FieldEditors,
    FieldKey,
    Init,
    Input,
    Keymap,
    Library,
    Projector,
    Reducer,
    SafeText,
    Size
  }

  alias SwarmCodeCLI.UI.DataSource.DTO

  defp ready do
    size = %Size{columns: 120, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "epoch"
      })

    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :research}})

    {state, []} =
      Library.response(state, request, %DTO.LibrarySnapshot{
        feature: :research,
        request_id: request.request_id
      })

    state
  end

  defp form do
    state = ready()
    action = Library.activation(state, "new-research")
    {state, []} = Reducer.update(state, action)
    state
  end

  defp input(state, input) do
    {:ok, action} = Keymap.resolve(input, state, %{})
    Reducer.update(state, action)
  end

  test "new form has a bounded question, default medium depth and safe projection" do
    state = form()
    assert state.focus == "question"
    assert {:ok, _} = FieldKey.validate({:research_question, "research-form"})

    assert {:error, :invalid_field_key} =
             FieldKey.validate({:research_question, "research-form", :arbitrary})

    {state, effects} = input(state, Input.paste("Compare databases\nincluding b trees\e[31m"))
    refute Enum.any?(effects, &match?({:command, _}, &1))
    assert :ignore == Keymap.resolve(Input.key(:enter), state, %{})
    {state, _} = input(state, Input.text_fragment(:press, "b", []))

    assert Editor.text(
             FieldEditors.fetch(state.field_editors, {:research_question, "research-form"})
           ) =~ "b"

    assert {:ok, {:field_editor, _, {:move, :left}}} =
             Keymap.resolve(Input.key(:left), state, %{})

    {scene, _} = Projector.project(state)
    assert SafeText.value(scene.overlay.title) == "New research"

    assert Enum.any?(
             scene.overlay.footer,
             &(Map.has_key?(&1, :text) and SafeText.value(&1.text) =~ "Start")
           )

    {pending, [{:command, request}]} = Reducer.update(%{state | focus: "start"}, :research_start)

    assert {:feature_command, :research, :start, nil,
            %{"question" => question, "level" => "medium"}} = request.kind

    assert question =~ "Compare databases"
    refute Map.has_key?(elem(request.kind, 4), "project_id")
    assert request.scope == state.watches.shell.scope
    assert {^pending, []} = Reducer.update(pending, :research_start)
  end

  test "blank validation, depth choice, rejection retention and accepted refresh" do
    state = form()
    {invalid, []} = Reducer.update(state, :research_start)
    assert invalid.library.message =~ "question"
    {state, _} = input(invalid, Input.paste("Study scheduling"))
    {state, []} = Reducer.update(state, {:research_depth, :ultra})
    {pending, [{:command, request}]} = Reducer.update(state, :research_start)
    assert elem(request.kind, 4)["level"] == "ultra"

    error = %{
      code: :invalid_request,
      message: "Configure a default research provider in Settings."
    }

    {rejected, []} =
      Library.command_response(pending, request, %DTO.Outcome{
        request_id: request.request_id,
        status: :rejected,
        error: error
      })

    assert rejected.layers == state.layers
    assert rejected.field_editors == state.field_editors
    assert rejected.library.message =~ "Settings"
    {pending, [{:command, request}]} = Reducer.update(rejected, :research_start)

    {accepted, effects} =
      Library.command_response(pending, request, %DTO.Outcome{
        request_id: request.request_id,
        status: :accepted
      })

    assert accepted.layers == [{:library, :research}]
    assert Enum.any?(effects, &match?({:query, _}, &1))

    assert Editor.text(
             FieldEditors.fetch(accepted.field_editors, {:research_question, "research-form"})
           ) == ""
  end

  test "cancel preserves composer, clears form and restores library focus" do
    state = ready()
    key = {"conversation", :main}
    {state, _} = Reducer.update(state, {:editor, key, {:paste, "composer draft"}})
    {state, []} = Reducer.update(state, Library.activation(state, "new-research"))
    {state, _} = input(state, Input.paste("unsent research"))
    {state, []} = Reducer.update(state, {:research_depth, :high})
    {closed, _} = input(state, Input.key(:escape))
    assert closed.layers == [{:library, :research}]
    assert Editor.text(Drafts.fetch(closed.drafts, key).editor) == "composer draft"

    assert Editor.text(
             FieldEditors.fetch(closed.field_editors, {:research_question, "research-form"})
           ) == ""

    {reopened, []} = Reducer.update(closed, Library.activation(closed, "new-research"))
    assert Map.get(reopened.selection, {:research_form, :depth}) == :medium
  end

  test "question bound and closed depth reject invalid input" do
    state = form()
    {rejected, []} = input(state, Input.paste(String.duplicate("x", 4_001)))
    assert rejected.notice == {:editor_error, :text_too_large}
    assert {:error, :invalid_action} = Action.validate({:research_depth, :huge})
    assert {state, []} == Reducer.update(state, {:research_depth, :huge})
    {scene, _} = Projector.project(rejected)

    assert Enum.any?(
             scene.overlay.blocks,
             &(Map.has_key?(&1, :text) and SafeText.value(&1.text) =~ "4,000")
           )

    {:ok, oversized} =
      Editor.apply(Editor.new(max_bytes: 16_384), {:paste, String.duplicate("x", 4_001)})

    assert_raise ArgumentError, fn ->
      FieldEditors.put(state.field_editors, {:research_question, "research-form"}, oversized)
    end
  end

  test "form controls are inert outside the form and pending edits cannot change submitted values" do
    state = ready()
    assert {^state, []} = Reducer.update(state, :research_start)
    assert {^state, []} = Reducer.update(state, {:research_depth, :high})
    state = form()
    {state, _} = input(state, Input.paste("Research concurrency"))
    {pending, [{:command, _}]} = Reducer.update(state, :research_start)
    assert :ignore = Keymap.resolve(Input.paste("extra"), pending, %{})
    assert {^pending, []} = Reducer.update(pending, {:research_depth, :low})
    assert {^pending, []} = Reducer.update(pending, {:open_layer, {:research_form, "another"}})
  end

  test "cancel and successful submission cancel undo timers without changing other editors" do
    state = form()

    {state, [{:start_timer, id, _, _}]} =
      input(state, Input.text_fragment(:press, "Question", []))

    {closed, effects} = input(state, Input.key(:escape))
    assert {:cancel_timer, id} in effects
    assert closed.timers == %{}
    assert {^closed, []} = Reducer.update(closed, {:timer_fired, id})
    state = form()

    {state, [{:start_timer, id, _, _}]} =
      input(state, Input.text_fragment(:press, "Question", []))

    {pending, [{:command, request}]} = Reducer.update(state, :research_start)

    {closed, effects} =
      Library.command_response(pending, request, %DTO.Outcome{
        request_id: request.request_id,
        status: :accepted
      })

    assert {:cancel_timer, id} in effects
    assert closed.timers == %{}
  end
end
