defmodule SwarmCode.Domain.Conversations.Message do
  @moduledoc """
  One transcript entry of a conversation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "messages" do
    field(:role, :string)
    field(:content, :string, default: "")
    field(:reasoning, :string)
    field(:run_id, :binary_id)
    field(:tokens_in, :integer, default: 0)
    field(:tokens_out, :integer, default: 0)
    field(:cost_usd, :float)
    field(:position, :integer, default: 0)
    field(:attachments, {:array, :map}, default: [])
    # Pass 12 §3: the run this message answers or steers.
    field(:reply_to_run_id, :binary_id)
    # Spec 25 §3.3: the deep researches this turn carried into the model's
    # context. The message's own text never contains the report.
    field(:research_ids, {:array, :integer}, default: [])
    # Spec 52 §1.1: the user edited and resent this turn. The row stays in the
    # transcript (folded and dimmed); the model never reads it again.
    field(:superseded_at, :utc_datetime_usec)

    belongs_to(:conversation, SwarmCode.Domain.Conversations.Conversation)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(conversation_id role content reasoning run_id tokens_in tokens_out cost_usd position
             attachments reply_to_run_id research_ids superseded_at)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields)
    |> validate_required([:conversation_id, :role])
    # Spec 50 §1.2: `compact` is a summary of everything before it, written by
    # a `/compact` run. `Conversations.list_history_window/2` starts there.
    |> validate_inclusion(:role, ["user", "assistant", "swarm", "error", "workflow", "compact"])
    |> unique_constraint(:position, name: :messages_conversation_id_position_index)
  end
end
