defmodule SwarmCode.Domain.Repo.Migrations.McpDisabledTools do
  use Ecto.Migration

  # spec 62 T1: the tools of a server the owner switched off. Declared like the
  # other array column of the table (`args`), so SQLite stores JSON text and the
  # Ecto `{:array, :string}` field round-trips.
  def change do
    alter table(:mcp_servers) do
      add :disabled_tools, {:array, :string}, default: []
    end
  end
end
