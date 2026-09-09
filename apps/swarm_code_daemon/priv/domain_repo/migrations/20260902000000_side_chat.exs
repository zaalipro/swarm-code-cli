defmodule SwarmCode.Domain.Repo.Migrations.SideChat do
  use Ecto.Migration

  # Spec 13 §3.1: the width of the side-chat column, as a fraction of the split
  # exactly like `split_ratio`.
  def change do
    alter table(:settings) do
      add :side_ratio, :float, default: 0.32, null: false
    end
  end
end
