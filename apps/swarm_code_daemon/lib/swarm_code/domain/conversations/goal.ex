defmodule SwarmCode.Domain.Conversations.Goal do
  @moduledoc """
  One goal of a conversation (spec 10 §19).

  A conversation can pursue several goals at once. Each goal remembers the mode
  its runs use (`"chat"` or `"swarm"`, spec 10 §7) and the run that is currently
  (or was last) pursuing it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active paused done cleared)
  @modes ~w(chat swarm)

  def statuses, do: @statuses
  def modes, do: @modes

  schema "goals" do
    field(:text, :string)
    field(:mode, :string, default: "chat")
    field(:status, :string, default: "active")
    field(:run_id, :binary_id)
    field(:inserted_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    belongs_to(:conversation, SwarmCode.Domain.Conversations.Conversation)
  end

  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [:conversation_id, :text, :mode, :status, :run_id, :inserted_at, :finished_at])
    |> validate_required([:conversation_id, :text])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
  end
end
