defmodule SwarmCodeCLI.UI.Reducer.Editing do
  @moduledoc false
  alias SwarmCodeCLI.UI.{Drafts, FieldEditors, Editor, State}

  def apply(state, kind, key, operation) do
    editor = editor(state, kind, key)

    case Editor.apply(editor, operation) do
      {:ok, ^editor} ->
        {state, []}

      {:ok, next} ->
        state = put(state, kind, key, next)
        timer_key = {kind, key}
        timer = Map.get(state.timers, timer_key)
        group = Editor.undo_group_id(next)
        effects = if timer, do: [{:cancel_timer, timer.id}], else: []
        state = %{state | timers: Map.delete(state.timers, timer_key)}

        if group && Editor.text(next) != Editor.text(editor) do
          {id, state} = State.next_id(state, :undo)
          action = {kind, key, {:undo_boundary, group}}
          timer = %{id: id, boundary_id: group, action: action}

          {%{state | timers: Map.put(state.timers, timer_key, timer)},
           effects ++ [{:start_timer, id, 1_000, action}]}
        else
          {state, effects}
        end

      {:error, error} ->
        {%{state | notice: {:editor_error, error}}, []}
    end
  rescue
    ArgumentError -> {%{state | notice: :editor_capacity_reached}, []}
  end

  def timer(state, id) do
    case Enum.find(state.timers, fn {_, timer} -> timer.id == id end) do
      nil -> {state, []}
      {{kind, key}, timer} -> __MODULE__.apply(state, kind, key, elem(timer.action, 2))
    end
  end

  def target(state, key, target) do
    draft = Drafts.fetch(state.drafts, key)
    {%{state | drafts: Drafts.put(state.drafts, %{draft | target: target})}, []}
  rescue
    ArgumentError -> {%{state | notice: :draft_capacity_reached}, []}
  end

  defp editor(state, :editor, key), do: Drafts.fetch(state.drafts, key).editor
  defp editor(state, :field_editor, key), do: FieldEditors.fetch(state.field_editors, key)

  defp put(state, :editor, key, editor) do
    draft = Drafts.fetch(state.drafts, key)

    %{
      state
      | drafts: Drafts.put(state.drafts, %{draft | editor: editor}),
        selection: Map.put(state.selection, "composer_draft", key)
    }
  end

  defp put(state, :field_editor, key, editor),
    do: %{state | field_editors: FieldEditors.put(state.field_editors, key, editor)}
end
