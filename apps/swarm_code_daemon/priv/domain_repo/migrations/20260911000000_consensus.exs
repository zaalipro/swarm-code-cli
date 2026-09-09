defmodule SwarmCode.Domain.Repo.Migrations.Consensus do
  use Ecto.Migration

  # Spec 37 §1: the consensus toggle, its checks and the judge model live on
  # the conversation; a run remembers that it was judged so its card can say so.
  def change do
    alter table(:conversations) do
      add :consensus, :boolean, default: false, null: false
      # nil = the catalogue defaults (SwarmCode.Domain.Engine.Consensus.default_keys/0)
      add :consensus_checks, {:array, :string}
      add :consensus_rounds, :integer, default: 2, null: false
      add :judge_provider_id, :binary_id
      add :judge_model, :string
      add :judge_effort, :string
    end

    alter table(:runs) do
      add :consensus, :boolean, default: false, null: false
    end
  end
end
