defmodule SwarmCode.Domain.Repo.Migrations.AgentsView do
  use Ecto.Migration

  def change do
    # Tree (with connectors) or the flat grid in the Agents tab (spec 06 §4).
    alter table(:settings) do
      add :agents_view, :string, default: "tree"
    end
  end
end
