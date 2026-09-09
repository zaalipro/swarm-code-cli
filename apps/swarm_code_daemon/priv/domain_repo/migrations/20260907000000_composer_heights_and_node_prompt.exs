defmodule SwarmCode.Domain.Repo.Migrations.ComposerHeightsAndNodePrompt do
  use Ecto.Migration

  # Spec 22 §1.5-§1.7 and §5.1. Null height means "auto-grow", which is the
  # behaviour every existing install already has; a number is a height the user
  # dragged and pinned. `nodes.prompt` is the prompt an agent is working on —
  # the run's prompt for an assistant or a Lead, the task for a spawned
  # sub-agent or a workflow worker.
  def change do
    alter table(:settings) do
      add :composer_h, :integer
      add :side_composer_h, :integer
    end

    alter table(:nodes) do
      add :prompt, :text
    end
  end
end
