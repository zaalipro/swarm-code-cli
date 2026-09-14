defmodule SwarmCode.Domain.Repo.Migrations.ProjectTrust do
  use Ecto.Migration

  # spec 67 T31 (G44): a directory became writable the moment it was added.
  # `~/Downloads/some-repo` + "run the tests" ran its attacker-controlled
  # `npm test` and put its AGENTS.md in the prompt before any consent — and with
  # no sandbox, consent is the only line. A project is `read_only` and
  # instruction-less until `Projects.trust/1` stamps this column.
  #
  # Every project already in the database is one the owner has been working in
  # for weeks: trust gates a *new* directory, it is not a re-consent for the
  # ones already in use, so they are backfilled here and their `approval_mode`
  # is left exactly as it is.
  def up do
    alter table(:projects) do
      add :trusted_at, :utc_datetime_usec
    end

    flush()

    execute("UPDATE projects SET trusted_at = inserted_at WHERE trusted_at IS NULL")
  end

  def down do
    alter table(:projects) do
      remove :trusted_at
    end
  end
end
