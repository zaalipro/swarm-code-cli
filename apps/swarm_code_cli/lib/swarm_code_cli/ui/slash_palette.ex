defmodule SwarmCodeCLI.UI.SlashPalette do
  @moduledoc "Pure builtin command completion. Suggestions never execute or dispatch a command."

  alias SwarmCode.Commands
  alias SwarmCodeCLI.UI.{Drafts, Editor, State}
  alias SwarmCodeCLI.UI.Reducer.Editing

  @doc "Validate a canonical builtin name without accepting input arguments or dynamic atoms."
  def valid_name?(name) do
    is_binary(name) and byte_size(name) <= 256 and String.valid?(name) and
      Enum.any?(Commands.catalogue(), &(&1.name == name))
  end

  @doc "Suggestions only apply to the entire first token, with the caret at its end."
  def entries(state) do
    case context(state) do
      nil -> []
      {_key, query} -> Commands.catalogue(query)
    end
  end

  def open?(state), do: entries(state) != []

  def selected(state) do
    Enum.at(entries(state), index(state))
  end

  @doc "A bounded window which always includes the current selection."
  def visible(state, limit) when is_integer(limit) and limit > 0 do
    items = entries(state)
    selected = index(state)
    first = max(0, min(selected, length(items) - limit))

    items
    |> Enum.with_index()
    |> Enum.drop(first)
    |> Enum.take(limit)
    |> Enum.map(fn {item, position} -> Map.put(item, :selected?, position == selected) end)
  end

  def visible(_, _), do: []

  def move(state, direction) when direction in [:next, :previous, :first, :last] do
    items = entries(state)

    if items == [] do
      state
    else
      next =
        case direction do
          :first -> 0
          :last -> length(items) - 1
          :next -> Integer.mod(index(state) + 1, length(items))
          :previous -> Integer.mod(index(state) - 1, length(items))
        end

      %{state | slash_palette: %{context: context(state), index: next}}
    end
  end

  @doc "Replace only the current matching draft, as one undoable editor replacement."
  def complete(state, name) do
    with true <- valid_name?(name),
         {key, _} <- context(state),
         true <- Enum.any?(entries(state), &(&1.name == name)),
         draft <- Drafts.fetch(state.drafts, key),
         true <- byte_size("/" <> name <> " ") <= draft.editor.max_bytes do
      {selected, effects} = Editing.apply(state, :editor, key, :select_all)
      {completed, edits} = Editing.apply(selected, :editor, key, {:paste, "/" <> name <> " "})
      {%{completed | slash_palette: nil}, effects ++ edits}
    else
      _ -> {state, []}
    end
  end

  defp index(state) do
    case state.slash_palette do
      %{context: saved, index: index} when is_integer(index) and index >= 0 ->
        if saved == context(state), do: min(index, max(0, length(entries(state)) - 1)), else: 0

      _ ->
        0
    end
  end

  defp context(%{focus: "composer", layers: []} = state) do
    with key when not is_nil(key) <- State.current_draft_key(state),
         draft <- Drafts.fetch(state.drafts, key),
         text <- Editor.text(draft.editor),
         true <- byte_size(text) <= 257 and Regex.match?(~r/^\/[A-Za-z0-9_.-]*\z/, text),
         true <- Editor.cursor(draft.editor) == String.length(text),
         nil <- Editor.selection(draft.editor) do
      {key, text}
    else
      _ -> nil
    end
  end

  defp context(_), do: nil
end
