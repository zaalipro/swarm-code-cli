defmodule SwarmCode.Domain.Repo.Migrations.ShellSettings do
  use Ecto.Migration

  # spec 66 T6/T7: what the agent's shell is, and what it may see of the
  # environment. `shell_env_keep` is declared like the other array columns of
  # the schema, so SQLite stores JSON text and `{:array, :string}` round-trips.
  def change do
    alter table(:settings) do
      add :shell_env_scrub, :boolean, default: true
      add :shell_env_keep, {:array, :string}, default: ["GITHUB_TOKEN", "GH_TOKEN"]
      add :shell_path, :string
      add :shell_login, :boolean, default: true
    end
  end
end
