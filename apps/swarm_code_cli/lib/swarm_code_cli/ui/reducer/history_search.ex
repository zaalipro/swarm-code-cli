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
  aside, `{:restore_stash}` swaps the stash and the draft.
  """

  alias SwarmCodeCLI.UI.{LayerSpec, State}
  alias SwarmCodeCLI.UI.Reducer.Remote

  @debounce_ms 150
  @max_query 256

  @doc "Ctrl-R in the composer."
  def open(state) do
    layer = {:history_search, %{query: "", rows: [], selected: 0}}

    if match?({:ok, _}, LayerSpec.validate(layer)) do
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
    {next, effects} = Remote.send(state, {:history_search, layer.query}, :history)

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

  @doc "Puts the draft aside (one stash per draft key)."
  def stash(state) do
    key = State.current_draft_key(state)
    text = SwarmCodeCLI.UI.Keymap.draft_text(state)

    cond do
      key == nil ->
        {state, []}

      String.trim(text) == "" ->
        {%{state | notice: {:command_feedback, "Nothing to stash."}}, []}

      true ->
        {state, effects} = SwarmCodeCLI.UI.Reducer.replace_text(state, key, "")

        {%{
           state
           | stashes: Map.put(state.stashes, key, text),
             notice: {:command_feedback, "Draft stashed · Ctrl-P Restore stash"}
         }, effects}
    end
  end

  @doc "Swaps the stash and the draft."
  def restore(state) do
    key = State.current_draft_key(state)

    case key && Map.fetch(state.stashes, key) do
      {:ok, stashed} ->
        current = SwarmCodeCLI.UI.Keymap.draft_text(state)

        stashes =
          if String.trim(current) == "",
            do: Map.delete(state.stashes, key),
            else: Map.put(state.stashes, key, current)

        {state, effects} = SwarmCodeCLI.UI.Reducer.replace_text(state, key, stashed)

        {%{state | stashes: stashes, notice: {:command_feedback, "Stash restored"}}, effects}

      _ ->
        {%{state | notice: {:command_feedback, "No stash to restore."}}, []}
    end
  end
end
