defmodule SwarmCode.Daemon.CrossAppLease.OwnerRecord do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.ProcessIdentity

  @allowed_keys [
    :identity,
    :schema_contract,
    :app_version,
    :database_fingerprint,
    :socket_path,
    :lease_path,
    :owner_path,
    :cleanup_barrier,
    :startup_reply,
    :name,
    :test_open_hook,
    :ipc_nonce,
    :owner_atomic_replace_opts
  ]

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
  def new(opts) when is_list(opts) do
    :ok = validate_input!(opts)
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

  def new(_opts), do: raise(ArgumentError, "invalid lease owner input")

  defp validate_input!(opts) do
    required = [:identity, :schema_contract, :app_version, :database_fingerprint, :socket_path]
    keys = Keyword.keys(opts)
    identity = Keyword.get(opts, :identity)
    contract = Keyword.get(opts, :schema_contract)

    if Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
         Enum.all?(keys, &(&1 in @allowed_keys)) and
         Enum.all?(required, &Keyword.has_key?(opts, &1)) and
         valid_identity?(identity) and
         valid_contract?(contract) and
         valid_version?(Keyword.get(opts, :app_version)) and
         valid_text?(Keyword.get(opts, :database_fingerprint), 4_096) and
         valid_path?(Keyword.get(opts, :socket_path)) do
      :ok
    else
      raise ArgumentError, "invalid lease owner input"
    end
  end

  defp valid_identity?(%ProcessIdentity{
         uid: uid,
         pid: pid,
         process_start_id: process_start_id,
         boot_id: boot_id
       }) do
    is_integer(uid) and uid >= 0 and is_integer(pid) and pid > 0 and
      valid_text?(process_start_id, 4_096) and valid_text?(boot_id, 4_096)
  end

  defp valid_identity?(_identity), do: false

  defp valid_contract?(contract) when is_map(contract) do
    Map.keys(contract) |> Enum.sort() == [:epoch, :manifest_sha256, :newest_migration] and
      is_integer(contract.epoch) and contract.epoch >= 0 and
      is_integer(contract.newest_migration) and contract.newest_migration > 0 and
      is_binary(contract.manifest_sha256) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, contract.manifest_sha256)
  end

  defp valid_contract?(_contract), do: false

  defp valid_version?(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} -> to_string(parsed) == version
      _other -> false
    end
  end

  defp valid_version?(_version), do: false

  defp valid_path?(path), do: valid_text?(path, 16 * 1_024) and Path.type(path) == :absolute

  defp valid_text?(value, maximum) when is_binary(value),
    do:
      byte_size(value) in 1..maximum and String.valid?(value) and
        not String.contains?(value, [<<0>>, "\n", "\r"])

  defp valid_text?(_value, _maximum), do: false

  @spec to_map(t()) :: %{String.t() => String.t() | integer()}
  def to_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
