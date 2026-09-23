defmodule SwarmCode.Daemon.Schema.Refusal do
  @moduledoc """
  The two schema refusals a person can act on, as one sentence each (pass 70
  D2). Both keep the `:schema_incompatible` code, so every layer that already
  handles that code (the directory protocol, the launchers' exit status) treats
  them the same; only the words differ from the generic probe failure.
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
