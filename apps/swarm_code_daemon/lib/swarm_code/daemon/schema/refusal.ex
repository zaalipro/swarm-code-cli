defmodule SwarmCode.Daemon.Schema.Refusal do
  @moduledoc """
  The schema refusals a person can act on, as one sentence each (pass 70
  D2, and Q13 for a stray or damaged file). All keep the
  `:schema_incompatible` code, so every layer that already handles that code
  (the directory protocol, the launchers' exit status) treats them the same;
  only the words differ from the generic probe failure.
  """

  alias SwarmCode.Daemon.StartupError

  @doc "The database carries migrations this build does not know: the desktop is newer."
  @spec database_ahead() :: StartupError.t()
  def database_ahead do
    StartupError.new(
      :schema_incompatible,
      false,
      "This SwarmCode database was upgraded by a newer SwarmCode app than this swarmcode supports.",
      "Update swarmcode to a build made for your SwarmCode app; the database was not changed."
    )
  end

  @doc "The file where the database belongs is not an SQLite database (pass70 Q13)."
  @spec not_a_database() :: StartupError.t()
  def not_a_database do
    StartupError.new(
      :schema_incompatible,
      false,
      "The file where your conversations database belongs is not a SwarmCode database.",
      "Move swarm_code.db aside or restore it from a verified backup, then run swarmcode again; nothing was changed."
    )
  end

  @doc "The database fails SQLite's own integrity check (pass70 Q13)."
  @spec damaged() :: StartupError.t()
  def damaged do
    StartupError.new(
      :schema_incompatible,
      false,
      "Your conversations database failed SQLite's integrity check.",
      "Restore swarm_code.db from a verified backup, then run swarmcode again; nothing was changed."
    )
  end

  @doc "A pending migration is not one the CLI may run ahead of the desktop."
  @spec desktop_upgrade_required() :: StartupError.t()
  def desktop_upgrade_required do
    StartupError.new(
      :schema_incompatible,
      false,
      "This SwarmCode database needs an upgrade that only the SwarmCode app makes.",
      "Open the SwarmCode app once to upgrade the database, quit it, then run swarmcode again."
    )
  end
end
