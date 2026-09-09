defmodule SwarmCode.Domain.Repo.Migrations.BenchLayout do
  @moduledoc """
  Spec 57 §7: the global default layout of the pane's consensus card —
  `scales | rail | spine | scorecard`. `consensus_layout` (spec 40 §2.4) is the
  transcript card's pane arrangement (`stacked | side`) and stays as it is.
  """
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :bench_layout, :string, null: false, default: "scales"
    end
  end
end
