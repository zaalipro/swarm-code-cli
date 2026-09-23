defmodule SwarmCode.Domain.Repo.Migrations.Keybindings do
  # spec 70 E3
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :keybindings, :string, default: "{}"
    end
  end
end
