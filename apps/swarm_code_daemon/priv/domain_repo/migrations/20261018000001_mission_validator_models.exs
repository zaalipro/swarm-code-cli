defmodule SwarmCode.Domain.Repo.Migrations.MissionValidatorModels do
  use Ecto.Migration

  # Spec 75 (pass 71): the mission validator — a third model beside the
  # orchestrator (the conversation's chat_* slot) and the worker (swarm_*).
  # Additive only: nil means "the main model" (Providers.effective_model/2).
  def change do
    alter table(:conversations) do
      add :validator_provider_id, :binary_id
      add :validator_model, :string
      add :validator_effort, :string
    end

    alter table(:settings) do
      add :default_validator_provider_id, :binary_id
      add :default_validator_model, :string
      add :default_validator_effort, :string
    end
  end
end
