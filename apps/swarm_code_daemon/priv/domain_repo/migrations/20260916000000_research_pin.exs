defmodule SwarmCode.Domain.Repo.Migrations.ResearchPin do
  use Ecto.Migration

  # Spec 41 §1.0: a research can be pinned to the top of the sidebar and the
  # index, exactly as a conversation is (`conversations.pinned_at`, spec 21 §4).
  # The column is both the flag and the sort key: SQLite orders NULLs last on a
  # DESC sort, so `order_by: [desc: pinned_at, desc: inserted_at, desc: id]`
  # is "pinned first, newest pin first, then everything else newest first".
  def change do
    alter table(:researches) do
      add :pinned_at, :utc_datetime_usec
    end

    create index(:researches, [:pinned_at])
  end
end
