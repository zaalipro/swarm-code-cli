defmodule SwarmCode.Domain.Repo.Migrations.ResearchHeadlines do
  use Ecto.Migration

  # Spec 26 §4.1: the round's own one-line summary, at most ten words, written
  # after its notes are in. `title` stays the lead's plan title.
  def change do
    alter table(:research_steps) do
      add :headline, :string
    end
  end
end
