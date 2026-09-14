defmodule SwarmCode.Domain.Repo.Migrations.ErrorKind do
  use Ecto.Migration

  # spec 67 T30 (G42): `nodes.error` and `runs` carried the failure as English
  # prose, so the one consumer that had to decide on it — the context-overflow
  # retry — matched six phrases, and nothing else upstream could branch at all.
  # The kind is `SwarmCode.Domain.LLM.Error.kinds/0` as a string; nil on every row
  # written before this pass.
  def change do
    alter table(:nodes) do
      add :error_kind, :string
    end

    alter table(:runs) do
      add :error_kind, :string
    end
  end
end
