defmodule SwarmCode.Domain.Repo.Migrations.CreateSwarmCodeSchema do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :theme, :string, default: "obsidian", null: false
      add :mode, :string, default: "dark", null: false
      add :sidebar_collapsed, :boolean, default: false, null: false
      add :split_ratio, :float, default: 0.5, null: false
      add :tavily_api_key, :string
      add :max_concurrent_agents, :integer, default: 4, null: false
      add :max_agent_depth, :integer, default: 2, null: false
      add :max_agent_turns, :integer, default: 40, null: false
      add :command_timeout_ms, :integer, default: 120_000, null: false
      add :default_chat_provider_id, :binary_id
      add :default_chat_model, :string
      add :default_swarm_provider_id, :binary_id
      add :default_swarm_model, :string
      add :pricing, :map

      timestamps(type: :utc_datetime_usec)
    end

    create table(:providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false, default: "openai_compatible"
      add :base_url, :string, null: false
      add :api_key, :string, default: ""
      add :models, {:array, :string}
      add :default_model, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:providers, [:name])

    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :root_path, :string, null: false
      add :approval_mode, :string, null: false, default: "auto"
      add :last_opened_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:root_path])

    create table(:conversations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false, default: "New conversation"
      add :chat_provider_id, :binary_id
      add :chat_model, :string
      add :swarm_provider_id, :binary_id
      add :swarm_model, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:project_id])

    create table(:messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :string, null: false
      add :content, :text, default: ""
      add :run_id, :binary_id
      add :tokens_in, :integer, default: 0
      add :tokens_out, :integer, default: 0
      add :cost_usd, :float
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:conversation_id])

    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :status, :string, null: false, default: "running"
      add :prompt, :text, default: ""
      add :root_node_id, :binary_id
      add :assistant_message_id, :binary_id
      add :tokens_in, :integer, default: 0
      add :tokens_out, :integer, default: 0
      add :cost_usd, :float
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:conversation_id])

    create table(:nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :parent_id, :binary_id
      add :kind, :string, null: false
      add :op_type, :string
      add :name, :string
      add :role, :string
      add :title, :string, default: ""
      add :status, :string, null: false, default: "running"
      add :progress, :integer
      add :detail, :string
      add :result, :text
      add :error, :string
      add :tokens_in, :integer, default: 0
      add :tokens_out, :integer, default: 0
      add :cost_usd, :float
      add :depth, :integer, default: 0
      add :position, :integer, default: 0
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:nodes, [:run_id])
  end
end
