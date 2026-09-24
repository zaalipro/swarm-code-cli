defmodule SwarmCodeCLI.UI.Reducer.Deliveries do
  @moduledoc """
  pass73 T3/T8: what became of each message sent from a conversation's
  composer, kept in `state.deliveries` (newest first, at most 50) so the
  transcript can mark it and nothing sent is ever silently lost.

  A send is `:sending` until the daemon answers. Then it is:

    * `:steered`: it went to the running chat turn (the daemon says "Steer",
      or the run it names is the chat turn that was live when it was sent);
    * `:queued`: it waits for the running turn (the daemon says "Queue");
    * `:started`: it began run `run_id` (a new turn, a swarm, a workflow…);
    * `:refused`: it was not sent; `reason` says why in words, the draft is
      kept, and the status line says so.

  `text` is what the user typed, trimmed (a "workflow" message without the
  `/create-workflow` it was sent as), so it matches the transcript's user
  message the way `state.steers` does. `turn_id` is the chat turn that was
  live when it was sent (nil when none), `operation` `:send` or `:queue`.
  """

  alias SwarmCodeCLI.UI.{Composer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.AdmissionError

  @limit 50

  @doc "Records the dispatch requests among `effects` as `:sending`."
  def sent(state, effects) do
    Enum.reduce(effects, state, fn
      {:command,
       %{kind: {:dispatch, operation, text, _, _}, origin: {:draft, {conversation, _}}} = request},
      state
      when operation in [:send, :queue] ->
        turn = Composer.chat_turn(state)

        delivery = %{
          id: request.request_id,
          conversation_id: conversation,
          run_id: nil,
          text: shown_text(text),
          status: :sending,
          at: state.now,
          reason: nil,
          turn_id: turn && turn.id,
          operation: operation
        }

        deliveries = [delivery | Enum.reject(state.deliveries, &(&1.id == delivery.id))]
        %{state | deliveries: Enum.take(deliveries, @limit)}

      _effect, state ->
        state
    end)
  end

  @doc "Settles the delivery of `request` with the daemon's `outcome`."
  def settled(state, %{request_id: id, kind: {:dispatch, _, _, _, _}}, outcome) do
    case Enum.find(state.deliveries, &(&1.id == id)) do
      %{status: :sending} = delivery ->
        settled = settle(delivery, outcome, state)

        state = %{
          state
          | deliveries: Enum.map(state.deliveries, &if(&1.id == id, do: settled, else: &1))
        }

        if settled.status == :refused,
          do: %{state | notice: {:command_feedback, refusal_words(settled)}},
          else: state

      _ ->
        state
    end
  end

  def settled(state, _request, _outcome), do: state

  defp settle(delivery, %{status: :accepted} = outcome, state) do
    ids = outcome.identifiers || []
    feedback = outcome.feedback
    runs = state.read_model.runs

    cond do
      said?(feedback, ["queue"], ["queued"]) ->
        %{delivery | status: :queued}

      said?(feedback, ["steer"], ["steered", "sent to the running"]) ->
        %{delivery | status: :steered, run_id: steered_run(delivery, ids, runs)}

      delivery.turn_id != nil and delivery.turn_id in ids ->
        %{delivery | status: :steered, run_id: delivery.turn_id}

      true ->
        %{
          delivery
          | status: :started,
            run_id: Enum.find(ids, &Map.has_key?(runs, &1)) || List.first(ids)
        }
    end
  end

  defp settle(delivery, outcome, _state),
    do: %{delivery | status: :refused, reason: reason(outcome)}

  defp steered_run(delivery, ids, runs) do
    cond do
      delivery.turn_id in ids -> delivery.turn_id
      run = Enum.find(ids, &Map.has_key?(runs, &1)) -> run
      true -> delivery.turn_id
    end
  end

  defp said?(%{title: title, text: text}, titles, openings) do
    title = String.downcase(String.trim(title || ""))
    text = String.downcase(String.trim(text || ""))
    title in titles or Enum.any?(openings, &String.starts_with?(text, &1))
  end

  defp said?(_feedback, _titles, _openings), do: false

  # The words for the outcome's status or admission code.
  defp reason(%{status: status}) when status in [:deadline_exceeded, :outcome_unknown],
    do: "the daemon did not answer in time"

  defp reason(%{status: :revision_conflict}), do: "the conversation changed meanwhile"
  defp reason(%{status: :interrupted}), do: "the session was interrupted"
  defp reason(%{error: %AdmissionError{} = error}), do: admission_words(error)
  defp reason(_outcome), do: "the daemon did not take it"

  defp admission_words(%AdmissionError{code: code, message: message}) do
    case code do
      :capacity_exceeded -> "the daemon is busy"
      :deadline_expired -> "the daemon did not answer in time"
      :source_unavailable -> "the daemon connection is down"
      :closed -> "the daemon connection is closed"
      :stale_revision -> "the conversation changed meanwhile"
      :not_allowed -> sentence(code, message) || "it is not allowed right now"
      _ -> sentence(code, message) || "the daemon did not take it"
    end
  end

  # A reason the daemon wrote for people, not the code's fixed diagnostic.
  defp sentence(code, message) when is_binary(message) do
    fixed =
      try do
        AdmissionError.new(code).message
      rescue
        _ -> nil
      end

    case String.trim(message) do
      "" -> nil
      ^fixed -> nil
      text -> String.trim_trailing(text, ".")
    end
  end

  defp sentence(_code, _message), do: nil

  defp refusal_words(%{reason: reason}) do
    text = "Not sent: #{reason}. Your draft is kept; Enter tries again."
    {:ok, safe} = SafeText.external(text, SafeText.Limits.content())
    SafeText.value(safe)
  end

  defp shown_text(text) do
    trimmed = String.trim(text)

    case trimmed do
      "/create-workflow " <> rest -> String.trim(rest)
      _ -> trimmed
    end
  end
end
