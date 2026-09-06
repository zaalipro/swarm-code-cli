defmodule SwarmCode.Daemon.Schema.MigrationManifest do
  @moduledoc false

  @manifest_version 1
  alias SwarmCode.Daemon.Schema.Contract

  @maximum_manifest_bytes 256 * 1_024

  @top_level_keys ~w(
    application_ids
    contract
    data_epoch
    legacy_handshake
    manifest_version
    migration_set_sha256
    migrations
    minimum_reader
    minimum_writer
    sqlite_minimum
    upstream_commit
  )

  @entry_keys ~w(
    additive_desktop_readable
    filename
    schema_sha256
    source_sha256
    version
  )

  defmodule Entry do
    @moduledoc false

    @enforce_keys [
      :version,
      :filename,
      :source_sha256,
      :schema_sha256,
      :additive_desktop_readable?
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            version: pos_integer(),
            filename: String.t(),
            source_sha256: String.t(),
            schema_sha256: String.t(),
            additive_desktop_readable?: boolean()
          }
  end

  @enforce_keys [
    :manifest_version,
    :contract,
    :upstream_commit,
    :application_ids,
    :data_epoch,
    :minimum_reader,
    :minimum_writer,
    :sqlite_minimum,
    :migration_set_sha256,
    :legacy_handshake,
    :migrations
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manifest_version: pos_integer(),
          contract: String.t(),
          upstream_commit: String.t(),
          application_ids: [non_neg_integer()],
          data_epoch: non_neg_integer(),
          minimum_reader: String.t(),
          minimum_writer: String.t(),
          sqlite_minimum: String.t(),
          migration_set_sha256: String.t(),
          legacy_handshake: String.t(),
          migrations: [Entry.t()]
        }

  @spec load!() :: t()
  def load! do
    :swarm_code_daemon
    |> :code.priv_dir()
    |> case do
      path when is_list(path) ->
        Path.join(to_string(path), "schema/#{Contract.current().name}.json")

      {:error, reason} ->
        raise ArgumentError, "daemon priv directory unavailable: #{inspect(reason)}"
    end
    |> load!()
  end

  @doc false
  @spec load!(Path.t()) :: t()
  def load!(path) when is_binary(path) do
    contents = read_bounded!(path)

    case Jason.decode(contents) do
      {:ok, decoded} -> decode!(decoded)
      {:error, _reason} -> invalid!("manifest is not valid JSON")
    end
  end

  defp read_bounded!(path) do
    # Refuse known devices/directories before opening; still validate the opened
    # descriptor and bound the read independently of this path observation.
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _ -> invalid!("manifest is not a regular file")
    end

    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, record} <- :file.read_file_info(io),
               %File.Stat{type: :regular} <- File.Stat.from_record(record) do
            case IO.binread(io, @maximum_manifest_bytes + 1) do
              bytes when is_binary(bytes) and byte_size(bytes) <= @maximum_manifest_bytes ->
                bytes

              bytes when is_binary(bytes) ->
                invalid!("manifest exceeds the size limit")

              :eof ->
                <<>>

              _ ->
                invalid!("manifest cannot be read")
            end
          else
            _ -> invalid!("manifest is not a regular file")
          end
        after
          File.close(io)
        end

      {:error, _reason} ->
        invalid!("manifest cannot be read")
    end
  end

  defp decode!(decoded) when is_map(decoded) do
    exact_keys!(decoded, @top_level_keys, "manifest")

    require_equal!(decoded["manifest_version"], @manifest_version, "manifest version")

    contract =
      case Contract.fetch(decoded["upstream_commit"]) do
        {:ok, contract} -> contract
        :error -> invalid!("unsupported upstream commit")
      end

    require_equal!(decoded["contract"], contract.name, "contract")
    require_equal!(decoded["application_ids"], [0], "application IDs")
    require_equal!(decoded["data_epoch"], 0, "data epoch")

    require_equal!(
      decoded["legacy_handshake"],
      "migration-prefix-plus-normalized-schema",
      "legacy handshake"
    )

    semantic_version!(decoded["minimum_reader"], "minimum reader")
    semantic_version!(decoded["minimum_writer"], "minimum writer")
    semantic_version!(decoded["sqlite_minimum"], "SQLite minimum")
    require_equal!(decoded["minimum_reader"], "0.1.0-dev", "minimum reader")
    require_equal!(decoded["minimum_writer"], "0.1.0-dev", "minimum writer")
    require_equal!(decoded["sqlite_minimum"], "3.51.3", "SQLite minimum")
    digest!(decoded["migration_set_sha256"], "migration-set digest")

    require_equal!(
      decoded["migration_set_sha256"],
      contract.migration_set_sha256,
      "migration-set sentinel"
    )

    migrations = migrations!(decoded["migrations"], contract)

    %__MODULE__{
      manifest_version: decoded["manifest_version"],
      contract: decoded["contract"],
      upstream_commit: decoded["upstream_commit"],
      application_ids: decoded["application_ids"],
      data_epoch: decoded["data_epoch"],
      minimum_reader: decoded["minimum_reader"],
      minimum_writer: decoded["minimum_writer"],
      sqlite_minimum: decoded["sqlite_minimum"],
      migration_set_sha256: decoded["migration_set_sha256"],
      legacy_handshake: decoded["legacy_handshake"],
      migrations: migrations
    }
  end

  defp decode!(_decoded), do: invalid!("manifest root must be an object")

  defp migrations!(migrations, contract)
       when is_list(migrations) and length(migrations) == contract.migration_count do
    entries = Enum.map(migrations, &entry!/1)
    versions = Enum.map(entries, & &1.version)

    unless versions == Enum.sort(versions) and versions == Enum.uniq(versions) do
      invalid!("migration versions must be strictly increasing")
    end

    unless migration_set_sha256(entries) == contract.migration_set_sha256 do
      invalid!("migration-set digest does not describe the entries")
    end

    first = hd(entries)
    last = List.last(entries)

    require_equal!(first.version, 20_260_820_000_001, "first migration version")

    require_equal!(
      first.filename,
      "20260820000001_create_swarm_code_schema.exs",
      "first migration filename"
    )

    require_equal!(
      first.source_sha256,
      "7b85670338191af007a196d8b2bf4f88bde6511bddbfb9a5efc691a8c6606f44",
      "first migration source sentinel"
    )

    require_equal!(last.version, contract.last_version, "last migration version")

    require_equal!(
      last.filename,
      contract.last_filename,
      "last migration filename"
    )

    require_equal!(
      last.source_sha256,
      contract.last_source_sha256,
      "last migration source sentinel"
    )

    require_equal!(last.schema_sha256, contract.final_schema_sha256, "final schema sentinel")

    require_equal!(
      Contract.lineage_sha256(entries),
      contract.lineage_sha256,
      "complete schema lineage"
    )

    entries
  end

  defp migrations!(_migrations, contract),
    do: invalid!("manifest must contain exactly #{contract.migration_count} migrations")

  defp entry!(entry) when is_map(entry) do
    exact_keys!(entry, @entry_keys, "migration")
    version = entry["version"]
    filename = entry["filename"]

    unless is_integer(version) and version >= 10_000_000_000_000 and version <= 99_999_999_999_999 do
      invalid!("migration version must be a 14-digit integer")
    end

    expected_prefix = Integer.to_string(version) <> "_"

    unless is_binary(filename) and String.starts_with?(filename, expected_prefix) and
             Regex.match?(~r/\A\d{14}_[a-z0-9_]+\.exs\z/, filename) do
      invalid!("migration filename must agree with its version")
    end

    digest!(entry["source_sha256"], "migration source digest")
    digest!(entry["schema_sha256"], "migration schema digest")
    require_equal!(entry["additive_desktop_readable"], true, "desktop readability flag")

    %Entry{
      version: version,
      filename: filename,
      source_sha256: entry["source_sha256"],
      schema_sha256: entry["schema_sha256"],
      additive_desktop_readable?: true
    }
  end

  defp entry!(_entry), do: invalid!("migration entry must be an object")

  defp exact_keys!(map, expected, label) do
    unless Enum.sort(Map.keys(map)) == Enum.sort(expected) do
      invalid!("#{label} keys do not match the contract")
    end
  end

  defp semantic_version!(value, label) when is_binary(value) do
    case Version.parse(value) do
      {:ok, parsed} ->
        unless to_string(parsed) == value,
          do: invalid!("#{label} must be canonical semantic version")

      :error ->
        invalid!("#{label} must be a semantic version")
    end
  end

  defp semantic_version!(_value, label), do: invalid!("#{label} must be a semantic version")

  defp digest!(value, label) do
    unless is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value) do
      invalid!("#{label} must be a lowercase SHA-256 digest")
    end
  end

  defp migration_set_sha256(entries) do
    entries
    |> Enum.map(fn entry ->
      [
        Integer.to_string(entry.version),
        0,
        entry.filename,
        0,
        entry.source_sha256,
        ?\n
      ]
    end)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp require_equal!(actual, expected, label) do
    unless actual == expected, do: invalid!("#{label} does not match the audited contract")
  end

  defp invalid!(message),
    do: raise(ArgumentError, "invalid desktop migration manifest: #{message}")
end
