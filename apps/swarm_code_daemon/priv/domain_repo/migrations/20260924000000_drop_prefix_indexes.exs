defmodule SwarmCode.Domain.Repo.Migrations.DropPrefixIndexes do
  use Ecto.Migration

  # Spec 51 §1.6: `nodes_run_id_index` (20260820000001) is a prefix of
  # `nodes_run_id_position_index` (20260905000002) and `messages_conversation_id_index`
  # (20260820000001) a prefix of the unique `messages_conversation_id_position_index`
  # (20260905000000). Both were paid for on every write and chosen by no plan.
  def up do
    execute("DROP INDEX IF EXISTS nodes_run_id_index")
    execute("DROP INDEX IF EXISTS messages_conversation_id_index")

    # The dev file was migrated before 20260905000003 existed (or lost it); idempotent
    # everywhere else — the sidebar's latest-run query wants this descending composite.
    execute(
      "CREATE INDEX IF NOT EXISTS runs_conversation_id_started_at_desc_index " <>
        "ON runs (conversation_id ASC, started_at DESC)"
    )
  end

  # Recreating prefix indexes nothing reads would be a regression (the model of
  # 20260905000004), so `down` only has to leave the schema usable.
  def down, do: :ok
end
