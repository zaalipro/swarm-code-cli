defmodule SwarmCode.Domain.Repo.Migrations.ConsensusCards do
  use Ecto.Migration

  # Spec 40 §2.2: a judged run remembers its setup (checks, rounds, judge);
  # §2.4: the transcript card's stacked / side-by-side preference; §3.3: the
  # sidebar's scroll offset.
  def change do
    alter table(:runs) do
      add :consensus_config, :map
    end

    alter table(:settings) do
      add :consensus_layout, :string, null: false, default: "stacked"
      add :sidebar_scroll, :integer, null: false, default: 0
    end
  end
end
