defmodule SwarmCode.Domain.Repo.Migrations.IsolationBackend do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :isolation_backend, :string, default: "auto", null: false
    end
  end
end
