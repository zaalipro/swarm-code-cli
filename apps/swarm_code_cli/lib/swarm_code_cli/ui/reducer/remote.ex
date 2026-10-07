defmodule SwarmCodeCLI.UI.Reducer.Remote do
  @moduledoc """
  cli020 lane D: the one seam through which D's new keys reach lane C's new
  daemon operations (§8.2): `shell.run`, `shell.stop`, `queue.edit`,
  `rewind.turns`, `rewind.apply`, `attachment.slot`, `attachment.attach_slot`,
  `history.search`. Each request is scoped to the conversation in view
  (`state.watches[:workspace]`), carries the origin `{:conversation,
  action}` (C's `Intent.conversation_action/1`) and expects an outcome; its
  answer comes back through `response/3`.

  A request the client's `Request.validate/1` refuses (the op is not in
  this build's `UI.Intent`/`Request` yet) is never sent: the notice says so
  and nothing is lost. Lane C adds the intents, the queries and their
  answers; until then this module is the stub listed in the lane notes.
  """

  alias SwarmCodeCLI.UI.DataSource.Request
  alias SwarmCodeCLI.UI.State

  @unavailable "This ncode daemon cannot do that yet."

  @doc "The words shown when the op is not in this build yet."
  def unavailable_words, do: @unavailable

  @doc "The conversation in view, or nil."
  @spec conversation(map()) :: binary() | nil
  def conversation(state) do
    case State.current_draft_key(state) do
      {conversation, _} when is_binary(conversation) -> conversation
      _ -> nil
    end
  end

  @doc """
  Sends `kind` (an intent or a query tuple) for the conversation in view as
  a `{:command, request}` with origin `{:conversation, action}`. Returns the
  state with the request recorded and the effects, or the notice.
  """
  @spec send(map(), tuple(), atom()) :: {map(), list()}
  def send(state, kind, action) do
    watch = Map.get(state.watches, :workspace)

    with %{status: :ready, scope: %{kind: :conversation} = scope, generation: generation} <-
           watch,
         {id, next} = State.next_id(state, :request),
         {:ok, request} <-
           Request.validate(%Request{
             request_id: id,
             kind: kind,
             scope: scope,
             generation: generation,
             origin: {:conversation, action},
             deadline: state.now + state.deadline_ms,
             expected_response: :outcome
           }) do
      {%{next | requests: Map.put(next.requests, id, request)}, [{:command, request}]}
    else
      {:error, :invalid_request} -> {notice(state, @unavailable), []}
      _ -> {notice(state, "The session is not connected yet."), []}
    end
  end

  @doc "Whether `request` is one this module sent."
  def mine?(%{origin: {:conversation, action}})
      when action in [:shell, :rewind, :attachment, :history],
      do: true

  def mine?(_request), do: false

  @doc """
  An answer to a request this module sent: an outcome (`settle/3`) or a
  query body. The request is already out of `state.requests`. Each op's
  feature module takes its payload; a refusal shows the service's words.
  """
  @spec answer(map(), map(), {:ok, term()} | {:error, binary() | nil}) :: {map(), list()}
  def answer(state, %{kind: kind} = request, result) do
    case {elem(kind, 0), result} do
      {_, {:error, words}} ->
        {notice(state, words || refused_words(kind)), []}

      {:attachment_slot, {:ok, payload}} ->
        SwarmCodeCLI.UI.Reducer.ImagePaste.slot_answer(state, request, payload)

      _ ->
        {state, []}
    end
  end

  @doc "The answer's payload from an outcome (lane C's shape; §8.2)."
  @spec outcome_payload(map()) :: {:ok, term()} | {:error, binary() | nil}
  def outcome_payload(%{status: :accepted} = outcome) do
    cond do
      Map.get(outcome, :result) != nil -> {:ok, outcome.result}
      match?(%{rows: [_ | _]}, outcome.feedback) -> {:ok, outcome.feedback.rows}
      true -> {:ok, outcome}
    end
  end

  def outcome_payload(outcome), do: {:error, refusal(outcome)}

  defp refusal(%{reason: %{text: text}}) when is_binary(text) and text != "",
    do: String.trim(text)

  defp refusal(_outcome), do: nil

  defp refused_words({:shell_run, _, _}), do: "The command did not start."
  defp refused_words({:shell_stop, _}), do: "The command could not be stopped."
  defp refused_words({:attachment_slot, _}), do: "The image could not be attached."
  defp refused_words({:attach_slot, _, _}), do: "The image could not be attached."
  defp refused_words({:rewind_turns, _}), do: "The turns could not be listed."
  defp refused_words({:rewind_apply, _, _, _}), do: "Nothing was rewound."
  defp refused_words({:history_search, _}), do: "History search failed."
  defp refused_words(_kind), do: "The command was refused."

  @doc "A map field by atom or string key."
  def field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  def field(_map, _key), do: nil

  defp notice(state, words), do: %{state | notice: {:command_feedback, words}}
end
