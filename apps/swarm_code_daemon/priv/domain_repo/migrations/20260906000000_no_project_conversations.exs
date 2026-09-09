defmodule SwarmCode.Domain.Repo.Migrations.NoProjectConversations do
  use Ecto.Migration

  # Spec 21 §2.1. `projects.scratch` marks the one hidden project that holds the
  # conversations the user started without picking a project — the engine keeps
  # its "every run has a root" invariant, and `Projects.list/0` never lists it.
  # `conversations.pinned_at` is both the flag and the sort key of the sidebar's
  # Pinned section (§4.3).
  def change do
    alter table(:projects) do
      add :scratch, :boolean, default: false, null: false
    end

    alter table(:conversations) do
      add :pinned_at, :utc_datetime_usec
    end

    create index(:projects, [:scratch])
    create index(:conversations, [:pinned_at])
  end
end
