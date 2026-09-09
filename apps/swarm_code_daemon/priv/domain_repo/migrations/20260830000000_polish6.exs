defmodule SwarmCode.Domain.Repo.Migrations.Polish6 do
  use Ecto.Migration

  def change do
    # Several goals can be pursued at once (spec 10 §19); each one carries the
    # mode its runs use (spec 10 §7).
    create table(:goals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :text, :text, null: false
      add :mode, :string, null: false, default: "chat"
      add :status, :string, null: false, default: "active"
      add :run_id, :binary_id
      add :inserted_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end

    create index(:goals, [:conversation_id])

    alter table(:runs) do
      # The goal this run pursues (spec 10 §16) and its AI label (spec 10 §13).
      add :goal_id, :binary_id
      add :label, :string
    end

    alter table(:settings) do
      # macOS Space auto-switch (spec 10 §14): off by default.
      add :focus_on_finish, :boolean, default: false
    end
  end
end
