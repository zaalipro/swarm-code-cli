defmodule SwarmCode.Domain.Repo.Migrations.UniqueScheduledOccurrence do
  use Ecto.Migration

  def up do
    create unique_index(:scheduled_runs, [:task_id, :scheduled_for])
  end

  def down, do: drop(index(:scheduled_runs, [:task_id, :scheduled_for]))
end
