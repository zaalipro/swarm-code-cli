defmodule SwarmCodeCLI.UI.DataSource.Delta do
  @moduledoc "Closed, ordered canonical fake facts, independent of a client watch."
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias DTO.Schema

  defstruct [
    :kind,
    :entity_id,
    :run_id,
    :conversation_id,
    :channel,
    :attempt_id,
    :text,
    :body,
    sequence: 0,
    revision: 0
  ]

  @type kind ::
          :node_upsert
          | :transcript_remove
          | :stream_append
          | :stream_reset
          | :run_update
          | :agent_update
          | :interaction_upsert
          | :interaction_remove
          | :activity_upsert
          | :activity_remove
          | :counts_update
          | :connection
          | :snapshot_required
  @type t :: %__MODULE__{
          kind: kind(),
          entity_id: binary() | nil,
          run_id: binary() | nil,
          conversation_id: binary() | nil,
          channel: :text | :reasoning | nil,
          attempt_id: binary() | nil,
          text: binary() | nil,
          body:
            DTO.TranscriptItem.t()
            | DTO.RunSummary.t()
            | DTO.AgentSummary.t()
            | DTO.PendingInteraction.t()
            | DTO.ActivityItem.t()
            | DTO.Counts.t()
            | DTO.Connection.t()
            | nil,
          sequence: non_neg_integer(),
          revision: non_neg_integer()
        }
  def validate(%__MODULE__{} = delta) do
    valid =
      map_size(delta) == 11 and Enum.all?(Map.keys(%__MODULE__{}), &Map.has_key?(delta, &1)) and
        Schema.valid?(:revision, delta.sequence) and
        Schema.valid?(:revision, delta.revision) and
        Enum.all?(
          [delta.entity_id, delta.run_id, delta.conversation_id, delta.attempt_id],
          &Schema.valid?({:optional, :id}, &1)
        ) and valid_body?(delta) and correlated_body?(delta)

    if valid, do: {:ok, delta}, else: {:error, :invalid_delta}
  end

  def validate(_), do: {:error, :invalid_delta}

  defp correlated_body?(%{body: %DTO.RunSummary{} = body} = delta),
    do:
      delta.entity_id == body.id and delta.run_id == body.id and
        delta.conversation_id == body.conversation_id and is_nil(delta.attempt_id)

  defp correlated_body?(%{body: %DTO.AgentSummary{} = body} = delta),
    do:
      delta.entity_id == body.id and delta.run_id == body.run_id and is_nil(delta.conversation_id) and
        is_nil(delta.attempt_id)

  defp correlated_body?(
         %{body: %{id: id, run_id: run_id, conversation_id: conversation_id}} = delta
       ),
       do:
         delta.entity_id == id and delta.run_id == run_id and
           delta.conversation_id == conversation_id and is_nil(delta.attempt_id)

  defp correlated_body?(%{kind: kind} = delta)
       when kind in [:counts_update, :connection, :snapshot_required],
       do:
         is_nil(delta.entity_id) and is_nil(delta.run_id) and is_nil(delta.conversation_id) and
           is_nil(delta.attempt_id)

  defp correlated_body?(%{kind: kind} = delta)
       when kind in [:transcript_remove, :interaction_remove, :activity_remove],
       do:
         Schema.valid?(:id, delta.run_id) and Schema.valid?(:id, delta.conversation_id) and
           is_nil(delta.attempt_id)

  defp correlated_body?(%{kind: kind} = delta) when kind in [:stream_append, :stream_reset],
    do: Schema.valid?(:id, delta.run_id) and Schema.valid?(:id, delta.conversation_id)

  defp correlated_body?(_), do: false

  defp valid_body?(%{
         kind: kind,
         channel: channel,
         attempt_id: attempt,
         text: text,
         body: nil,
         entity_id: id
       })
       when kind in [:stream_append, :stream_reset],
       do:
         channel in [:text, :reasoning] and Schema.valid?(:id, attempt) and Schema.valid?(:id, id) and
           Schema.valid?(:text, text)

  defp valid_body?(%{kind: kind, body: nil, entity_id: id, channel: nil, text: nil})
       when kind in [:transcript_remove, :interaction_remove, :activity_remove],
       do: Schema.valid?(:id, id)

  defp valid_body?(%{kind: :snapshot_required, body: nil, channel: nil, text: nil}), do: true

  defp valid_body?(%{kind: kind, body: body, channel: nil, text: nil}) do
    module =
      case kind do
        :node_upsert -> DTO.TranscriptItem
        :run_update -> DTO.RunSummary
        :agent_update -> DTO.AgentSummary
        :interaction_upsert -> DTO.PendingInteraction
        :activity_upsert -> DTO.ActivityItem
        :counts_update -> DTO.Counts
        :connection -> DTO.Connection
        _ -> nil
      end

    module != nil and Schema.valid?({:dto, module}, body)
  end

  defp valid_body?(_), do: false
end
