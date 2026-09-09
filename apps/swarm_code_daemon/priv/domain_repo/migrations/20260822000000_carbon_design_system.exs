defmodule SwarmCode.Domain.Repo.Migrations.CarbonDesignSystem do
  use Ecto.Migration

  def up do
    alter table(:settings) do
      add :sidebar_width, :integer, null: false, default: 280
      add :reduce_motion, :boolean, null: false, default: false
      add :default_effort, :string, null: false, default: "medium"
      add :monthly_budget_usd, :float
    end

    alter table(:conversations) do
      add :effort, :string
    end

    flush()

    # The user wants the new look right away, so existing installs move over.
    execute("UPDATE settings SET theme = 'carbon'")
  end

  def down do
    alter table(:settings) do
      remove :sidebar_width
      remove :reduce_motion
      remove :default_effort
      remove :monthly_budget_usd
    end

    alter table(:conversations) do
      remove :effort
    end

    flush()

    execute("UPDATE settings SET theme = 'obsidian'")
  end
end
