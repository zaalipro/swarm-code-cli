defmodule SwarmCode.Daemon.Platform.DirectoryProtocol do
  @moduledoc false

  alias SwarmCode.Daemon.Schema.Probe
  alias SwarmCode.Daemon.StartupError

  @maximum_bytes 8 * 1_024 * 1_024
  @maximum_basename_bytes 255
  @maximum_path_bytes 16 * 1_024
  @maximum_sources 3

  @error_atoms [
    :all_rowid_aliases_shadowed,
    :ambiguous_artifact,
    :backup_cleanup_directory_changed,
    :backup_creation_failed,
    :backup_directory_changed,
    :backup_directory_helper_changed,
    :backup_directory_moved,
    :cancelled,
    :copy_already_open,
    :copy_not_open,
    :database_verification_failed,
    :directory_broker_failed,
    :directory_mode_repair_failed,
    :directory_operation_failed,
    :directory_sync_failed,
    :file_hash_failed,
    :file_identity_changed,
    :file_sync_failed,
    :helper_operation_failed,
    :invalid_manifest,
    :invalid_manifest_path,
    :invalid_source_index,
    :invalid_table_metadata,
    :invalid_table_name,
    :manifest_probe_mismatch,
    :manifest_read_failed,
    :manifest_too_large,
    :manifest_verification_mismatch,
    :missing_cleanup_owner,
    :mismatch,
    :no_tables,
    :operation_in_progress,
    :ownership_conflict,
    :private_copy_cancelled,
    :private_copy_failed,
    :private_read_failed,
    :private_write_failed,
    :publish_failed,
    :published_artifact_invalid,
    :restore_copy_failed,
    :rowid_proof_failed,
    :sidecar_cleanup_failed,
    :sidecar_identity_failed,
    :snapshot_failed,
    :snapshot_path_exists,
    :source_already_open,
    :source_close_failed,
    :source_not_open,
    :source_pin_failed,
    :table_verification_failed,
    :unsafe_backup_directory,
    :unsafe_backup_directory_handle,
    :unsafe_created_file,
    :unsafe_directory,
    :unsafe_file,
    :unsafe_open_file,
    :unsafe_private_file,
    :unsafe_source_file,
    :unsupported_directory_operation
  ]

  @type decoder :: %{
          body: [binary()],
          header: binary(),
          remaining: non_neg_integer() | nil
        }

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec preload() :: :ok
  def preload do
    {:module, Probe} = Code.ensure_loaded(Probe)
    {:module, StartupError} = Code.ensure_loaded(StartupError)
    :ok
  end

  @spec new_decoder() :: decoder()
  def new_decoder, do: %{body: [], header: <<>>, remaining: nil}

  @spec read_frame((pos_integer() -> binary() | :eof | {:error, term()})) ::
          {:ok, binary()} | {:error, :invalid_frame}
  def read_frame(reader) when is_function(reader, 1) do
    with {:ok, <<size::unsigned-big-32>>} <- read_exact(reader, 4, []),
         true <- size in 1..@maximum_bytes//1 do
      read_frame_body(reader, size, [])
    else
      _other -> {:error, :invalid_frame}
    end
  rescue
    _error -> {:error, :invalid_frame}
  catch
    _kind, _reason -> {:error, :invalid_frame}
  end

  def read_frame(_reader), do: {:error, :invalid_frame}

  @spec push(decoder(), binary()) ::
          {:more, decoder()} | {:ok, binary(), binary()} | {:error, :invalid_frame}
  def push(decoder, bytes) when is_map(decoder) and is_binary(bytes) do
    push_header(decoder, bytes)
  end

  def push(_decoder, _bytes), do: {:error, :invalid_frame}

  @spec encode_request(term()) :: {:ok, iodata()} | {:error, :invalid_protocol}
  def encode_request(request) do
    if valid_request?(request), do: encode(request), else: {:error, :invalid_protocol}
  end

  @spec encode_reply(term(), term()) :: {:ok, iodata()} | {:error, :invalid_protocol}
  def encode_reply(operation, reply) do
    if valid_reply?(operation, reply), do: encode(reply), else: {:error, :invalid_protocol}
  end

  @spec encode_ready(term()) :: {:ok, iodata()} | {:error, :invalid_protocol}
  def encode_ready({:ready, path, {:ok, identity}} = ready) do
    if safe_path?(path) and directory_identity?(identity),
      do: encode(ready),
      else: {:error, :invalid_protocol}
  end

  def encode_ready(_ready), do: {:error, :invalid_protocol}

  @spec decode_request(binary()) :: {:ok, term()} | {:error, :invalid_protocol}
  def decode_request(payload), do: decode_and_validate(payload, &valid_request?/1)

  @spec decode_reply(term(), binary()) :: {:ok, term()} | {:error, :invalid_protocol}
  def decode_reply(operation, payload) do
    decode_and_validate(payload, &valid_reply?(operation, &1))
  end

  @spec decode_ready(binary()) :: {:ok, term()} | {:error, :invalid_protocol}
  def decode_ready(payload) do
    decode_and_validate(payload, fn
      {:ready, path, {:ok, identity}} -> safe_path?(path) and directory_identity?(identity)
      _other -> false
    end)
  end

  defp encode(term) do
    payload = :erlang.term_to_binary(term, [:deterministic, {:minor_version, 2}])

    if byte_size(payload) in 1..@maximum_bytes//1 and not compressed?(payload) do
      {:ok, [<<byte_size(payload)::unsigned-big-32>>, payload]}
    else
      {:error, :invalid_protocol}
    end
  rescue
    _error -> {:error, :invalid_protocol}
  end

  defp decode_and_validate(payload, validator)
       when is_binary(payload) and byte_size(payload) in 1..@maximum_bytes//1 do
    if compressed?(payload) do
      {:error, :invalid_protocol}
    else
      try do
        term = :erlang.binary_to_term(payload, [:safe])
        if validator.(term), do: {:ok, term}, else: {:error, :invalid_protocol}
      rescue
        _error -> {:error, :invalid_protocol}
      end
    end
  end

  defp decode_and_validate(_payload, _validator), do: {:error, :invalid_protocol}

  defp compressed?(<<131, 80, _rest::binary>>), do: true
  defp compressed?(<<131, _rest::binary>>), do: false
  defp compressed?(_payload), do: true

  defp push_header(%{remaining: nil, header: header} = decoder, bytes) do
    needed = 4 - byte_size(header)
    take = min(needed, byte_size(bytes))
    <<piece::binary-size(take), rest::binary>> = bytes
    header = <<header::binary, piece::binary>>

    if byte_size(header) < 4 do
      {:more, %{decoder | header: header}}
    else
      <<size::unsigned-big-32>> = header

      if size in 1..@maximum_bytes//1 do
        push_body(%{decoder | header: <<>>, remaining: size}, rest)
      else
        {:error, :invalid_frame}
      end
    end
  end

  defp push_header(decoder, bytes), do: push_body(decoder, bytes)

  defp push_body(%{remaining: remaining} = decoder, bytes) when is_integer(remaining) do
    take = min(remaining, byte_size(bytes))
    <<piece::binary-size(take), rest::binary>> = bytes
    body = if take == 0, do: decoder.body, else: [piece | decoder.body]

    if take == remaining do
      {:ok, body |> Enum.reverse() |> IO.iodata_to_binary(), rest}
    else
      {:more, %{decoder | body: body, remaining: remaining - take}}
    end
  end

  defp read_frame_body(_reader, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_frame_body(reader, remaining, chunks) do
    amount = min(remaining, 64 * 1_024)

    case read_exact(reader, amount, []) do
      {:ok, bytes} -> read_frame_body(reader, remaining - amount, [bytes | chunks])
      {:error, :invalid_frame} = error -> error
    end
  end

  defp read_exact(_reader, 0, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_exact(reader, remaining, chunks) do
    case reader.(remaining) do
      bytes when is_binary(bytes) and byte_size(bytes) in 1..remaining//1 ->
        read_exact(reader, remaining - byte_size(bytes), [bytes | chunks])

      _other ->
        {:error, :invalid_frame}
    end
  end

  defp valid_request?(operation)
       when operation in [
              :cancel_copy,
              :close_source,
              :directory_identity,
              :finish_copy,
              :pwd,
              :stop,
              :sync_directory
            ],
       do: true

  defp valid_request?({:configure_sources, sources}), do: source_paths?(sources)

  defp valid_request?({operation, source, destination}) when operation == :link,
    do: safe_basename?(source) and safe_basename?(destination)

  defp valid_request?({:unlink, basename}), do: safe_basename?(basename)

  defp valid_request?({:link_source, index, destination}),
    do: index in 0..2 and safe_basename?(destination)

  defp valid_request?({:unlink_identity, basename, identity}),
    do: safe_basename?(basename) and file_or_object_identity?(identity)

  defp valid_request?({operation, basename, uid})
       when operation in [:entry_state, :private_identity],
       do: safe_basename?(basename) and uid?(uid)

  defp valid_request?({:write_private, basename, contents, uid}),
    do:
      safe_basename?(basename) and is_binary(contents) and
        byte_size(contents) <= 4 * 1_024 * 1_024 and
        uid?(uid)

  defp valid_request?({:read_private, basename, uid, maximum}),
    do:
      safe_basename?(basename) and uid?(uid) and is_integer(maximum) and
        maximum in 0..(4 * 1_024 * 1_024)//1

  defp valid_request?({operation, source, destination, uid})
       when operation in [:copy_private, :prepare_copy],
       do: safe_basename?(source) and safe_basename?(destination) and uid?(uid)

  defp valid_request?({:sync_file, basename, identity, uid}),
    do: safe_basename?(basename) and file_identity?(identity) and uid?(uid)

  defp valid_request?({:adopt, basename, identity, uid}),
    do: safe_basename?(basename) and file_identity?(identity) and uid?(uid)

  defp valid_request?({:commit, files, uid}),
    do:
      uid?(uid) and is_list(files) and length(files) in 1..2//1 and
        Enum.all?(files, fn
          {basename, identity} -> safe_basename?(basename) and file_identity?(identity)
          _other -> false
        end)

  defp valid_request?({:repair_mode, 0o700, uid}), do: uid?(uid)

  defp valid_request?({:file_entry, basename, uid, published_name}),
    do: safe_basename?(basename) and uid?(uid) and safe_basename?(published_name)

  defp valid_request?({:verify_database, basename, probe}),
    do: safe_basename?(basename) and probe?(probe)

  defp valid_request?({:open_source, specs, probe, uid}),
    do: uid?(uid) and source_specs?(specs) and probe?(probe)

  defp valid_request?({:vacuum, destination, uid}),
    do: safe_basename?(destination) and uid?(uid)

  defp valid_request?(_request), do: false

  defp valid_reply?(:pwd, {:ok, path}), do: safe_path?(path)

  defp valid_reply?({:read_private, _basename, _uid, maximum}, {:ok, contents}),
    do: is_binary(contents) and byte_size(contents) <= maximum

  defp valid_reply?(:directory_identity, {:ok, identity}), do: directory_identity?(identity)

  defp valid_reply?(operation, {:ok, identity})
       when operation == :finish_copy or
              (is_tuple(operation) and
                 elem(operation, 0) in [
                   :copy_private,
                   :entry_state,
                   :prepare_copy,
                   :private_identity,
                   :vacuum,
                   :write_private
                 ]),
       do: file_identity?(identity)

  defp valid_reply?({:open_source, _specs, _probe, _uid}, {:ok, identities}),
    do:
      is_map(identities) and Map.keys(identities) |> Enum.sort() == [:main, :shm, :wal] and
        file_identity?(identities.main) and optional_file_identity?(identities.wal) and
        optional_file_identity?(identities.shm)

  defp valid_reply?({:file_entry, _basename, _uid, published}, {:ok, entry}),
    do: file_entry?(entry, published)

  defp valid_reply?({:verify_database, _basename, _probe}, {:ok, verification}),
    do: verification?(verification)

  defp valid_reply?({:entry_state, _basename, _uid}, :absent), do: true

  defp valid_reply?(operation, :ok)
       when operation in [
              :cancel_copy,
              :close_source,
              :finish_copy,
              :stop,
              :sync_directory
            ],
       do: true

  defp valid_reply?({operation, _rest}, :ok) when operation in [:configure_sources, :unlink],
    do: true

  defp valid_reply?(operation, :ok) when is_tuple(operation) do
    elem(operation, 0) in [
      :adopt,
      :commit,
      :link,
      :link_source,
      :repair_mode,
      :sync_file,
      :unlink_identity
    ]
  end

  defp valid_reply?(_operation, {:error, %StartupError{} = error}), do: startup_error?(error)
  defp valid_reply?(_operation, {:error, reason}) when reason in @error_atoms, do: true
  defp valid_reply?(_operation, _reply), do: false

  defp source_paths?(sources),
    do:
      is_list(sources) and length(sources) <= @maximum_sources and
        Enum.all?(sources, &safe_source_basename?/1)

  defp safe_source_basename?(name) when is_binary(name) do
    byte_size(name) in 1..@maximum_basename_bytes//1 and String.valid?(name) and
      not String.contains?(name, [<<0>>, "\n", "\r"]) and Path.basename(name) == name
  end

  defp safe_source_basename?(_name), do: false

  defp source_specs?(specs) do
    is_list(specs) and length(specs) in 1..@maximum_sources//1 and
      Enum.count(specs, fn
        {:main, _source, _destination, _identity} -> true
        _other -> false
      end) == 1 and
      Enum.all?(specs, fn
        {kind, source, destination, identity} when kind in [:main, :wal, :shm] ->
          safe_path?(source) and safe_basename?(destination) and optional_file_identity?(identity) and
            (kind != :main or file_identity?(identity))

        _other ->
          false
      end)
  end

  defp safe_basename?(name) when is_binary(name) do
    byte_size(name) in 1..@maximum_basename_bytes//1 and String.valid?(name) and
      Regex.match?(~r/\A[.a-zA-Z0-9_-]+\z/, name) and Path.basename(name) == name
  end

  defp safe_basename?(_name), do: false

  defp safe_path?(path) when is_binary(path) do
    byte_size(path) in 1..@maximum_path_bytes//1 and String.valid?(path) and
      not String.contains?(path, [<<0>>, "\n", "\r"])
  end

  defp safe_path?(_path), do: false
  defp uid?(uid), do: is_integer(uid) and uid >= 0

  defp file_identity?({:regular, major, minor, inode, uid, mode, size}),
    do: nonnegative?([major, minor, inode, uid, mode, size])

  defp file_identity?(_identity), do: false

  defp file_or_object_identity?({:regular, major, minor, inode, uid}),
    do: nonnegative?([major, minor, inode, uid])

  defp file_or_object_identity?(identity), do: file_identity?(identity)
  defp optional_file_identity?(nil), do: true
  defp optional_file_identity?(identity), do: file_identity?(identity)

  defp directory_identity?({:directory, major, minor, inode, uid, mode}),
    do: nonnegative?([major, minor, inode, uid, mode])

  defp directory_identity?(_identity), do: false
  defp nonnegative?(values), do: Enum.all?(values, &(is_integer(&1) and &1 >= 0))

  defp probe?(%Probe{} = probe) do
    Map.keys(probe) |> Enum.sort() ==
      [
        :__struct__,
        :application_id,
        :foreign_key_violations,
        :migration_versions,
        :quick_check,
        :schema_sha256,
        :sqlite_source_id,
        :sqlite_version
      ] and
      is_integer(probe.application_id) and probe.application_id >= 0 and
      migration_versions?(probe.migration_versions) and sha256?(probe.schema_sha256) and
      bounded_text?(probe.sqlite_version, 128) and
      bounded_text?(probe.sqlite_source_id, 1_024) and probe_rows?(probe.quick_check) and
      probe_rows?(probe.foreign_key_violations)
  end

  defp probe?(_probe), do: false

  defp migration_versions?(versions) when is_list(versions) and length(versions) <= 43 do
    Enum.all?(versions, &(is_integer(&1) and &1 > 0)) and
      versions == Enum.sort(Enum.uniq(versions))
  end

  defp migration_versions?(_versions), do: false

  defp probe_rows?(rows) when is_list(rows) and length(rows) <= 1 do
    Enum.all?(rows, fn
      row when is_list(row) and length(row) <= 8 -> Enum.all?(row, &probe_value?/1)
      _other -> false
    end)
  end

  defp probe_rows?(_rows), do: false

  defp probe_value?(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: true

  defp probe_value?(value) when is_binary(value), do: bounded_text?(value, 4_096)
  defp probe_value?(_value), do: false

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp sha256?(_value), do: false

  defp startup_error?(%StartupError{} = error) do
    Map.keys(error) |> Enum.sort() ==
      [:__exception__, :__struct__, :action, :code, :message, :retryable] and
      error.__exception__ == true and error.code in [:backup_failed, :schema_incompatible] and
      is_boolean(error.retryable) and bounded_text?(error.message, 4_096) and
      bounded_text?(error.action, 4_096)
  end

  defp startup_error?(_error), do: false

  defp bounded_text?(value, maximum) when is_binary(value),
    do: byte_size(value) in 1..maximum//1 and String.valid?(value)

  defp bounded_text?(_value, _maximum), do: false

  defp file_entry?(entry, published) when is_map(entry) and map_size(entry) == 3 do
    Map.keys(entry) |> Enum.sort() == ["name", "sha256", "size"] and
      entry["name"] == published and sha256?(entry["sha256"]) and
      is_integer(entry["size"]) and entry["size"] >= 0
  end

  defp file_entry?(_entry, _published), do: false

  defp verification?(verification)
       when is_map(verification) and map_size(verification) == 9 do
    Map.keys(verification) |> Enum.sort() ==
      [
        "application_id",
        "foreign_key_violations",
        "migrations",
        "quick_check",
        "row_counts",
        "rowid_proofs",
        "schema_sha256",
        "sqlite_source_id",
        "sqlite_version"
      ] and
      is_integer(verification["application_id"]) and verification["application_id"] >= 0 and
      verification["foreign_key_violations"] == [] and
      migration_versions?(verification["migrations"]) and verification["quick_check"] == "ok" and
      row_counts?(verification["row_counts"]) and
      rowid_proofs?(verification["rowid_proofs"], verification["row_counts"]) and
      sha256?(verification["schema_sha256"]) and
      bounded_text?(verification["sqlite_source_id"], 1_024) and
      bounded_text?(verification["sqlite_version"], 128)
  end

  defp verification?(_verification), do: false

  defp row_counts?(counts) when is_map(counts) and map_size(counts) in 1..512//1 do
    Enum.all?(counts, fn {table, count} ->
      bounded_text?(table, 1_024) and is_integer(count) and count >= 0
    end)
  end

  defp row_counts?(_counts), do: false

  defp rowid_proofs?(proofs, counts)
       when is_map(proofs) and is_map(counts) and map_size(proofs) == map_size(counts) do
    Enum.sort(Map.keys(proofs)) == Enum.sort(Map.keys(counts)) and
      Enum.all?(counts, fn {table, count} -> rowid_proof?(proofs[table], count) end)
  end

  defp rowid_proofs?(_proofs, _counts), do: false

  defp rowid_proof?(proof, count) when is_map(proof) and map_size(proof) == 3 do
    Map.keys(proof) |> Enum.sort() ==
      ["count", "first_rowid_sha256", "last_rowid_sha256"] and
      proof["count"] == count and rowid_hashes?(proof, count)
  end

  defp rowid_proof?(_proof, _count), do: false

  defp rowid_hashes?(proof, 0),
    do: is_nil(proof["first_rowid_sha256"]) and is_nil(proof["last_rowid_sha256"])

  defp rowid_hashes?(proof, count) when is_integer(count) and count > 0,
    do: sha256?(proof["first_rowid_sha256"]) and sha256?(proof["last_rowid_sha256"])

  defp rowid_hashes?(_proof, _count), do: false
end
