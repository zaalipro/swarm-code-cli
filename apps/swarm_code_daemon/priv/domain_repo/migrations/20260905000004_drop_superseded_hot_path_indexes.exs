defmodule SwarmCode.Domain.Repo.Migrations.DropSupersededHotPathIndexes do
  use Ecto.Migration

  # An earlier version of `20260905000002` created two indexes the planner never
  # chooses: one on `messages {conversation_id, position}`, duplicating the
  # unique index of `20260905000000`, and an ascending one on
  # `runs {conversation_id, started_at}`, superseded by the descending index of
  # `20260905000003`. Databases that ran that version keep paying for them on
  # every write; `IF EXISTS` makes this a no-op everywhere else.
  @superseded [
    "messages_conversation_id_position_order_index",
    "runs_conversation_id_started_at_index"
  ]

  def up do
    for name <- @superseded, do: execute("DROP INDEX IF EXISTS #{name}")
  end

  # Recreating an index nothing reads would be a regression, so `down` only has
  # to leave the schema usable.
  def down, do: :ok
end
