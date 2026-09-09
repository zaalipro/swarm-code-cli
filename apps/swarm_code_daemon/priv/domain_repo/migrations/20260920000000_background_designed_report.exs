defmodule SwarmCode.Domain.Repo.Migrations.BackgroundDesignedReport do
  use Ecto.Migration

  # Spec 48 §2: the designed HTML report leaves the critical path. A research is
  # `done` when `result.md` and the rendered report are on disk; `design_state`
  # then says what the report currently is — "rendered", "designing", "designed"
  # or "failed". NULL is a row from before this pass and reads exactly as it did.
  #
  # Spec 48 §5 raises `research_max_live` to 10 (Ultra's whole fan-out) in the
  # Ecto schema only: SQLite has no ALTER COLUMN (`ecto_sqlite3`'s
  # `connection.ex:1632` raises on `modify`), the settings row is always written
  # through the schema, and an existing row's 6 may be a deliberate choice about
  # load. The owner's dev row is moved through the app instead.
  def change do
    alter table(:researches) do
      add :design_state, :string
    end

    alter table(:settings) do
      add :research_auto_design, :string, null: false, default: "deep"
    end
  end
end
