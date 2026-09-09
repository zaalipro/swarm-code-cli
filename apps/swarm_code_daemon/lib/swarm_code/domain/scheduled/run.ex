defmodule SwarmCode.Domain.Scheduled.Run do
  @moduledoc "One occurrence of a scheduled task that the scheduler actually fired."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Sakana task 8: a scheduled workflow that pauses or asks the user is not
  # running any more, but it is not finished either — the row mirrors the
  # engine run instead of claiming "running" for ever.
  @statuses ~w(claimed running paused waiting_user done failed skipped)

  schema "scheduled_runs" do
    field(:run_id, :binary_id)
    field(:scheduled_for, :utc_datetime)
    field(:started_at, :utc_datetime_usec)
    field(:status, :string, default: "running")

    belongs_to(:task, SwarmCode.Domain.Scheduled.Task)
    belongs_to(:conversation, SwarmCode.Domain.Conversations.Conversation)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @fields ~w(task_id conversation_id run_id scheduled_for started_at status)a

  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:task_id, :scheduled_for, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
