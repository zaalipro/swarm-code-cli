defmodule SwarmCode.Domain.Repo.Migrations.ProviderRefusalFallbacks do
  @moduledoc """
  Spec 53b §3: Claude Opus 5 and Claude Fable 5.1 answer a request
  their safety classifiers decline with a 200 and `stop_reason: "refusal"`, and
  the migration guide's instruction is to opt into the server-side fallback
  from day one. The opt-in is a per-provider toggle, on by default.
  """
  use Ecto.Migration

  def change do
    alter table(:providers) do
      add :fallbacks, :boolean, default: true, null: false
    end
  end
end
