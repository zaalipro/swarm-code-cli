defmodule SwarmCode.Domain.Repo.Migrations.CompactDue do
  use Ecto.Migration

  # spec 67 T9 (B34): an automatic compaction is no longer run from inside the
  # turn that tripped it — the agent only raises this flag, and the *next*
  # `Engine.start_chat_turn/4` compacts before it reserves its own two rows.
  # Without it the summary landed above the answer of the running turn and that
  # answer was never read again.
  def change do
    alter table(:conversations) do
      add :compact_due, :boolean, default: false
    end
  end
end
