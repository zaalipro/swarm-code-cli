defmodule SwarmCode.Domain.Repo.Migrations.Resume do
  use Ecto.Migration

  # Spec 45 §2 / §5.2: a resumed chat or swarm run is a NEW run that names the
  # one it continues, so `Consensus.rounds/2` can prepend the earlier attempt's
  # rounds and the card can say "resumed from …".
  def change do
    alter table(:runs) do
      add :resumed_from_run_id, :binary_id
    end

    create index(:runs, [:resumed_from_run_id])
  end
end
