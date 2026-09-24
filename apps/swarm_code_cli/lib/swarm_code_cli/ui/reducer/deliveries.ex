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
          said?: false,
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
    runs = state.read_model.runs

    # pass73 S: the daemon names the disposition (`Outcome.disposition`,
    # read with `Map.get` until S is merged); its words are the fallback.
    case Map.get(outcome, :disposition) do
      :steered -> %{delivery | status: :steered, run_id: steered_run(delivery, ids, runs)}
      :queued -> %{delivery | status: :queued}
      :started -> %{delivery | status: :started, run_id: started_run(ids, runs)}
      _ -> settle_by_words(delivery, ids, outcome.feedback, runs)
    end
  end

  defp settle(delivery, outcome, _state) do
    case refusal_text(Map.get(outcome, :reason)) do
      nil -> %{delivery | status: :refused, reason: reason(outcome), said?: false}
      text -> %{delivery | status: :refused, reason: text, said?: true}
    end
  end

  defp settle_by_words(delivery, ids, feedback, runs) do
    cond do
      said?(feedback, ["queue"], ["queued"]) ->
        %{delivery | status: :queued}

      said?(feedback, ["steer"], ["steered", "sent to the running"]) ->
        %{delivery | status: :steered, run_id: steered_run(delivery, ids, runs)}

      delivery.turn_id != nil and delivery.turn_id in ids ->
        %{delivery | status: :steered, run_id: delivery.turn_id}

      true ->
        %{delivery | status: :started, run_id: started_run(ids, runs)}
    end
  end

  defp started_run(ids, runs), do: Enum.find(ids, &Map.has_key?(runs, &1)) || List.first(ids)

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

  # pass73 S: a refusal carries the service's own sentence
  # (`Outcome.reason`, a `%Refusal{code, text}`), written for people.
  defp refusal_text(%{text: text}) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp refusal_text(_reason), do: nil

  # Without one, the words for the outcome's status or admission code (its
  # message is a fixed diagnostic, never shown).
  defp reason(%{status: status}) when status in [:deadline_exceeded, :outcome_unknown],
    do: "the daemon did not answer in time"

  defp reason(%{status: :revision_conflict}), do: "the conversation changed meanwhile"
  defp reason(%{status: :interrupted}), do: "the session was interrupted"
  defp reason(%{error: %AdmissionError{code: code}}), do: admission_words(code)
  defp reason(_outcome), do: "the daemon did not take it"

  defp admission_words(:capacity_exceeded), do: "the daemon is busy"
  defp admission_words(:deadline_expired), do: "the daemon did not answer in time"
  defp admission_words(:source_unavailable), do: "the daemon connection is down"
  defp admission_words(:closed), do: "the daemon connection is closed"
  defp admission_words(:stale_revision), do: "the conversation changed meanwhile"
  defp admission_words(:not_allowed), do: "it is not allowed right now"
  defp admission_words(_code), do: "the daemon did not take it"

  # The service's sentence stands alone; the fallback words say what to do.
  defp refusal_words(%{reason: reason, said?: true}), do: safe(reason)

  defp refusal_words(%{reason: reason}),
    do: safe("Not sent: #{reason}. Your draft is kept; Enter tries again.")

  defp safe(text) do
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
