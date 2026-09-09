defmodule SwarmCode.Domain.Repo.Migrations.DropSpec36Leftovers do
  use Ecto.Migration

  # Spec 36 §B9 / §A10 said "drop with the next migration"; spec 51 §1.8 does. Plain
  # columns, no index, no FK — SQLite ≥ 3.35 DROP COLUMN (ecto_sqlite3 emits it for
  # `remove`); the type and default keep the migration reversible.
  def change do
    alter table(:settings) do
      remove :split_ratio, :float, default: 0.5
      remove :side_ratio, :float, default: 0.32
    end

    alter table(:runs) do
      remove :assistant_message_id, :binary_id
    end
  end
end
