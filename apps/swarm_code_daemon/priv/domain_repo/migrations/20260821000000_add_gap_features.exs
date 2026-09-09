defmodule SwarmCode.Domain.Repo.Migrations.AddGapFeatures do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :workspace_path, :text
      add :branch, :text
      add :base_sha, :text
      add :changes_stat, :text
      add :integrated, :boolean, null: false, default: false
    end

    alter table(:settings) do
      add :worktrees_enabled, :boolean, null: false, default: true
    end

    alter table(:messages) do
      add :attachments, {:array, :map}, default: []
    end

    alter table(:conversations) do
      add :queued, {:array, :string}, default: []
    end

    alter table(:runs) do
      add :interrupted, :boolean, null: false, default: false
    end

    create table(:mcp_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :transport, :string, null: false, default: "stdio"
      add :command, :string
      add :args, {:array, :string}, default: []
      add :env, :map, default: %{}
      add :url, :string
      add :headers, :map, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_servers, [:name])
    create index(:mcp_servers, [:project_id])

    create table(:checkpoints, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :run_id, :binary_id
      add :node_id, :binary_id
      add :path, :text, null: false
      add :previous_content, :text
      add :restorable, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:checkpoints, [:conversation_id])
    create index(:checkpoints, [:run_id])
  end
end
