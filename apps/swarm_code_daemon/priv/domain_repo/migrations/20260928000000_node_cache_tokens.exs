defmodule SwarmCode.Domain.Repo.Migrations.NodeCacheTokens do
  @moduledoc """
  Spec 53b §5: the two prompt-cache counters the Messages API reports were
  collected and then thrown away at the last step, so a warm turn was priced as
  if every token of its prefix were fresh input. They are now kept per agent —
  which also makes the cache hit rate observable, the only way to see whether
  the append-only history of §4 is doing its job.
  """
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add :cache_read, :integer, default: 0
      add :cache_write, :integer, default: 0
    end
  end
end
