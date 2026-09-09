defmodule SwarmCode.Domain.Repo.Migrations.StorageCleanup do
  @moduledoc "Spec 49 §1.6: the prune marker, the retention settings and the age indexes."
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # Spec 49 §1.5: this run's node payloads were dropped by a cleanup. The
      # rows, the tokens, the costs and the timings are all still here.
      add :pruned, :boolean, default: false, null: false
    end

    alter table(:settings) do
      # Spec 49 §2: nil means off for both.
      add :storage_retention_days, :integer
      add :storage_prune_days, :integer
      add :storage_last_cleanup_at, :utc_datetime_usec
    end

    # Spec 49 §1: the three age filters of the cleanup, none of which had an
    # index before this pass.
    create index(:runs, [:finished_at])
    create index(:checkpoints, [:inserted_at])
    create index(:conversations, [:updated_at])
  end
end
