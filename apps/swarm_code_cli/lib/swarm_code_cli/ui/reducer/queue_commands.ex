defmodule SwarmCodeCLI.UI.Reducer.QueueCommands do
  @moduledoc """
  cli020 D20: the client-local `/queue` and `/delete`.

  `/queue` alone opens `{:queue_list}` (E draws the workspace's
  `queued_texts`, numbered; `d` on a row drops it); `/queue clear` and
  `/queue drop N` (N in 1..length) send `{:queue_edit, conversation,
  queue_revision, :clear | {:drop, N}}` (C1) with the revision of the
  workspace on screen; anything else after `/queue` is queued as text, as
  before (to queue the word `clear`, type it and press Alt-Enter).

  Bare `/delete` asks first: the notice says how to confirm, and a second
  `/delete` within 5 s sends it to the daemon (E3's `:delete_conversation`).
  """

  alias SwarmCodeCLI.UI.Reducer.Remote
  alias SwarmCodeCLI.UI.State

  @confirm_ms 5_000

  @doc "What `/queue <rest>` means: `:list`, `{:edit, edit}`, `{:bad_drop, words}` or `:text`."
  def parse(rest) do
    case String.split(String.trim(rest)) do
      [] -> :list
      ["clear"] -> {:edit, :clear}
      ["drop", n] -> drop(n)
      _ -> :text
    end
  end

  defp drop(n) do
    case Integer.parse(n) do
      {n, ""} when n > 0 -> {:edit, {:drop, n}}
      _ -> {:bad_drop, "Drop which message? /queue drop N, N from 1."}
    end
  end

  @doc "The queued texts of the workspace on screen."
  def queued(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace -> workspace |> Map.get(:queued_texts) |> List.wrap()
      _ -> []
    end
  end

  defp revision(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace -> Map.get(workspace, :queue_revision)
      _ -> nil
    end
  end

  @doc "Opens the queue list."
  def list(state) do
    cond do
      queued(state) == [] ->
        {%{state | notice: {:command_feedback, "Nothing is queued."}}, []}

      not Remote.drawable?({:queue_list}) ->
        {%{state | notice: {:command_feedback, "The queue list is not drawn in this build yet."}},
         []}

      true ->
        {%{
           state
           | layers: [{:queue_list} | state.layers],
             selection: Map.put(state.selection, "queue_list", 0)
         }, []}
    end
  end

  @doc "Sends `edit` (`:clear` or `{:drop, n}`) for the conversation in view."
  def edit(state, edit) do
    count = length(queued(state))
    conversation = Remote.conversation(state)

    cond do
      conversation == nil ->
        {state, []}

      count == 0 ->
        {%{state | notice: {:command_feedback, "Nothing is queued."}}, []}

      match?({:drop, n} when n > count, edit) ->
        {%{
           state
           | notice:
               {:command_feedback, "The queue has #{count} message(s): /queue drop 1..#{count}."}
         }, []}

      not is_binary(revision(state)) ->
        {%{state | notice: {:command_feedback, "The queue is not loaded yet."}}, []}

      true ->
        Remote.send(state, {:queue_edit, conversation, revision(state), edit}, :queue)
    end
  end

  @doc "↑/↓ in the list."
  def move(%{layers: [{:queue_list} | _]} = state, delta) do
    last = max(length(queued(state)) - 1, 0)
    at = min(max(Map.get(state.selection, "queue_list", 0) + delta, 0), last)
    {%{state | selection: Map.put(state.selection, "queue_list", at)}, []}
  end

  def move(state, _delta), do: {state, []}

  @doc "`d` on a row: drops that message (numbered from 1)."
  def drop_selected(%{layers: [{:queue_list} | _]} = state) do
    last = max(length(queued(state)) - 1, 0)
    edit(state, {:drop, min(Map.get(state.selection, "queue_list", 0), last) + 1})
  end

  def drop_selected(state), do: {state, []}

  # A queued text arrives from the daemon cut at 2 KB; one that long may be
  # cut, and bringing back half a prompt would lose the rest.
  @whole_bytes 2_000

  @doc """
  Enter on a row (fix round U5): the message moves into the composer for
  editing. The daemon removes it from the queue (`queue.edit`, the same op as
  `d`); the text is put in the draft when that is accepted (`answered/3`).
  """
  def take_selected(%{layers: [{:queue_list} | _]} = state) do
    texts = queued(state)
    at = min(Map.get(state.selection, "queue_list", 0), max(length(texts) - 1, 0))

    case Enum.at(texts, at) do
      text when is_binary(text) and byte_size(text) >= @whole_bytes ->
        {%{
           state
           | notice:
               {:command_feedback,
                "That message is too long to edit here: d drops it, or let it run."}
         }, []}

      text when is_binary(text) ->
        before = Map.keys(state.requests)
        {next, effects} = edit(state, {:drop, at + 1})

        case Map.keys(next.requests) -- before do
          [id] -> {%{next | queue_take: %{id: id, text: text}}, effects}
          _ -> {next, effects}
        end

      _ ->
        {state, []}
    end
  end

  def take_selected(state), do: {state, []}

  @doc "A queue edit the daemon refused: a pending take is over."
  def refused(%{queue_take: %{id: id}} = state, %{request_id: id}), do: %{state | queue_take: nil}
  def refused(state, _request), do: state

  @doc "The answer of a queue edit: `{state, effects}`."
  def answered(state, %{request_id: id, kind: {:queue_edit, _, _, {:drop, n}}}) do
    case state.queue_take do
      %{id: ^id, text: text} -> brought_back(%{state | queue_take: nil}, n, text)
      _ -> answered(state, {:queue_edit, nil, nil, {:drop, n}})
    end
  end

  def answered(state, %{kind: kind}), do: answered(state, kind)

  def answered(state, {:queue_edit, _, _, :clear}),
    do: {%{state | notice: {:command_feedback, "Queue cleared."}}, []}

  def answered(state, {:queue_edit, _, _, {:drop, n}}),
    do: {%{state | notice: {:command_feedback, "Dropped message #{n} from the queue."}}, []}

  # The text goes into the draft (one undoable replacement, Ctrl-Z gives the
  # earlier draft back); a draft already typed keeps its place and the text
  # follows on a new line.
  defp brought_back(state, n, text) do
    state = %{state | layers: Enum.reject(state.layers, &match?({:queue_list}, &1))}

    case State.current_draft_key(state) do
      nil ->
        {%{state | notice: {:command_feedback, "Message #{n} left the queue."}}, []}

      key ->
        draft = SwarmCodeCLI.UI.Keymap.draft_text(state)
        joined = if String.trim(draft) == "", do: text, else: draft <> "\n" <> text
        {state, effects} = SwarmCodeCLI.UI.Reducer.replace_text(state, key, joined)

        {%{
           state
           | notice: {:command_feedback, "Message #{n} is in the composer · Enter sends it again"}
         }, effects}
    end
  end

  @doc """
  Bare `/delete`: `{:send, state}` when this is the confirming second one,
  `{:asked, state}` when it only asked.
  """
  def delete(state) do
    if is_integer(state.delete_armed_at) and state.now - state.delete_armed_at <= @confirm_ms do
      {:send, %{state | delete_armed_at: nil}}
    else
      {:asked,
       %{
         state
         | delete_armed_at: state.now,
           notice:
             {:command_feedback,
              "Delete this conversation? Send /delete again within 5 s to confirm."}
       }}
    end
  end
end
