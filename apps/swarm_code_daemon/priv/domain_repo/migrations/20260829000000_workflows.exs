defmodule SwarmCode.Domain.Repo.Migrations.Workflows do
  use Ecto.Migration

  def change do
    create table(:workflow_runs, primary_key: false) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all)

      add :definition_name, :string
      add :scope, :string
      add :display_name, :string, null: false
      add :source, :text, null: false
      add :args, :map, default: "{}"
      add :budget, :integer, null: false
      add :max_live, :integer, null: false
      add :agents_admitted, :integer, default: 0
      add :phases, {:array, :string}, default: "[]"
      add :phase, :string
      add :pause_kind, :string
      add :pause_message, :text
      add :gate_question, :text
      add :gate_options, {:array, :string}, default: "[]"
      add :result, :text
      add :logs, {:array, :map}, default: "[]"
      add :created_by, :string, default: "user"
      add :auto_continue, :boolean, default: false
      add :launch_message_id, :binary_id

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_runs, [:conversation_id])
    create index(:workflow_runs, [:definition_name])

    create table(:workflow_journal, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :slot, :integer, null: false
      add :fingerprint, :integer, null: false
      add :kind, :string, null: false
      add :result, :text
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:workflow_journal, [:run_id, :seq, :slot])

    alter table(:nodes) do
      add :phase, :string
      add :group, :string
    end

    alter table(:conversations) do
      add :ultra, :boolean, default: false
      add :authoring_workflow, :boolean, default: false
    end

    alter table(:scheduled_tasks) do
      add :workflow_name, :string
      add :workflow_args, :map, default: "{}"
    end

    alter table(:settings) do
      add :workflow_budget, :integer, default: 128
      add :workflow_max_live, :integer, default: 16
      add :default_workflow_provider_id, :binary_id
      add :default_workflow_model, :string
      add :default_workflow_effort, :string
    end
  end
end
