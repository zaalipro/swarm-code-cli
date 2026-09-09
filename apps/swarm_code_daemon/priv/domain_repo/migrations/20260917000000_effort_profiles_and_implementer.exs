defmodule SwarmCode.Domain.Repo.Migrations.EffortProfilesAndImplementer do
  use Ecto.Migration

  # Spec 45 §2 (Y): reasoning-effort profiles per provider (and per model), and
  # the consensus implementer — a third model beside the planner and the judge.
  # `{:array, :map}` is JSON under ecto_sqlite3, like `providers.models`.
  def change do
    alter table(:providers) do
      # nil = the built-in defaults for the provider's kind (spec 45 §3.2).
      add :effort_levels, {:array, :map}
      # %{"<model>" => [level]} — a model's own list wins over the provider's.
      add :model_effort_levels, :map, default: "{}"
    end

    alter table(:conversations) do
      add :implementer_provider_id, :binary_id
      add :implementer_model, :string
      add :implementer_effort, :string
    end

    alter table(:settings) do
      add :default_implementer_provider_id, :binary_id
      add :default_implementer_model, :string
      add :default_implementer_effort, :string
    end
  end
end
