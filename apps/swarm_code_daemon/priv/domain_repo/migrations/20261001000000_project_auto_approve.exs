defmodule SwarmCode.Domain.Repo.Migrations.ProjectAutoApprove do
  use Ecto.Migration

  # spec 66 T5: the command families the user pressed `Always allow "mix test"`
  # on, per project. Declared like the other array columns of the schema
  # (`mcp_servers.args`), so SQLite stores JSON text and the Ecto
  # `{:array, :string}` field round-trips.
  def change do
    alter table(:projects) do
      add :auto_approve_prefixes, {:array, :string}, default: []
    end
  end
end
