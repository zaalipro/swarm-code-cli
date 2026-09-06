defmodule SwarmCode.Daemon.Backup.Manifest do
  @moduledoc false

  @maximum_bytes 4 * 1_024 * 1_024
  @maximum_tables 512
  @maximum_table_name_bytes 1_024
  @maximum_sqlite_text_bytes 4_096
  @maximum_migrations SwarmCode.Daemon.Schema.Contract.maximum_migrations()

  @keys ~w(
    application
    application_id
    backup
    foreign_key_violations
    independent_restore
    manifest_version
    migrations
    operation_id
    quick_check
    row_counts
    rowid_proofs
    schema_sha256
    source
    sqlite_source_id
    sqlite_version
    verified_at
  )
  @application_keys ~w(name version)
  @source_keys ~w(fingerprint main shm wal)
  @file_keys ~w(name sha256 size)

  @independent_restore_keys ~w(
    application_id
    backup_sha256
    foreign_key_violations
    migrations
    quick_check
    row_counts
    rowid_proofs
    schema_sha256
    sqlite_source_id
    sqlite_version
    verified
  )

  @rowid_proof_keys ~w(count first_rowid_sha256 last_rowid_sha256)

  @type t :: %{required(String.t()) => term()}

  @spec build(keyword()) :: t()
  def build(opts) when is_list(opts) do
    verification = Keyword.fetch!(opts, :verification)

    %{
      "manifest_version" => 1,
      "operation_id" => Keyword.fetch!(opts, :operation_id),
      "application" => %{
        "name" => "swarm_code_daemon",
        "version" => Keyword.fetch!(opts, :app_version)
      },
      "verified_at" => Keyword.fetch!(opts, :verified_at),
      "source" => Keyword.fetch!(opts, :source),
      "backup" => Keyword.fetch!(opts, :backup),
      "application_id" => verification["application_id"],
      "schema_sha256" => verification["schema_sha256"],
      "sqlite_version" => verification["sqlite_version"],
      "sqlite_source_id" => verification["sqlite_source_id"],
      "migrations" => verification["migrations"],
      "row_counts" => verification["row_counts"],
      "quick_check" => verification["quick_check"],
      "foreign_key_violations" => verification["foreign_key_violations"],
      "rowid_proofs" => verification["rowid_proofs"],
      "independent_restore" => Keyword.fetch!(opts, :independent_restore)
    }
  end

  @spec encode(t()) :: {:ok, iodata()} | {:error, term()}
  def encode(manifest) when is_map(manifest) do
    with :ok <- validate(manifest),
         {:ok, encoded} <- Jason.encode_to_iodata(manifest),
         true <- IO.iodata_length(encoded) + 1 <= @maximum_bytes do
      {:ok, [encoded, "\n"]}
    else
      false -> {:error, :manifest_too_large}
      {:error, _reason} = error -> error
    end
  end

  def encode(_manifest), do: {:error, :invalid_manifest}

  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, contents} <- read_bounded(path),
         {:ok, decoded} <- Jason.decode(contents),
         :ok <- validate(decoded) do
      {:ok, decoded}
    end
  end

  def read(_path), do: {:error, :invalid_manifest_path}

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(contents) when is_binary(contents) and byte_size(contents) <= @maximum_bytes do
    with {:ok, decoded} <- Jason.decode(contents),
         :ok <- validate(decoded) do
      {:ok, decoded}
    end
  end

  def decode(_contents), do: {:error, :invalid_manifest}

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(manifest) when is_map(manifest) do
    with :ok <- exact_keys(manifest, @keys),
         :ok <- equal(manifest["manifest_version"], 1),
         :ok <- uuid(manifest["operation_id"]),
         :ok <- application(manifest["application"]),
         :ok <- utc_timestamp(manifest["verified_at"]),
         :ok <- source(manifest["source"]),
         :ok <- file_entry(manifest["backup"]),
         :ok <- nonnegative_integer(manifest["application_id"]),
         :ok <- digest(manifest["schema_sha256"]),
         :ok <- bounded_string(manifest["sqlite_version"], @maximum_sqlite_text_bytes),
         :ok <- bounded_string(manifest["sqlite_source_id"], @maximum_sqlite_text_bytes),
         :ok <- migrations(manifest["migrations"]),
         :ok <- row_counts(manifest["row_counts"]),
         :ok <- equal(manifest["quick_check"], "ok"),
         :ok <- equal(manifest["foreign_key_violations"], []),
         :ok <- rowid_proofs(manifest["rowid_proofs"], manifest["row_counts"]),
         :ok <- independent_restore(manifest["independent_restore"]),
         :ok <- independent_equality(manifest) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_manifest}
    end
  end

  def validate(_manifest), do: {:error, :invalid_manifest}

  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @maximum_bytes + 1) do
            contents when is_binary(contents) and byte_size(contents) <= @maximum_bytes ->
              {:ok, contents}

            contents when is_binary(contents) ->
              {:error, :manifest_too_large}

            :eof ->
              {:ok, <<>>}

            {:error, reason} ->
              {:error, {:manifest_read_failed, reason}}
          end
        after
          _ = File.close(io)
        end

      {:error, reason} ->
        {:error, {:manifest_open_failed, reason}}
    end
  end

  defp application(application) when is_map(application) do
    with :ok <- exact_keys(application, @application_keys),
         :ok <- equal(application["name"], "swarm_code_daemon"),
         :ok <- bounded_string(application["version"], 128),
         {:ok, parsed} <- Version.parse(application["version"]),
         true <- to_string(parsed) == application["version"] do
      :ok
    else
      _other -> {:error, :invalid_manifest}
    end
  end

  defp application(_application), do: {:error, :invalid_manifest}

  defp source(source) when is_map(source) do
    with :ok <- exact_keys(source, @source_keys),
         :ok <- fingerprint(source["fingerprint"]),
         :ok <- file_entry(source["main"]),
         :ok <- optional_file_entry(source["wal"]),
         :ok <- optional_file_entry(source["shm"]) do
      :ok
    end
  end

  defp source(_source), do: {:error, :invalid_manifest}

  defp optional_file_entry(nil), do: :ok
  defp optional_file_entry(entry), do: file_entry(entry)

  defp file_entry(entry) when is_map(entry) do
    with :ok <- exact_keys(entry, @file_keys),
         :ok <- safe_basename(entry["name"]),
         :ok <- nonnegative_integer(entry["size"]),
         :ok <- digest(entry["sha256"]) do
      :ok
    end
  end

  defp file_entry(_entry), do: {:error, :invalid_manifest}

  defp safe_basename(name) when is_binary(name) and byte_size(name) in 1..1_024 do
    if Path.basename(name) == name and name not in [".", ".."],
      do: :ok,
      else: {:error, :invalid_manifest}
  end

  defp safe_basename(_name), do: {:error, :invalid_manifest}

  defp migrations(values) when is_list(values) and length(values) <= @maximum_migrations do
    if values != [] and values == Enum.sort(values) and values == Enum.uniq(values) and
         Enum.all?(values, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, :invalid_manifest}
    end
  end

  defp migrations(_values), do: {:error, :invalid_manifest}

  defp row_counts(counts) when is_map(counts) and map_size(counts) <= @maximum_tables do
    if map_size(counts) > 0 and
         Enum.all?(counts, fn {name, count} ->
           valid_table_name?(name) and is_integer(count) and count >= 0
         end) do
      :ok
    else
      {:error, :invalid_manifest}
    end
  end

  defp row_counts(_counts), do: {:error, :invalid_manifest}

  defp rowid_proofs(proofs, counts)
       when is_map(proofs) and is_map(counts) and map_size(proofs) <= @maximum_tables do
    if Map.keys(proofs) |> Enum.sort() == Map.keys(counts) |> Enum.sort() and
         Enum.all?(proofs, fn {table, proof} -> rowid_proof?(proof, counts[table]) end) do
      :ok
    else
      {:error, :invalid_manifest}
    end
  end

  defp rowid_proofs(_proofs, _counts), do: {:error, :invalid_manifest}

  defp rowid_proof?(proof, count) when is_map(proof) and is_integer(count) and count >= 0 do
    exact_keys(proof, @rowid_proof_keys) == :ok and proof["count"] == count and
      if count == 0 do
        is_nil(proof["first_rowid_sha256"]) and is_nil(proof["last_rowid_sha256"])
      else
        digest(proof["first_rowid_sha256"]) == :ok and
          digest(proof["last_rowid_sha256"]) == :ok
      end
  end

  defp rowid_proof?(_proof, _count), do: false

  defp independent_restore(restore) when is_map(restore) do
    with :ok <- exact_keys(restore, @independent_restore_keys),
         :ok <- equal(restore["verified"], true),
         :ok <- digest(restore["backup_sha256"]),
         :ok <- nonnegative_integer(restore["application_id"]),
         :ok <- digest(restore["schema_sha256"]),
         :ok <- bounded_string(restore["sqlite_version"], @maximum_sqlite_text_bytes),
         :ok <- bounded_string(restore["sqlite_source_id"], @maximum_sqlite_text_bytes),
         :ok <- migrations(restore["migrations"]),
         :ok <- row_counts(restore["row_counts"]),
         :ok <- equal(restore["quick_check"], "ok"),
         :ok <- equal(restore["foreign_key_violations"], []),
         :ok <- rowid_proofs(restore["rowid_proofs"], restore["row_counts"]) do
      :ok
    end
  end

  defp independent_restore(_restore), do: {:error, :invalid_manifest}

  defp independent_equality(manifest) do
    expected = %{
      "verified" => true,
      "backup_sha256" => manifest["backup"]["sha256"],
      "application_id" => manifest["application_id"],
      "schema_sha256" => manifest["schema_sha256"],
      "sqlite_version" => manifest["sqlite_version"],
      "sqlite_source_id" => manifest["sqlite_source_id"],
      "migrations" => manifest["migrations"],
      "row_counts" => manifest["row_counts"],
      "quick_check" => manifest["quick_check"],
      "foreign_key_violations" => manifest["foreign_key_violations"],
      "rowid_proofs" => manifest["rowid_proofs"]
    }

    equal(manifest["independent_restore"], expected)
  end

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_manifest}
  end

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> :ok
      _other -> {:error, :invalid_manifest}
    end
  end

  defp uuid(_value), do: {:error, :invalid_manifest}

  defp utc_timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} ->
        if DateTime.to_iso8601(datetime) == value,
          do: :ok,
          else: {:error, :invalid_manifest}

      _other ->
        {:error, :invalid_manifest}
    end
  end

  defp utc_timestamp(_value), do: {:error, :invalid_manifest}

  defp fingerprint("sqlite-file-v1:" <> digest), do: digest(digest)
  defp fingerprint(_fingerprint), do: {:error, :invalid_manifest}

  defp digest(value) when is_binary(value) and byte_size(value) == 64 do
    if value =~ ~r/\A[0-9a-f]{64}\z/,
      do: :ok,
      else: {:error, :invalid_manifest}
  end

  defp digest(_value), do: {:error, :invalid_manifest}

  defp bounded_string(value, maximum)
       when is_binary(value) and byte_size(value) in 1..maximum//1,
       do: :ok

  defp bounded_string(_value, _maximum), do: {:error, :invalid_manifest}

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative_integer(_value), do: {:error, :invalid_manifest}

  defp valid_table_name?(name),
    do: is_binary(name) and byte_size(name) in 1..@maximum_table_name_bytes

  defp equal(value, value), do: :ok
  defp equal(_actual, _expected), do: {:error, :invalid_manifest}
end
