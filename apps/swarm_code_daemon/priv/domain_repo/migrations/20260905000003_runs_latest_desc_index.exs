defmodule SwarmCode.Domain.Repo.Migrations.RunsLatestDescIndex do
  use Ecto.Migration

  def up do
    # ecto_sqlite3 accepts literal index expressions for direction (its DDL
    # adapter does not implement Ecto's keyword-list direction syntax).
    create index(:runs, ["conversation_id ASC", "started_at DESC"],
             name: :runs_conversation_id_started_at_desc_index
           )
  end

  def down do
    drop index(:runs, ["conversation_id ASC", "started_at DESC"],
           name: :runs_conversation_id_started_at_desc_index
         )
  end
end
