defmodule SwarmCodeCLI.UI.FeatureForm do
  @moduledoc "Bounded editor and typed request builder for feature-library forms."

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, State}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  @max_fields 32

  def open(state, feature, id, %DTO.FeatureForm{} = form) do
    fields = Enum.take(form.fields, @max_fields)
    owner = "feature-form-" <> Integer.to_string(state.id_sequence + 1)

    field_editors =
      Enum.reduce(fields, state.field_editors, fn %DTO.FormField{} = field, acc ->
        editor =
          Editor.new(max_bytes: 16_384, ambiguous_width: state.capabilities.ambiguous_width)

        editor = if field.value == "", do: editor, else: put_initial(editor, field.value)
        FieldEditors.put(acc, {:feature_field, owner, field.key}, editor)
      end)

    state = %{
      state
      | field_editors: field_editors,
        feature_form: %{
          owner: owner,
          feature: feature,
          id: if(id == "new", do: nil, else: id),
          form: form,
          command_id: nil,
          message: nil,
          error: nil
        },
        layers: [{:feature_form, feature, if(id == "new", do: "new", else: id)} | state.layers],
        focus: first_focus(fields, owner),
        hidden_focus: state.focus
    }

    {state, []}
  end

  def value(%{feature_form: %{owner: owner}} = state, key) do
    FieldEditors.fetch(state.field_editors, {:feature_field, owner, key}) |> Editor.text()
  rescue
    ArgumentError -> ""
  end

  def fields(%{feature_form: %{form: %DTO.FeatureForm{fields: fields}}}), do: fields
  def fields(_), do: []

  def editable?(state, key), do: Enum.any?(fields(state), &(&1.key == key))

  def choice?(state, key),
    do: Enum.any?(fields(state), &(&1.key == key and &1.kind in [:choice, :boolean]))

  def focus_graph(%{feature_form: %{owner: owner}} = state) do
    (Enum.map(fields(state), &("field:" <> &1.key)) ++ ["submit", "cancel"])
    |> Enum.filter(fn id -> id in ["submit", "cancel"] or has_field?(state, owner, id) end)
  end

  def cycle(%{feature_form: %{owner: owner, command_id: nil}} = state, key, direction) do
    case Enum.find(fields(state), &(&1.key == key)) do
      %DTO.FormField{kind: :choice, choices: choices} when choices != [] ->
        current = value(state, key)
        index = Enum.find_index(choices, &(&1 == current)) || 0
        next = Enum.at(choices, Integer.mod(index + direction, length(choices)))
        replace(state, owner, key, next)

      %DTO.FormField{kind: :boolean} ->
        replace(
          state,
          owner,
          key,
          if(String.downcase(value(state, key)) == "true", do: "false", else: "true")
        )

      _ ->
        {state, []}
    end
  end

  def cycle(state, _key, _direction), do: {state, []}

  def submit(%{feature_form: nil} = state), do: {state, []}
  def submit(%{feature_form: %{command_id: id}} = state) when not is_nil(id), do: {state, []}

  def submit(%{feature_form: %{feature: feature, id: id, form: form}} = state) do
    case build_attributes(state, fields(state)) do
      {:ok, attrs} ->
        {request_id, state} = State.next_id(state, :feature_command)

        scope =
          if state.destination != :activity and state.watches.workspace.scope,
            do: state.watches.workspace.scope,
            else: state.watches.shell.scope

        request = %Request{
          request_id: request_id,
          kind: {:feature_command, feature, form.action, id, attrs},
          scope: scope,
          generation: scope.generation,
          origin: {:feature_form, feature},
          deadline: state.now + state.deadline_ms,
          expected_response: :outcome
        }

        state = %{
          state
          | feature_form: %{
              state.feature_form
              | command_id: request_id,
                error: nil,
                message: "Working…"
            },
            requests: Map.put(state.requests, request_id, request)
        }

        {state, [{:command, request}]}

      {:error, key, message} ->
        {%{
           state
           | feature_form: %{state.feature_form | error: message, message: nil},
             focus: "field:" <> key
         }, []}
    end
  end

  def command_response(state, request, outcome) do
    state = %{state | requests: Map.delete(state.requests, request.request_id)}

    case state.feature_form do
      %{command_id: id} = form when id == request.request_id ->
        if outcome.status == :accepted do
          {state, close_effects} = close(state)
          {state, close_layer_effects} = close_layer(state)
          {state, refresh} = refresh_library(state)
          {state, close_effects ++ close_layer_effects ++ refresh}
        else
          message =
            case outcome.error do
              %{message: message} when is_binary(message) -> message
              _ -> "Rejected values"
            end

          {%{state | feature_form: %{form | command_id: nil, error: message, message: nil}}, []}
        end

      _ ->
        {state, []}
    end
  end

  def close(%{feature_form: nil} = state), do: {state, []}

  def close(%{feature_form: %{owner: owner}} = state) do
    {state, effects} = clear_timers(state, owner)

    {FieldEditors.close_owner(state.field_editors, owner), effects}
    |> then(fn {fields, effects} ->
      {%{state | field_editors: fields, feature_form: nil}, effects}
    end)
  end

  defp close_layer(
         %{layers: [{:feature_form, _, _} | rest], layer_contexts: [context | contexts]} = state
       ) do
    {%{
       state
       | layers: rest,
         layer_contexts: contexts,
         focus: context.focus,
         hidden_focus: context.hidden_focus
     }, []}
  end

  defp close_layer(state), do: {state, []}

  defp refresh_library(%{library: nil} = state), do: {state, []}
  defp refresh_library(state), do: SwarmCodeCLI.UI.Library.page(state, :refresh)

  defp build_attributes(state, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, attrs} ->
      case parse(field, value(state, field.key)) do
        {:ok, nil} -> {:cont, {:ok, maybe_nil(state.feature_form.feature, attrs, field.key)}}
        {:ok, value} -> {:cont, {:ok, put_value(attrs, field.key, value)}}
        {:error, message} -> {:halt, {:error, field.key, message}}
      end
    end)
  end

  defp put_value(attrs, "arg:" <> key, value),
    do: Map.update(attrs, "args", %{key => value}, &Map.put(&1, key, value))

  defp put_value(attrs, key, value), do: Map.put(attrs, key, value)
  defp maybe_nil(:schedules, attrs, key), do: Map.put(attrs, key, nil)
  defp maybe_nil(:memory, attrs, "content"), do: Map.put(attrs, "content", "")
  defp maybe_nil(_, attrs, _key), do: attrs

  defp parse(%DTO.FormField{required: true, kind: kind, label: label, choices: choices}, text)
       when is_binary(text) do
    if String.trim(text) == "",
      do: {:error, "#{label} is required."},
      else: parse_value(kind, text, label, choices)
  end

  defp parse(%DTO.FormField{kind: :json, choices: choices, label: label, hint: hint}, text),
    do: parse_json(text, label, hint, choices)

  defp parse(%DTO.FormField{kind: kind, choices: choices, label: label}, text),
    do: parse_value(kind, text, label, choices)

  defp parse_value(:text, text, _label, _),
    do: if(String.trim(text) == "", do: {:ok, nil}, else: {:ok, text})

  defp parse_value(:choice, text, label, choices),
    do:
      if(text == "" and choices != [],
        do: {:ok, nil},
        else:
          if(text in choices,
            do: {:ok, text},
            else: {:error, "#{label} must use one of the listed choices."}
          )
      )

  defp parse_value(:boolean, text, _label, _) do
    case String.downcase(String.trim(text)) do
      "" -> {:ok, nil}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "Boolean values must be true or false."}
    end
  end

  defp parse_value(:integer, text, label, _) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:ok, nil}
    else
      case Integer.parse(trimmed) do
        {value, ""} -> {:ok, value}
        _ -> {:error, "#{label} must be a whole number."}
      end
    end
  end

  defp parse_value(:number, text, label, _), do: parse_number(String.trim(text), label)

  defp parse_value(:json, text, label, _) do
    if String.trim(text) == "" do
      {:ok, nil}
    else
      case Jason.decode(text) do
        {:ok, value} -> {:ok, value}
        _ -> {:error, "#{label} must be valid JSON."}
      end
    end
  end

  defp parse_value(_, text, _label, _), do: {:ok, text}

  defp parse_json(text, label, hint, choices) do
    with {:ok, value} <- parse_value(:json, text, label, choices),
         :ok <- json_shape(value, hint, label) do
      {:ok, value}
    end
  end

  defp json_shape(nil, _hint, _label), do: :ok

  defp json_shape(value, hint, label) when is_binary(hint) do
    cond do
      String.contains?(hint, "array") and is_list(value) -> :ok
      String.contains?(hint, "object") and is_map(value) -> :ok
      String.contains?(hint, "array") -> {:error, "#{label} must be a JSON array."}
      String.contains?(hint, "object") -> {:error, "#{label} must be a JSON object."}
      true -> :ok
    end
  end

  defp json_shape(_value, _hint, _label), do: :ok

  defp parse_number("", _), do: {:ok, nil}

  defp parse_number(text, _label) do
    case Float.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> {:error, "Number must be numeric."}
    end
  end

  defp put_initial(editor, value) do
    {:ok, editor} = Editor.apply(editor, {:paste, value})
    editor
  end

  defp replace(state, owner, key, text) do
    field = {:feature_field, owner, key}

    {state, effects} =
      SwarmCodeCLI.UI.Reducer.Editing.apply(state, :field_editor, field, :select_all)

    SwarmCodeCLI.UI.Reducer.Editing.apply(state, :field_editor, field, {:paste, text})
    |> then(fn {s, e} -> {s, effects ++ e} end)
  end

  defp first_focus([], _), do: "submit"
  defp first_focus([field | _], _), do: "field:" <> field.key
  defp has_field?(state, _owner, "field:" <> key), do: Enum.any?(fields(state), &(&1.key == key))
  defp has_field?(_, _, _), do: true
  defp clear_timers(state, owner), do: SwarmCodeCLI.UI.Reducer.Editing.close_fields(state, owner)
end
