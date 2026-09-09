defmodule SwarmCode.Domain.Repo.Migrations.DeepResearch do
  @moduledoc "Spec 24 §2.1: researches, their steps, the search providers and the settings."
  use Ecto.Migration

  def up do
    # The default integer primary key on purpose: `#2` is what the user types.
    create table(:researches) do
      add :question, :text, null: false
      add :level, :string, null: false, default: "medium"
      add :status, :string, null: false, default: "queued"
      add :title, :string
      add :interpretation, :text
      add :summary, :text
      add :step, :integer, null: false, default: 0
      add :steps_total, :integer, null: false, default: 1
      add :fanout, :integer, null: false, default: 3
      add :dir, :string
      add :result_path, :string
      add :report_path, :string
      add :sources, {:array, :map}, null: false, default: []
      add :tokens_in, :integer, null: false, default: 0
      add :tokens_out, :integer, null: false, default: 0
      add :cost_usd, :float
      add :error, :text
      # Plain columns: `conversations.research_id` carries the foreign key the
      # other way and SQLite has no deferred constraints to close the cycle.
      add :run_id, :binary_id
      add :conversation_id, :binary_id
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:researches, [:status])

    # ecto_sqlite3 wants a literal direction expression and an explicit name.
    create index(:researches, ["inserted_at DESC"], name: :researches_inserted_at_desc_index)

    create table(:research_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :research_id, references(:researches, on_delete: :delete_all), null: false
      add :index, :integer, null: false
      add :title, :string
      add :tasks, {:array, :map}, null: false, default: []
      add :notes, {:array, :map}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:research_steps, [:research_id, :index])

    create table(:search_providers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :api_key, :string, default: ""
      add :base_url, :string
      add :enabled, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:search_providers, [:kind])

    # The hidden conversation a research owns; every sidebar list filters it out.
    alter table(:conversations) do
      add :research_id, references(:researches, on_delete: :delete_all)
    end

    create index(:conversations, [:research_id])

    alter table(:settings) do
      add :research_level, :string, null: false, default: "medium"
      add :research_max_live, :integer, null: false, default: 6
      add :research_max_sources, :integer, null: false, default: 5
      add :research_recency_days, :integer
      add :research_include_domains, {:array, :string}, null: false, default: []
      add :research_exclude_domains, {:array, :string}, null: false, default: []
      add :research_reader, :string, null: false, default: "web_fetch"
      add :research_lead_provider_id, :binary_id
      add :research_lead_model, :string
      add :research_lead_effort, :string
      add :research_worker_provider_id, :binary_id
      add :research_worker_model, :string
      add :research_worker_effort, :string
      add :research_reporter_provider_id, :binary_id
      add :research_reporter_model, :string
      add :research_reporter_effort, :string
    end

    flush()
    seed_tavily()
  end

  def down do
    alter table(:settings) do
      remove :research_level
      remove :research_max_live
      remove :research_max_sources
      remove :research_recency_days
      remove :research_include_domains
      remove :research_exclude_domains
      remove :research_reader
      remove :research_lead_provider_id
      remove :research_lead_model
      remove :research_lead_effort
      remove :research_worker_provider_id
      remove :research_worker_model
      remove :research_worker_effort
      remove :research_reporter_provider_id
      remove :research_reporter_model
      remove :research_reporter_effort
    end

    drop index(:conversations, [:research_id])

    alter table(:conversations) do
      remove :research_id
    end

    drop table(:search_providers)
    drop table(:research_steps)
    drop table(:researches)
  end

  # Whoever already had a Tavily key keeps searching without opening Settings.
  defp seed_tavily do
    key =
      case repo().query("SELECT tavily_api_key FROM settings LIMIT 1", []) do
        {:ok, %{rows: [[key]]}} when is_binary(key) -> String.trim(key)
        _other -> ""
      end

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    # Raw SQL, not `insert_all`: with no schema to cast against, ecto_sqlite3
    # would store `enabled` as the string "false" and every later read would
    # blow up loading it as a boolean.
    repo().query!(
      """
      INSERT INTO search_providers (id, kind, api_key, base_url, enabled, position,
                                    inserted_at, updated_at)
      VALUES (?1, 'tavily', ?2, NULL, ?3, 0, ?4, ?4)
      """,
      [Ecto.UUID.bingenerate(), key, if(key == "", do: 0, else: 1), now]
    )
  end
end
