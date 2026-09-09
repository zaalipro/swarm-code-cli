defmodule SwarmCode.Domain.Repo.Migrations.ResearchHeadlinesToggle do
  use Ecto.Migration

  # Spec 39 §2.3: the per-round headline (spec 26 §4.1) can be turned off.
  def change do
    alter table(:settings) do
      add :research_headlines, :boolean, null: false, default: true
    end
  end
end
