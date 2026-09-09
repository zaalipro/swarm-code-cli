defmodule SwarmCode.Domain.Repo.Migrations.AddGoalModeReasoning do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :goal, :text
      add :mode, :string, null: false, default: "build"
    end

    alter table(:messages) do
      add :reasoning, :text
    end

    alter table(:nodes) do
      add :turn, :integer
      add :max_turns, :integer
    end

    alter table(:settings) do
      add :show_reasoning, :boolean, null: false, default: false
      add :pane_view, :string, null: false, default: "cards"
    end

    # Runs used to die at 40 turns; the new default is 60 (see Setting schema).
    execute "UPDATE settings SET max_agent_turns = 60 WHERE max_agent_turns = 40", ""
  end
end
