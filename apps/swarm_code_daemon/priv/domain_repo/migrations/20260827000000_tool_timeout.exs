defmodule SwarmCode.Domain.Repo.Migrations.ToolTimeout do
  use Ecto.Migration

  def change do
    # The ceiling for everything that is not a shell command: web fetch/search
    # and MCP requests (spec 07 §10). Shell commands keep `command_timeout_ms`.
    alter table(:settings) do
      add :tool_timeout_ms, :integer, default: 120_000
    end
  end
end
