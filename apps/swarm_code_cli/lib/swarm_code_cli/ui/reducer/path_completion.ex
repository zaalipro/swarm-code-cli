defmodule SwarmCodeCLI.UI.Reducer.PathCompletion do
  @moduledoc """
  `@path` completion in the composer (pass 70 E5).

  When the caret ends an `@` token (`@` at the start of the draft or after
  whitespace, then no whitespace), the service is asked for the project's
  files matching what follows it: the `files` feature query
  (`{:feature_query, :files, query, nil, 20, 65_536}`, origin
  `{:feature, :files}`), answered with a `LibrarySnapshot` whose items' ids
  and titles are project-relative paths and whose `matches` are the matched
  grapheme indices. One query is in flight at a time; a newer token cancels
  the older query and a stale answer is ignored.

  Tab puts the selected path in place of the token (`@path `, one undoable
  edit), Up and Down move the selection, Esc puts the list aside until the
  token changes. `visible/2` is what the composer draws above itself.

  State (`state.path_completion`): `nil`, or
  `%{key, query, request_id, items, index, dismissed?}`.
  """

  alias SwarmCodeCLI.UI.{Drafts, Editor, State}
  alias SwarmCodeCLI.UI.Reducer.Editing
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  @page 20
  @bytes 65_536
  @max_query_bytes 256
  # Only the end of the text before the caret can hold the token.
  @window 300

  @doc "The `@` token the caret ends in the composer: `{draft key, query}`, or nil."
  @spec context(map()) :: {tuple(), binary()} | nil
  def context(%{focus: "composer", layers: []} = state) do
    with key when not is_nil(key) <- State.current_draft_key(state),
         draft = Drafts.fetch(state.drafts, key),
         nil <- Editor.selection(draft.editor),
         cursor = Editor.cursor(draft.editor),
         from = max(cursor - @window, 0),
         before = String.slice(Editor.text(draft.editor), from, cursor - from),
         [_, query] <- Regex.run(~r/(?:^|\s)@([^\s@]*)\z/u, before),
         true <- from == 0 or not String.starts_with?(before, "@" <> query),
         true <- byte_size(query) <= @max_query_bytes do
      {key, query}
    else
      _ -> nil
    end
  end

  def context(_), do: nil

  @doc "True while the list is showing: its token is the caret's and it has rows."
  @spec open?(map()) :: boolean()
  def open?(%{path_completion: %{items: [_ | _], dismissed?: false} = completion} = state),
    do: context(state) == {completion.key, completion.query}

  def open?(_), do: false

  @doc "The selected path, or nil."
  def selected(state) do
    if open?(state),
      do: Enum.at(state.path_completion.items, state.path_completion.index),
      else: nil
  end

  @doc """
  At most `limit` rows around the selection, each the item with
  `selected?: true | false`. A draw asks for as many as it has room for.
  """
  def visible(state, limit) when is_integer(limit) and limit > 0 do
    if open?(state) do
      %{items: items, index: selected} = state.path_completion
      first = max(0, min(selected, length(items) - limit))

      items
      |> Enum.with_index()
      |> Enum.drop(first)
      |> Enum.take(limit)
      |> Enum.map(fn {item, position} -> Map.put(item, :selected?, position == selected) end)
    else
      []
    end
  end

  def visible(_, _), do: []

  @doc """
  After an edit: ask for the caret's token when it changed, cancel the query
  of a token that is gone. Returns `{state, effects}`.
  """
  def sync(state) do
    current = Map.get(state, :path_completion)

    case context(state) do
      nil ->
        {%{forget(state, current) | path_completion: nil}, cancel(current)}

      {key, query} = token ->
        if current != nil and {current.key, current.query} == token,
          do: {state, []},
          else: request(state, key, query, current)
    end
  end

  defp request(state, key, query, current) do
    watch = state.watches.workspace
    state = forget(state, current)

    if watch.status == :ready and watch.scope != nil do
      {id, state} = State.next_id(state, :path)

      request = %Request{
        request_id: id,
        kind: {:feature_query, :files, if(query == "", do: nil, else: query), nil, @page, @bytes},
        scope: watch.scope,
        generation: watch.generation,
        origin: {:feature, :files},
        deadline: state.now + state.deadline_ms,
        expected_response: :library_snapshot
      }

      # The rows of the previous token stay until the new ones arrive, so the
      # list does not blink on every key.
      items = if current, do: current.items, else: []

      completion = %{
        key: key,
        query: query,
        request_id: id,
        items: items,
        index: 0,
        dismissed?: false
      }

      {%{
         state
         | path_completion: completion,
           requests: Map.put(state.requests, id, request)
       }, cancel(current) ++ [{:query, request}]}
    else
      {%{state | path_completion: nil}, cancel(current)}
    end
  end

  defp cancel(%{request_id: id}) when is_binary(id), do: [{:cancel_request, id}]
  defp cancel(_), do: []

  # A cancelled query is no longer the reducer's to wait for.
  defp forget(state, %{request_id: id}) when is_binary(id),
    do: %{state | requests: Map.delete(state.requests, id)}

  defp forget(state, _), do: state

  @doc "True when `request` is the list's own query."
  def owns?(state, %Request{request_id: id, origin: {:feature, :files}}),
    do: match?(%{request_id: ^id}, Map.get(state, :path_completion))

  def owns?(_, _), do: false

  @doc "The answer to the list's query; any other answer changes nothing."
  def response(state, %Request{request_id: id}, body) do
    state = %{state | requests: Map.delete(state.requests, id)}

    case {state.path_completion, body} do
      {%{request_id: ^id} = completion, %DTO.LibrarySnapshot{feature: :files, state: :idle}} ->
        items = Enum.take(body.items, @page)
        {%{state | path_completion: %{completion | request_id: nil, items: items, index: 0}}, []}

      {%{request_id: ^id} = completion, _} ->
        {%{state | path_completion: %{completion | request_id: nil, items: []}}, []}

      _ ->
        {state, []}
    end
  end

  @doc "Up/Down over the rows, wrapping."
  def move(%{path_completion: %{items: items, index: index} = completion} = state, direction)
      when items != [] do
    next =
      case direction do
        :first -> 0
        :last -> length(items) - 1
        :next -> Integer.mod(index + 1, length(items))
        :previous -> Integer.mod(index - 1, length(items))
      end

    %{state | path_completion: %{completion | index: next}}
  end

  def move(state, _), do: state

  @doc "Esc: the list steps aside until the token changes."
  def dismiss(%{path_completion: %{} = completion} = state) do
    state = forget(state, completion)

    {%{state | path_completion: %{completion | dismissed?: true, request_id: nil}},
     cancel(completion)}
  end

  def dismiss(state), do: {state, []}

  @doc """
  Puts `@<path> ` in place of the caret's token, as one undoable edit. The
  path must be one of the rows.
  """
  def complete(state, path) do
    with true <- open?(state),
         %{key: key, query: query, items: items} <- state.path_completion,
         true <- Enum.any?(items, &(&1.id == path)),
         count when count in 1..999 <- String.length("@" <> query) do
      {selected, a} =
        Editing.apply(state, :editor, key, {:times, count, {:extend_selection, :left}})

      {completed, b} = Editing.apply(selected, :editor, key, {:paste, "@" <> path <> " "})
      completed = forget(completed, state.path_completion)
      {%{completed | path_completion: nil}, cancel(state.path_completion) ++ a ++ b}
    else
      _ -> {state, []}
    end
  end
end
