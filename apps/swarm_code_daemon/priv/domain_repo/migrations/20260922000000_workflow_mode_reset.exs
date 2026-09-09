defmodule SwarmCode.Domain.Repo.Migrations.WorkflowModeReset do
  @moduledoc """
  Spec 50 §6.4: `conversations.authoring_workflow` was a flag nothing but a
  successful `workflow_save` ever cleared, so every conversation in which a
  `/create-workflow` turn was abandoned still carries it. From this pass it is
  the Workflow *mode* the composer shows (spec 50 §2.1), and a stale `true`
  would put a conversation in a mode its owner never picked — and turn the next
  plain message into an authoring turn.

  Clear it once. The mode is one click to set again, and no message, run or node
  is touched. There is nothing to restore, so the `down` is a no-op.
  """
  use Ecto.Migration

  def change do
    execute(
      "UPDATE conversations SET authoring_workflow = 0 WHERE authoring_workflow = 1",
      "SELECT 1"
    )
  end
end
