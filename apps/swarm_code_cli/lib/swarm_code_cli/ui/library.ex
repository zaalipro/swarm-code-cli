defmodule SwarmCodeCLI.UI.Library do
  @moduledoc "Owns a bounded, request-correlated feature page without changing conversation watches."
  alias SwarmCodeCLI.UI.{State, FieldEditors, Editor, FeatureForm}
  alias SwarmCodeCLI.UI.DataSource.{Request, DTO}

  @features [
    :workflows,
    :research,
    :schedules,
    :settings,
    :usage,
    :changes,
    :checkpoints,
    :mcp,
    :memory
  ]
  def features, do: @features
  def title(:research), do: "Deep Research"
  def title(:schedules), do: "Scheduled Tasks"
  def title(:mcp), do: "MCP Servers"
  def title(:memory), do: "Memory"
  def title(feature), do: feature |> Atom.to_string() |> String.capitalize()

  def new_form(:schedules) do
    %DTO.FeatureForm{
      title: "New scheduled task",
      submit_label: "Save",
      action: :save,
      fields: [
        %DTO.FormField{key: "name", label: "Name", required: true},
        %DTO.FormField{key: "prompt", label: "Prompt", required: true},
        %DTO.FormField{
          key: "kind",
          label: "Kind",
          kind: :choice,
          choices: ~w(chat swarm workflow),
          value: "chat"
        },
        %DTO.FormField{
          key: "mode",
          label: "Mode",
          kind: :choice,
          choices: ~w(build plan),
          value: "build"
        },
        %DTO.FormField{
          key: "schedule_kind",
          label: "Repeat",
          kind: :choice,
          choices: ~w(once daily weekly monthly cron),
          value: "daily"
        },
        %DTO.FormField{key: "run_at", label: "Run at", hint: "ISO-8601 timestamp for once"},
        %DTO.FormField{key: "time_of_day", label: "Time", value: "09:00"},
        %DTO.FormField{
          key: "weekdays",
          label: "Weekdays",
          kind: :json,
          hint: "JSON array, e.g. [1,5]"
        },
        %DTO.FormField{key: "day_of_month", label: "Day of month", kind: :integer, hint: "1..31"},
        %DTO.FormField{key: "cron", label: "Cron", hint: "Five-field cron expression"},
        %DTO.FormField{key: "timezone", label: "Timezone", value: "Etc/UTC", required: true},
        %DTO.FormField{key: "enabled", label: "Enabled", kind: :boolean, value: "true"},
        %DTO.FormField{key: "catch_up", label: "Catch up", kind: :boolean, value: "true"},
        %DTO.FormField{key: "workflow_name", label: "Workflow name"},
        %DTO.FormField{
          key: "workflow_args",
          label: "Workflow arguments",
          kind: :json,
          hint: "JSON object"
        },
        %DTO.FormField{key: "provider_id", label: "Provider ID"},
        %DTO.FormField{key: "model", label: "Model"},
        %DTO.FormField{
          key: "effort",
          label: "Effort",
          kind: :choice,
          choices: ~w(low medium high max),
          value: "medium"
        },
        %DTO.FormField{
          key: "color",
          label: "Color",
          kind: :choice,
          choices: ~w(orange violet teal green pink yellow),
          value: "orange"
        }
      ]
    }
  end

  def new_form(:mcp) do
    %DTO.FeatureForm{
      title: "New MCP server",
      submit_label: "Save",
      action: :save,
      fields: [
        %DTO.FormField{key: "name", label: "Name", required: true},
        %DTO.FormField{
          key: "transport",
          label: "Transport",
          kind: :choice,
          choices: ~w(stdio http),
          value: "stdio",
          required: true
        },
        %DTO.FormField{key: "command", label: "Command", hint: "stdio command"},
        %DTO.FormField{key: "args", label: "Arguments", kind: :json, hint: "JSON array"},
        %DTO.FormField{key: "url", label: "URL", hint: "http transport"},
        %DTO.FormField{key: "enabled", label: "Enabled", kind: :boolean, value: "true"}
      ]
    }
  end

  def open(state, feature) do
    state = close(state)

    library = %{
      feature: feature,
      request_id: nil,
      command_id: nil,
      body: nil,
      cursor: nil,
      previous: [],
      selected: nil,
      confirmation: nil,
      message: nil
    }

    request(%{state | library: library}, nil)
  end

  def page(
        %{library: %{request_id: nil, body: %DTO.LibrarySnapshot{} = body} = library} = state,
        :next
      )
      when not is_nil(body.after_cursor),
      do:
        request(
          %{state | library: %{library | previous: [library.cursor | library.previous]}},
          body.after_cursor
        )

  def page(
        %{library: %{request_id: nil, previous: [cursor | rest]} = library} = state,
        :previous
      ),
      do: request(%{state | library: %{library | previous: rest}}, cursor)

  def page(%{library: %{request_id: nil} = library} = state, :refresh),
    do: request(state, library.cursor)

  def page(state, _), do: {state, []}

  def command(
        %{library: %{request_id: nil, command_id: nil, feature: feature, body: body}} = state,
        id,
        action
      )
      when is_binary(id) and is_atom(action) do
    allowed =
      not is_nil(body) and body.state == :idle and
        Enum.any?(body.items, &(&1.id == id and action in &1.actions))

    cond do
      not allowed ->
        {state, []}

      action in [:delete, :restore, :clear] ->
        {%{
           state
           | library: %{state.library | confirmation: {id, action}},
             focus: "cancel_action"
         }, []}

      action == :start and feature == :workflows ->
        case Enum.find(body.items, &(&1.id == id)) do
          %{form: %DTO.FeatureForm{} = form} ->
            context = %{focus: state.focus, hidden_focus: state.hidden_focus}

            FeatureForm.open(
              %{state | layer_contexts: [context | state.layer_contexts]},
              feature,
              id,
              form
            )

          _ ->
            send_command(state, feature, id, action)
        end

      true ->
        send_command(state, feature, id, action)
    end
  end

  def command(state, _id, _action), do: {state, []}

  def confirm(
        %{library: %{confirmation: {id, action}, command_id: nil, feature: feature}} = state,
        true
      ),
      do:
        send_command(
          %{state | library: %{state.library | confirmation: nil}},
          feature,
          id,
          action
        )

  def confirm(%{library: library} = state, false) when not is_nil(library),
    do: {%{state | library: %{library | confirmation: nil}, focus: "cancel"}, []}

  def confirm(state, _), do: {state, []}

  def select(%{library: %{body: body} = library} = state, id) when not is_nil(body) do
    if Enum.any?(body.items, &(&1.id == id)),
      do: {%{state | library: %{library | selected: id}}, []},
      else: {state, []}
  end

  def select(state, _), do: {state, []}

  def rows(%{library: %{body: %{items: items}}}), do: Enum.with_index(items)
  def rows(_), do: []

  def selected(%{library: %{selected: selected}} = state),
    do: Enum.find_value(rows(state), fn {item, _} -> if item.id == selected, do: item end)

  def selected(_), do: nil

  def controls(%{library: %{confirmation: value}}) when not is_nil(value),
    do: [
      {"confirm", "Confirm", {:library_confirm, true}},
      {"cancel_action", "Cancel", {:library_confirm, false}}
    ]

  def controls(state) do
    item = selected(state)

    form_control =
      if item && item.form,
        do: [
          {"form", item.form.submit_label,
           {:open_layer, {:feature_form, state.library.feature, item.id}}}
        ],
        else: []

    actions =
      if item && state.library.command_id == nil && state.library.request_id == nil,
        do:
          Enum.filter(
            item.actions,
            &(&1 in [
                :start,
                :pause,
                :resume,
                :stop,
                :delete,
                :restore,
                :retry,
                :report,
                :toggle,
                :run_now,
                :clear
              ])
          ),
        else: []

    new =
      cond do
        state.library.feature == :research ->
          [{"new-research", "New research", {:open_layer, {:research_form, "research-form"}}}]

        state.library.feature == :schedules ->
          [
            {"new-schedule", "New scheduled task",
             {:open_layer, {:feature_form, :schedules, "new"}}}
          ]

        state.library.feature == :mcp ->
          [{"new-mcp", "New MCP server", {:open_layer, {:feature_form, :mcp, "new"}}}]

        true ->
          []
      end

    new ++
      form_control ++
      Enum.map(actions, fn action ->
        {"cmd-" <> Atom.to_string(action), label(action),
         {:library_command, state.library.feature, item.id, action}}
      end) ++
      [
        {"previous", "Previous", {:library_page, :previous}},
        {"next", "Next", {:library_page, :next}},
        {"refresh", "Refresh", {:library_page, :refresh}},
        {"cancel", "Close", :close_top_layer}
      ]
  end

  def activation(state, focus) do
    Enum.find_value(rows(state), fn {item, index} ->
      if focus == "row-#{index}", do: {:library_select, item.id}
    end) || Enum.find_value(controls(state), fn {id, _, action} -> if id == focus, do: action end)
  end

  def focus_graph(%{library: %{confirmation: c}} = state) when not is_nil(c),
    do: Enum.map(controls(state), &elem(&1, 0))

  def focus_graph(state),
    do:
      Enum.map(rows(state), fn {_, index} -> "row-#{index}" end) ++
        Enum.map(controls(state), &elem(&1, 0))

  defp label(:run_now), do: "Run now"
  defp label(action), do: action |> Atom.to_string() |> String.capitalize()

  defp send_command(state, feature, id, action) do
    {request_id, state} = State.next_id(state, :library_command)

    scope = scope_for(state, feature)

    request = %Request{
      request_id: request_id,
      kind: {:feature_command, feature, action, id, %{}},
      scope: scope,
      generation: scope.generation,
      origin: {:feature, feature},
      deadline: state.now + state.deadline_ms,
      expected_response: :outcome
    }

    {%{
       state
       | library: %{state.library | command_id: request_id, message: "Working…"},
         requests: Map.put(state.requests, request_id, request)
     }, [{:command, request}]}
  end

  def command_response(state, request, outcome) do
    state = %{state | requests: Map.delete(state.requests, request.request_id)}

    case state.library do
      %{command_id: id} = library when id == request.request_id ->
        message =
          case outcome.status do
            :accepted ->
              "Done"

            :outcome_unknown ->
              "The connection closed before the result arrived. Refresh to check the result."

            _ ->
              if outcome.error, do: outcome.error.message, else: "Action was not completed."
          end

        state = %{state | library: %{library | command_id: nil, message: message}}

        if outcome.status == :accepted do
          {state, close_effects} =
            if state.layers != [] and match?({:research_form, _}, hd(state.layers)),
              do: SwarmCodeCLI.UI.Reducer.update(state, :close_top_layer),
              else: {state, []}

          {state, refresh_effects} = page(state, :refresh)
          {state, close_effects ++ refresh_effects}
        else
          {state, []}
        end

      _ ->
        {state, []}
    end
  end

  defp request(state, cursor) do
    {id, state} = State.next_id(state, :library)

    scope = scope_for(state, state.library.feature)

    query = %Request{
      request_id: id,
      kind: {:feature_query, state.library.feature, nil, cursor, 20, 262_144},
      scope: scope,
      generation: scope.generation,
      origin: {:feature, state.library.feature},
      deadline: state.now + state.deadline_ms,
      expected_response: :library_snapshot
    }

    {%{
       state
       | library: %{state.library | request_id: id, cursor: cursor},
         requests: Map.put(state.requests, id, query)
     }, [{:query, query}]}
  end

  def response(
        %{library: %{request_id: id, feature: feature} = library} = state,
        %{request_id: id},
        %DTO.LibrarySnapshot{feature: feature} = body
      ),
      do:
        {%{
           state
           | library: %{
               library
               | request_id: nil,
                 body: body,
                 selected:
                   if(Enum.any?(body.items, &(&1.id == library.selected)),
                     do: library.selected,
                     else: List.first(body.items) && hd(body.items).id
                   )
             },
             requests: Map.delete(state.requests, id)
         }, []}

  def response(state, _, _), do: {state, []}

  def close(%{library: nil} = state), do: state

  def close(state),
    do: %{state | requests: Map.delete(state.requests, state.library.request_id), library: nil}

  def start_research(state) do
    if state.layers == [] or not match?({:research_form, _}, hd(state.layers)) or
         state.library.command_id do
      {state, []}
    else
      q =
        FieldEditors.fetch(state.field_editors, {:research_question, "research-form"})
        |> Editor.text()
        |> String.trim()

      depth = Map.get(state.selection, {:research_form, :depth}, :medium)

      if q == "" do
        {%{
           state
           | notice: "Enter a research question before starting.",
             library: %{state.library | message: "Enter a research question before starting."}
         }, []}
      else
        {id, state} = State.next_id(state, :library_command)

        scope = scope_for(state, :research)

        attrs = %{"question" => q, "level" => Atom.to_string(depth)}

        request = %Request{
          request_id: id,
          kind: {:feature_command, :research, :start, nil, attrs},
          scope: scope,
          generation: scope.generation,
          origin: {:feature, :research},
          deadline: state.now + state.deadline_ms,
          expected_response: :outcome
        }

        {%{
           state
           | library: %{state.library | command_id: id, message: "Starting…"},
             requests: Map.put(state.requests, id, request)
         }, [{:command, request}]}
      end
    end
  end

  defp scope_for(state, :settings), do: state.watches.shell.scope

  defp scope_for(state, _feature),
    do:
      if(state.destination != :activity and state.watches.workspace.scope,
        do: state.watches.workspace.scope,
        else: state.watches.shell.scope
      )
end
