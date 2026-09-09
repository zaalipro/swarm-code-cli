defmodule SwarmCode.Domain.Repo.Migrations.PromptPanelSize do
  use Ecto.Migration

  # Spec 22 §5.3: how much of an agent's prompt the `Prompt` drawer shows —
  # `sm` one line, `md` two, `lg` three plus the run's context.
  def change do
    alter table(:settings) do
      add :prompt_size, :string, default: "md"
    end
  end
end
