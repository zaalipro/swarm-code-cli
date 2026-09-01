defmodule SwarmCode.Daemon.CrossAppLease.OwnerRecord do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.ProcessIdentity

  @enforce_keys [
    :protocol_version,
    :product,
    :app_version,
    :pid,
    :process_start_id,
    :boot_id,
    :acquired_at,
    :lease_nonce,
    :database_fingerprint,
    :schema_epoch,
    :newest_migration,
    :manifest_sha256,
    :socket_path
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          protocol_version: 1,
          product: String.t(),
          app_version: String.t(),
          pid: pos_integer(),
          process_start_id: String.t(),
          boot_id: String.t(),
          acquired_at: String.t(),
          lease_nonce: String.t(),
          database_fingerprint: String.t(),
          schema_epoch: non_neg_integer(),
          newest_migration: non_neg_integer(),
          manifest_sha256: String.t(),
          socket_path: Path.t()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %ProcessIdentity{} = identity = Keyword.fetch!(opts, :identity)

    %{epoch: epoch, newest_migration: newest, manifest_sha256: manifest} =
      Keyword.fetch!(opts, :schema_contract)

    %__MODULE__{
      protocol_version: 1,
      product: "cli-daemon",
      app_version: Keyword.fetch!(opts, :app_version),
      pid: identity.pid,
      process_start_id: identity.process_start_id,
      boot_id: identity.boot_id,
      acquired_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      lease_nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      database_fingerprint: Keyword.fetch!(opts, :database_fingerprint),
      schema_epoch: epoch,
      newest_migration: newest,
      manifest_sha256: manifest,
      socket_path: Keyword.fetch!(opts, :socket_path)
    }
  end

  @spec to_map(t()) :: %{String.t() => String.t() | integer()}
  def to_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
