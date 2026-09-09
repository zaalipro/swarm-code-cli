defmodule SwarmCode.Domain.Repo.Migrations.RunLaunch do
  use Ecto.Migration

  # Spec 17 §2.6: a run that an agent (the `start_swarm` tool, a workflow)
  # started remembers who started it, and the user message that launched a run
  # now carries that run's id — so a run never claims a message it did not
  # come from.
  def change do
    alter table(:runs) do
      add :launched_by_run_id, :binary_id
    end
  end
end
