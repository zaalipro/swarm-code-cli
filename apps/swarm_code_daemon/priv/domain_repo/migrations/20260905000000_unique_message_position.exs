defmodule SwarmCode.Domain.Repo.Migrations.UniqueMessagePosition do
  use Ecto.Migration

  def up do
    create unique_index(:messages, [:conversation_id, :position])
  end

  def down, do: drop(index(:messages, [:conversation_id, :position]))
end
