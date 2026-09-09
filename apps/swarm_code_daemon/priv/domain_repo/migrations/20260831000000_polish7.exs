defmodule SwarmCode.Domain.Repo.Migrations.Polish7 do
  use Ecto.Migration

  def change do
    # Phases may be authored as %{title: …, detail: …} (spec 11 §R.1); the run
    # keeps the details next to the titles so the rail can show them.
    alter table(:workflow_runs) do
      add :phase_details, :map, default: %{}
    end
  end
end
