defmodule SwarmCode.Domain.Repo.Migrations.SupersedeOnEdit do
  @moduledoc """
  Spec 52 §1.1: editing a message retries it in place instead of forking the
  conversation. The old turn — the user row, its run and every message of that
  run — is marked instead of deleted, so the transcript keeps it and the model
  never reads it again.
  """
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :superseded_at, :utc_datetime_usec
    end

    alter table(:runs) do
      add :superseded_at, :utc_datetime_usec
    end

    # No indexes: both columns are read together with rows already selected by
    # `conversation_id`.
  end
end
