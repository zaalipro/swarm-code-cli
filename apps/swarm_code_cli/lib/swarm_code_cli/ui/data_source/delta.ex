defmodule SwarmCodeCLI.UI.DataSource.Delta do
  @moduledoc "Closed, ordered presentation facts, independent of a client watch."
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias DTO.Schema

  @bodies %{
    node_upsert: DTO.TranscriptItem,
    run_update: DTO.RunSummary,
    agent_update: DTO.AgentSummary,
    interaction_upsert: DTO.PendingInteraction,
    activity_upsert: DTO.ActivityItem,
    workspace_metadata: DTO.WorkspaceMetadata,
    counts_update: DTO.Counts,
    connection: DTO.Connection,
    change_upsert: DTO.Change,
    verdict_upsert: DTO.Verdict,
    # pass70 C1: `toast` and `rate_limit` reach the shell watch only;
    # `background_upsert`/`background_remove` travel with the run.
    toast: DTO.Toast,
    rate_limit: DTO.RateLimit,
    background_upsert: DTO.BackgroundCommand
  }
  @kinds Map.keys(@bodies) ++
           [
             :transcript_remove,
             :stream_append,
             :stream_reset,
             :interaction_remove,
             :activity_remove,
             :change_remove,
             :background_remove,
             :snapshot_required
           ]

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
          | :workspace_metadata
          | :counts_update
          | :connection
          | :change_upsert
          | :change_remove
          | :verdict_upsert
          | :toast
          | :rate_limit
          | :background_upsert
          | :background_remove
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
            | DTO.WorkspaceMetadata.t()
            | DTO.Change.t()
            | DTO.Verdict.t()
            | DTO.Toast.t()
            | DTO.RateLimit.t()
            | DTO.BackgroundCommand.t()
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

  @doc "Decode fixed wire fields and select a nested DTO only from the closed delta kind."
  def decode(wire) when is_map(wire) and not is_struct(wire) do
    kind = Enum.find(@kinds, &(Atom.to_string(&1) == wire["kind"]))

    body_type =
      case Map.get(@bodies, kind) do
        nil -> {:optional, {:enum, []}}
        module -> {:dto, module}
      end

    Schema.decode(
      __MODULE__,
      [
        kind: {:enum, @kinds},
        entity_id: {:optional, :id},
        run_id: {:optional, :id},
        conversation_id: {:optional, :id},
        channel: {:optional, {:enum, [:text, :reasoning]}},
        attempt_id: {:optional, :id},
        text: {:optional, :text},
        body: body_type,
        sequence: :revision,
        revision: :revision
      ],
      wire
    )
  end

  def decode(_), do: {:error, :invalid_delta}

  defp correlated_body?(%{body: %DTO.RunSummary{} = body} = delta),
    do:
      delta.entity_id == body.id and delta.run_id == body.id and
        delta.conversation_id == body.conversation_id and is_nil(delta.attempt_id)

  # An agent belongs to a run. The envelope may carry that run's conversation
  # so a conversation-scoped watch can route it (the daemon stamps every
  # delta), or leave it out (the fake source does); the body never has one.
  defp correlated_body?(%{body: %DTO.AgentSummary{} = body} = delta),
    do: delta.entity_id == body.id and delta.run_id == body.run_id and is_nil(delta.attempt_id)

  # Changes and verdicts belong to a run; the envelope carries the run's
  # conversation so conversation-scoped watches can route them.
  defp correlated_body?(%{body: %{__struct__: module} = body} = delta)
       when module in [DTO.Change, DTO.Verdict, DTO.BackgroundCommand],
       do: delta.entity_id == body.id and delta.run_id == body.run_id and is_nil(delta.attempt_id)

  # A toast may be about another conversation than the watch's (a run waiting
  # elsewhere); the envelope routes, the body says what it is about.
  defp correlated_body?(%{body: %DTO.Toast{} = body} = delta),
    do: delta.entity_id == body.id and is_nil(delta.attempt_id)

  defp correlated_body?(%{body: %DTO.RateLimit{} = body} = delta),
    do: delta.entity_id == body.provider_id and is_nil(delta.run_id) and is_nil(delta.attempt_id)

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

  defp correlated_body?(%{kind: kind} = delta) when kind in [:change_remove, :background_remove],
    do: Schema.valid?(:id, delta.run_id) and is_nil(delta.attempt_id)

  defp correlated_body?(%{kind: :workspace_metadata, body: body} = delta),
    do:
      delta.conversation_id == body.conversation_id and is_nil(delta.entity_id) and
        is_nil(delta.run_id) and is_nil(delta.attempt_id)

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
       when kind in [
              :transcript_remove,
              :interaction_remove,
              :activity_remove,
              :change_remove,
              :background_remove
            ],
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
        :workspace_metadata -> DTO.WorkspaceMetadata
        :change_upsert -> DTO.Change
        :verdict_upsert -> DTO.Verdict
        :toast -> DTO.Toast
        :rate_limit -> DTO.RateLimit
        :background_upsert -> DTO.BackgroundCommand
        _ -> nil
      end

    module != nil and Schema.valid?({:dto, module}, body)
  end

  defp valid_body?(_), do: false
end
