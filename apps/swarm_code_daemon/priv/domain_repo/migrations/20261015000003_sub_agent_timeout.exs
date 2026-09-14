defmodule SwarmCode.Domain.Repo.Migrations.SubAgentTimeout do
  use Ecto.Migration

  # spec 67 T29 (G38): `spawn_agent` awaited `:infinity`. A sub-agent whose
  # provider stalled, or that talked itself into a loop, held its lead for ever
  # — and the lead was itself being awaited, so the whole run sat there. Codex
  # polls `wait_agent` with a timeout (default 30 s) and can give up.
  # Half an hour, and 0 means the old behaviour: wait for ever.
  def change do
    alter table(:settings) do
      add :sub_agent_timeout_s, :integer, default: 1800
    end
  end
end
