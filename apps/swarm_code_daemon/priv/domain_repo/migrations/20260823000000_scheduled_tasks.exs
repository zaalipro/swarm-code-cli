defmodule SwarmCode.Domain.Repo.Migrations.ScheduledTasks do
  use Ecto.Migration

  def change do
    create table(:scheduled_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :prompt, :text, null: false
      add :kind, :string, null: false, default: "chat"

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :mode, :string, null: false, default: "build"
      add :schedule_kind, :string, null: false, default: "daily"
      add :run_at, :utc_datetime
      add :time_of_day, :string
      add :weekdays, {:array, :integer}, default: []
      add :day_of_month, :integer
      add :cron, :string
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :color, :string, null: false, default: "orange"
      add :enabled, :boolean, null: false, default: true
      add :catch_up, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime
      add :next_run_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_tasks, [:project_id])
    create index(:scheduled_tasks, [:next_run_at])

    create table(:scheduled_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :task_id,
          references(:scheduled_tasks, type: :binary_id, on_delete: :delete_all),
          null: false

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :run_id, :binary_id
      add :scheduled_for, :utc_datetime, null: false
      add :started_at, :utc_datetime_usec
      add :status, :string, null: false, default: "running"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_runs, [:task_id])
    create index(:scheduled_runs, [:scheduled_for])
  end
end
