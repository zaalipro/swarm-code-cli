defmodule SwarmCode.Domain.Repo.Migrations.ChatThreads do
  use Ecto.Migration

  # Pass 12 §1/§6: the per-run seen marker (unread badges on run cards) and the
  # run a user message replies to / steers.
  def change do
    alter table(:runs) do
      add :seen_at, :utc_datetime_usec
    end

    alter table(:messages) do
      add :reply_to_run_id, :binary_id
    end
  end
end
