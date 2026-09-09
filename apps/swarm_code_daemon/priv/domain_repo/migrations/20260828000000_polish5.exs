defmodule SwarmCode.Domain.Repo.Migrations.Polish5 do
  use Ecto.Migration

  def change do
    # Unread dots (spec 08 §9) and the scheduled-task badge (§8).
    alter table(:conversations) do
      add :last_seen_at, :utc_datetime_usec

      add :scheduled_task_id,
          references(:scheduled_tasks, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:conversations, [:scheduled_task_id])

    # Collapsible sidebar sections (§22/§26), the Agents density (§12) and the
    # default model of a scheduled task (§7/§21).
    alter table(:settings) do
      add :sidebar_sections, :map, default: "{}"
      add :sidebar_show_global_tasks, :boolean, default: true
      add :agents_density, :string, default: "full"
      add :default_scheduled_provider_id, :binary_id
      add :default_scheduled_model, :string
      add :default_scheduled_effort, :string
    end

    # A model per scheduled task (§7/§21); nil falls back to the settings
    # default and then to the chat default.
    alter table(:scheduled_tasks) do
      add :provider_id, :binary_id
      add :model, :string
      add :effort, :string
    end
  end
end
