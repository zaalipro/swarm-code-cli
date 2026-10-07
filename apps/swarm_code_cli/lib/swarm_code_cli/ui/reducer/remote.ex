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
  The payload of an answer: the outcome's feedback rows/text or the body a
  query returned; `{:error, words}` for a refusal.
  """
  @spec payload(term()) :: {:ok, term()} | {:error, binary() | nil}
  def payload({:outcome, %{status: :accepted} = outcome}),
    do: {:ok, Map.get(outcome, :result) || outcome}

  def payload({:outcome, outcome}), do: {:error, refusal(outcome)}
  def payload({_tag, body}), do: {:ok, body}
  def payload(body), do: {:ok, body}

  defp refusal(%{reason: %{text: text}}) when is_binary(text) and text != "",
    do: String.trim(text)

  defp refusal(_outcome), do: nil

  defp notice(state, words), do: %{state | notice: {:command_feedback, words}}
end
