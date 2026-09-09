defmodule SwarmCode.Domain.Repo.Migrations.ResearchOverrides do
  use Ecto.Migration

  # Spec 40 §1.0: one research can run on a model of its own, which overrides
  # all three Settings tiers; §1.6: agents time out and may be retried.
  def change do
    alter table(:researches) do
      add :provider_id, :binary_id
      add :model, :string
      add :effort, :string
    end

    alter table(:settings) do
      add :research_agent_timeout_s, :integer, null: false, default: 600
      add :research_retry_timeouts, :boolean, null: false, default: true
      add :research_max_retries, :integer, null: false, default: 1
    end
  end
end
