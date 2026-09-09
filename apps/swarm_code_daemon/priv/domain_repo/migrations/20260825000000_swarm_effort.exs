defmodule SwarmCode.Domain.Repo.Migrations.SwarmEffort do
  use Ecto.Migration

  def change do
    # Chat turns and swarm runs get their own reasoning effort: a cheap, fast
    # chat model next to a deep-thinking swarm (spec 06 §9).
    alter table(:conversations) do
      add :swarm_effort, :string
    end

    alter table(:settings) do
      add :default_swarm_effort, :string, default: "medium"
    end
  end
end
