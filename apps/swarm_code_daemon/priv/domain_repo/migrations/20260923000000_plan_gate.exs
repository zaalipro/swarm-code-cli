defmodule SwarmCode.Domain.Repo.Migrations.PlanGate do
  @moduledoc "Spec 50 §4 + §7: the mode a run ran in, and the plan gate's two links."
  use Ecto.Migration

  def change do
    alter table(:runs) do
      # Spec 50 §4: the mode this run actually ran in — `conversations.mode` is
      # mutable, so a finished run could not say whether it was a plan.
      add :mode, :string
      # Spec 50 §7: the planner run this run implements, and what the user did
      # with the plan (nil | approved | declined | revised).
      add :implements_run_id, :binary_id
      add :plan_state, :string
    end

    create index(:runs, [:implements_run_id])
  end
end
