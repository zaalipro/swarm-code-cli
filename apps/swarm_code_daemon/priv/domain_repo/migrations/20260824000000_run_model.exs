defmodule SwarmCode.Domain.Repo.Migrations.RunModel do
  use Ecto.Migration

  def change do
    # The usage table shows which model a run actually used; the conversation's
    # current model is not it once the user switches models mid-conversation.
    alter table(:runs) do
      add :model, :string
    end
  end
end
