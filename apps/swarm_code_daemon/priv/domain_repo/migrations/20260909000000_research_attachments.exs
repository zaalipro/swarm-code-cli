defmodule SwarmCode.Domain.Repo.Migrations.ResearchAttachments do
  @moduledoc "Spec 25 §3.3: the researches a message carries into the model's context."
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :research_ids, {:array, :integer}, null: false, default: []
    end
  end
end
