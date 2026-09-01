defmodule SwarmCode.Daemon.Backup.Artifact do
  @moduledoc false

  @enforce_keys [
    :database,
    :manifest,
    :operation_id,
    :source_sha256,
    :backup_sha256,
    :verified_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          database: Path.t(),
          manifest: Path.t(),
          operation_id: String.t(),
          source_sha256: String.t(),
          backup_sha256: String.t(),
          verified_at: String.t()
        }
end
