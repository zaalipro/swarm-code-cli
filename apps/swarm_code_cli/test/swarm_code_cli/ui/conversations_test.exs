defmodule SwarmCodeCLI.UI.ConversationsTest do
  @moduledoc """
  Pass 70 E3: the session is no longer locked to one conversation. /resume
  and the palette list the project's conversations by title, a pick switches
  the service and then the view, /new starts one, and /approval and /trust
  set the project's mode through the service. The model picker groups by
  provider.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Drafts,
    Editor,
    Init,
    Input,
    Keymap,
    ModelPicker,
    Reducer,
    Size,
    Switcher
  }

  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  @a "11111111-1111-4111-8111-111111111111"
  @b "22222222-2222-4222-8222-222222222222"
  @key {@a, :main}

  defp watch_ready(state, slot, body) do
    watch = Map.fetch!(state.watches, slot)

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

  defp workspace(id, extra \\ []) do
    struct!(
      %DTO.WorkspaceSnapshot{
        conversation_id: id,
        allowed_actions: [:send, :queue],
        transcript: %DTO.TranscriptWindow{},
        runs_page: %DTO.PageInfo{},
        interactions_page: %DTO.PageInfo{}
      },
      extra
    )
  end

  defp ready(extra \\ []) do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, @a},
        focus: "composer"
      })

    state
    |> watch_ready(:shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"}
    })
    |> watch_ready(:workspace, workspace(@a, extra))
  end

  defp type(state, text) do
    {state, _} = Reducer.update(state, {:editor, @key, {:insert, text}})
    state
  end

  defp send_draft(state, text) do
    state = type(state, text)
    intent = {:dispatch, :send, text, :main, []}
    {:ok, action} = Keymap.activate({:intent, intent}, state, %{"send" => {:intent, intent}})
    Reducer.update(state, action)
  end

  # A page answers the request that asked for it, by id.
  defp respond(state, request, body) do
    body =
      if Map.has_key?(body, :request_id), do: %{body | request_id: request.request_id}, else: body

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

    Reducer.update(state, {:data, delivery})
  end

  defp list do
    %DTO.ConversationList{
      project: "ailogic",
      current_id: @a,
      items: [
        %DTO.ConversationSummary{
          id: @a,
          title: "Authentication review",
          run_count: 3,
          live: true,
          current: true
        },
        %DTO.ConversationSummary{id: @b, title: "", run_count: 1}
      ]
    }
  end

  test "/resume opens the palette on the conversations and asks the service for them" do
    {state, effects} = send_draft(ready(), "/resume")
    assert [{:switcher, _} = layer | _] = state.layers
    key = Switcher.field_key(layer)
    assert Editor.text(SwarmCodeCLI.UI.FieldEditors.fetch(state.field_editors, key)) == "#"
    assert Editor.text(Drafts.fetch(state.drafts, @key).editor) == ""

    assert [request] = for({:query, request} <- effects, do: request)
    assert {:conversation_list, nil, 50, _} = request.kind
    assert request.origin == {:conversation, :list}

    {state, []} = respond(state, request, list())
    labels = Enum.map(Switcher.visible(state), & &1.label)

    assert "Authentication review · 3 runs · live · open" in labels
    assert "Untitled conversation · 1 run" in labels
    refute Enum.any?(labels, &String.contains?(&1, @a))
  end

  test "a picked conversation switches the service, then the view follows" do
    {state, effects} = Reducer.update(ready(), {:open_layer, Switcher.open(ready(), "main")})
    [list_request] = for {:query, request} <- effects, do: request
    {state, _} = respond(state, list_request, list())

    entry = Enum.find(Switcher.visible(state), &(&1.target == {:local, {:open_conversation, @b}}))
    assert entry.title == "Untitled conversation"

    {state, effects} = Reducer.update(state, {:open_conversation, @b})
    assert state.layers == []
    assert [request] = for({:command, request} <- effects, do: request)
    assert request.kind == {:conversation_open, @b}
    assert state.destination == {:conversation, @a}

    {state, effects} =
      respond(state, request, %DTO.Outcome{request_id: request.request_id, status: :accepted})

    assert state.destination == {:conversation, @b}
    assert state.focus == "composer"
    assert Enum.any?(effects, &match?({:watch, %{scope: %{kind: :conversation, id: @b}}}, &1))
  end

  test "picking the conversation already open only closes the palette" do
    state = ready()
    {state, _} = Reducer.update(state, {:open_layer, Switcher.open(state, "main")})
    {state, effects} = Reducer.update(state, {:open_conversation, @a})
    assert state.layers == []
    assert for({:command, request} <- effects, do: request) == []
  end

  test "/new starts a conversation and opens it; a refusal says so" do
    {state, effects} = send_draft(ready(), "/new")
    assert [request] = for({:command, request} <- effects, do: request)
    assert request.kind == {:conversation_new}

    {refused, _} =
      respond(state, request, %DTO.Outcome{
        request_id: request.request_id,
        status: :deadline_exceeded
      })

    assert refused.notice == {:command_feedback, "A new conversation could not be started."}

    {state, _} =
      respond(state, request, %DTO.Outcome{
        request_id: request.request_id,
        status: :accepted,
        identifiers: [@b]
      })

    assert state.destination == {:conversation, @b}
  end

  test "/approval sets the project's mode; bare, it says what the mode is" do
    {state, effects} = send_draft(ready(), "/approval full")
    assert [request] = for({:command, request} <- effects, do: request)
    assert request.kind == {:project_update, :full_access, nil}
    assert Editor.text(Drafts.fetch(state.drafts, @key).editor) == ""

    {state, []} = send_draft(ready(approval_mode: :auto), "/approval")
    assert {:command_feedback, "Approval: auto." <> _} = state.notice

    {state, []} = send_draft(ready(), "/approval sometimes")
    assert {:command_feedback, "Approval is read-only, auto or full" <> _} = state.notice
    assert Editor.text(Drafts.fetch(state.drafts, @key).editor) == "/approval sometimes"
  end

  test "/trust trusts the project" do
    {_state, effects} = send_draft(ready(), "/trust")
    assert [request] = for({:command, request} <- effects, do: request)
    assert request.kind == {:project_update, nil, true}
    assert request.origin == {:project, :update}
  end

  test "Enter on the /resume query picks the first conversation" do
    {state, effects} = send_draft(ready(), "/resume")
    [request] = for {:query, request} <- effects, do: request
    {state, _} = respond(state, request, list())
    table = Map.new(Switcher.visible(state), &{&1.id, &1.target})

    assert {:ok, {:open_conversation, @a}} = Keymap.resolve(Input.key(:enter), state, table)
  end

  describe "the model picker" do
    defp options do
      [
        %DTO.ModelOption{provider_id: "p1", provider: "Alpha", model: "a-large"},
        %DTO.ModelOption{provider_id: "p1", provider: "Alpha", model: "shared"},
        %DTO.ModelOption{provider_id: "p2", provider: "Beta", model: "shared"},
        %DTO.ModelOption{provider_id: "p2", provider: "Beta", model: "b-mini"}
      ]
    end

    test "groups rows by provider and checks the model on its own provider" do
      state = ready(models: options(), chat_model: "shared", chat_provider: "Beta")
      layer = ModelPicker.open(state, :chat)
      {state, _} = Reducer.update(state, {:open_layer, layer})
      rows = ModelPicker.rows(state, layer)

      assert Enum.map(rows, &{&1.provider, &1.model, &1.first_in_group?, &1.current?}) == [
               {"Alpha", "a-large", true, false},
               {"Alpha", "shared", false, false},
               {"Beta", "shared", true, true},
               {"Beta", "b-mini", false, false}
             ]
    end

    test "without a provider name the model alone decides" do
      state = ready(models: options(), chat_model: "shared")
      layer = ModelPicker.open(state, :chat)
      {state, _} = Reducer.update(state, {:open_layer, layer})
      assert Enum.count(ModelPicker.rows(state, layer), & &1.current?) == 2
    end
  end
end
