defmodule SwarmCode.Domain.Repo.Migrations.NodeInput do
  use Ecto.Migration

  # Spec 45 §2 / §8.3: an op node keeps the tool arguments it was called with
  # (JSON, windowed to 8 KB) so the timeline's Inspector can show its Input
  # tab after the run is gone. `llm` ops store nothing.
  def change do
    alter table(:nodes) do
      add :input, :text
    end
  end
end
