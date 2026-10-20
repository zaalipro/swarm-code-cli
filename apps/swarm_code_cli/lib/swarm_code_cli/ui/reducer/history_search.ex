defmodule SwarmCodeCLI.UI.Reducer.HistorySearch do
  @moduledoc """
  cli020 D19 (competitors-19): Ctrl-R in the composer searches the earlier
  prompts of this project (`history.search`, C20), and the draft stash.

  The layer `{:history_search, %{query, rows, selected}}`: typing edits the
  query, which goes out 150 ms after the last key (the owner's timer,
  `state.history_timer`); only the answer to the newest request is taken
  (`state.history_request`), older ones are dropped. ↑/↓ move, Enter puts the
  prompt into the draft as one undoable edit, Esc closes.

  Stash: one per draft key (`state.stashes`); `{:stash_draft}` puts the draft
  aside, `{:restore_stash}` swaps the stash and the draft. A stash holds the
  draft's *expanded* text (C-BUG-13): a collapsed paste's payload lives in the
  draft, which a send clears, so the placeholder alone would be lost. A draft
  over the 256 KiB message bound is refused with a notice and nothing changes.
  """

  alias SwarmCodeCLI.UI.{Drafts, Editor, State}
  alias SwarmCodeCLI.UI.Draft.Pastes
  alias SwarmCodeCLI.UI.Reducer.Remote

  @debounce_ms 150
  @max_query 256

  @doc "Ctrl-R in the composer."
  def open(state) do
    layer = {:history_search, %{query: "", rows: [], selected: 0}}

    if Remote.drawable?(layer) do
      fire(%{state | layers: [layer | state.layers]})
    else
      {%{state | notice: {:command_feedback, "History search is not drawn in this build yet."}},
       []}
    end
  end

  @doc "A key edited the query: `{:append, text}` or `:backspace`."
  def edit(%{layers: [{:history_search, layer} | rest]} = state, operation) do
    query =
      case operation do
        {:append, text} -> String.slice(layer.query <> text, 0, @max_query)
        :backspace -> String.slice(layer.query, 0, max(String.length(layer.query) - 1, 0))
      end

    state = %{state | layers: [{:history_search, %{layer | query: query}} | rest]}
    {id, state} = State.next_id(state, :timer)
    cancel = if state.history_timer, do: [{:cancel_timer, state.history_timer}], else: []

    {%{state | history_timer: id},
     cancel ++ [{:start_timer, id, @debounce_ms, {:timer_fired, id}}]}
  end

  def edit(state, _operation), do: {state, []}

  @doc "The debounce ended: the query goes out."
  def fire(%{layers: [{:history_search, layer} | _]} = state) do
    state = %{state | history_timer: nil}
    before = Map.keys(state.requests)

    {next, effects} =
      Remote.send(
        state,
        {:history_search, Remote.conversation(state), layer.query},
        :history
      )

    case Map.keys(next.requests) -- before do
      [id] -> {%{next | history_request: id}, effects}
      _ -> {next, effects}
    end
  end

  def fire(state), do: {%{state | history_timer: nil}, []}

  @doc "An answer: taken only when it is the newest request's."
  def answer(
        %{layers: [{:history_search, layer} | rest], history_request: id} = state,
        %{request_id: id},
        payload
      ) do
    rows =
      payload
      |> List.wrap()
      |> Enum.flat_map(fn row ->
        case Remote.field(row, :text) do
          text when is_binary(text) and text != "" ->
            [
              %{
                text: text,
                conversation_id: Remote.field(row, :conversation_id),
                at: Remote.field(row, :at)
              }
            ]

          _ ->
            []
        end
      end)
      |> Enum.take(50)

    {%{
       state
       | history_request: nil,
         layers: [{:history_search, %{layer | rows: rows, selected: 0}} | rest]
     }, []}
  end

  def answer(state, _request, _payload), do: {state, []}

  @doc "↑/↓."
  def move(%{layers: [{:history_search, layer} | rest]} = state, delta) do
    at = min(max(layer.selected + delta, 0), max(length(layer.rows) - 1, 0))
    {%{state | layers: [{:history_search, %{layer | selected: at}} | rest]}, []}
  end

  def move(state, _delta), do: {state, []}

  @doc "Enter: the prompt under the cursor becomes the draft (undoable)."
  def pick(%{layers: [{:history_search, layer} | rest]} = state) do
    case {Enum.at(layer.rows, layer.selected), State.current_draft_key(%{state | layers: rest})} do
      {%{text: text}, key} when key != nil ->
        state = %{state | layers: rest, history_request: nil}
        SwarmCodeCLI.UI.Reducer.replace_text(state, key, text)

      _ ->
        {state, []}
    end
  end

  def pick(state), do: {state, []}

  @too_large_words "The draft is too large to stash (over 256 KiB)."

  @doc "Puts the draft aside (one stash per draft key)."
  def stash(state) do
    key = State.current_draft_key(state)

    cond do
      key == nil ->
        {state, []}

      String.trim(SwarmCodeCLI.UI.Keymap.draft_text(state)) == "" ->
        {%{state | notice: {:command_feedback, "Nothing to stash."}}, []}

      true ->
        case expanded_text(state, key) do
          {:ok, expanded} ->
            {state, effects} = SwarmCodeCLI.UI.Reducer.replace_text(state, key, "")

            {%{
               state
               | stashes: Map.put(state.stashes, key, expanded),
                 notice: {:command_feedback, "Draft stashed · Ctrl-P Restore stash"}
             }, effects}

          {:error, :too_large} ->
            {%{state | notice: {:command_feedback, @too_large_words}}, []}
        end
    end
  end

  @doc "Swaps the stash and the draft."
  def restore(state) do
    key = State.current_draft_key(state)

    case key && Map.fetch(state.stashes, key) do
      {:ok, stashed} ->
        swap(state, key, stashed)

      _ ->
        {%{state | notice: {:command_feedback, "No stash to restore."}}, []}
    end
  end

  defp swap(state, key, stashed) do
    blank? = String.trim(SwarmCodeCLI.UI.Keymap.draft_text(state)) == ""

    with {:ok, stashes} <- stashes_after_swap(state, key, blank?) do
      {state, effects} = SwarmCodeCLI.UI.Reducer.replace_text(state, key, stashed)
      {%{state | stashes: stashes, notice: {:command_feedback, "Stash restored"}}, effects}
    else
      {:error, :too_large} -> {%{state | notice: {:command_feedback, @too_large_words}}, []}
    end
  end

  # The current draft takes the stash's place, as its expanded text.
  defp stashes_after_swap(state, key, true), do: {:ok, Map.delete(state.stashes, key)}

  defp stashes_after_swap(state, key, false) do
    with {:ok, expanded} <- expanded_text(state, key),
         do: {:ok, Map.put(state.stashes, key, expanded)}
  end

  defp expanded_text(state, key) do
    draft = Drafts.fetch(state.drafts, key)
    Pastes.expand(Editor.text(draft.editor), draft.pastes)
  end
end
