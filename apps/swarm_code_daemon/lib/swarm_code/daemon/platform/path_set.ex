defmodule SwarmCode.Daemon.Platform.PathSet do
  @moduledoc false

  @enforce_keys [
    :platform,
    :data,
    :config,
    :state,
    :cache,
    :runtime,
    :database,
    :lease,
    :owner_record,
    :socket,
    :socket_metadata,
    :backups
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          platform: :macos | :linux,
          data: Path.t(),
          config: Path.t(),
          state: Path.t(),
          cache: Path.t(),
          runtime: Path.t(),
          database: Path.t(),
          lease: Path.t(),
          owner_record: Path.t(),
          socket: Path.t(),
          socket_metadata: Path.t(),
          backups: Path.t()
        }
end
