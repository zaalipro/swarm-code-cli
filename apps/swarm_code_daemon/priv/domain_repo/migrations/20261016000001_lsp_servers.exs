# spec 70 B4
defmodule SwarmCode.Domain.Repo.Migrations.LspServers do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :lsp_servers, :map, default: %{}
    end
  end
end
