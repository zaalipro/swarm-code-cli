defmodule SwarmCode.Domain.Repo.Migrations.HotPathIndexes do
  use Ecto.Migration

  # `messages` needs nothing here: `20260905000000_unique_message_position`
  # already creates a unique index on `{conversation_id, position}`, which the
  # planner uses for the transcript's ordered read. `runs` is ordered
  # `started_at DESC`, so its index lives in the next migration — an ascending
  # one is never chosen for it.
  def up do
    create index(:nodes, [:run_id, :position])
  end

  def down do
    drop index(:nodes, [:run_id, :position])
  end
end
