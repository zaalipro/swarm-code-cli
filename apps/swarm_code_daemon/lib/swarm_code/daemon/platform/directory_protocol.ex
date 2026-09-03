defmodule SwarmCode.Daemon.Platform.DirectoryProtocol do
  @moduledoc false

  alias SwarmCode.Daemon.Schema.Probe
  alias SwarmCode.Daemon.StartupError
  alias SwarmCode.Protocol.JsonLimits

  @maximum_bytes 1_048_576
  @maximum_basename_bytes 255
  @maximum_path_bytes 16 * 1_024
  @maximum_sources 3
  @maximum_payload_bytes @maximum_bytes - 4_096

  @error_atoms [
    :all_rowid_aliases_shadowed,
    :ambiguous_vacuum_sidecar,
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
    :unsupported_directory_operation,
    :directory_helper_cleanup_pending,
    :cleanup_pending
  ]

  @type decoder :: %{
          body: [binary()],
          collected: non_neg_integer(),
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
  def new_decoder, do: %{body: [], collected: 0, header: <<>>, remaining: nil}

  @spec collected_bytes(decoder()) :: non_neg_integer()
  def collected_bytes(%{collected: collected}) when is_integer(collected) and collected >= 0,
    do: collected

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

  @doc false
  @spec valid_request?(term()) :: boolean()
  def valid_request?(request), do: valid_request_shape?(request)

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
    with {:ok, wire} <- encode_term(term),
         document = %{"v" => 1, "kind" => "directory", "term" => wire},
         :ok <- JsonLimits.validate_term(document),
         {:ok, payload} <- Jason.encode_to_iodata(document, maps: :strict),
         size = IO.iodata_length(payload),
         true <- size in 1..@maximum_bytes//1 do
      {:ok, [<<size::unsigned-big-32>>, payload]}
    else
      _other -> {:error, :invalid_protocol}
    end
  rescue
    _error -> {:error, :invalid_protocol}
  catch
    _kind, _reason -> {:error, :invalid_protocol}
  end

  defp decode_and_validate(payload, validator)
       when is_binary(payload) and byte_size(payload) in 1..@maximum_bytes//1 do
    with {:ok, document} <- JsonLimits.decode(payload),
         :ok <- valid_document_shape(document),
         {:ok, term} <- decode_term(document["term"]),
         true <- validator.(term) do
      {:ok, term}
    else
      _other -> {:error, :invalid_protocol}
    end
  rescue
    _error -> {:error, :invalid_protocol}
  catch
    _kind, _reason -> {:error, :invalid_protocol}
  end

  defp decode_and_validate(_payload, _validator), do: {:error, :invalid_protocol}

  defp valid_document_shape(document) when is_map(document) do
    if Map.keys(document) |> Enum.sort() == ["kind", "term", "v"] and
         document["v"] == 1 and document["kind"] == "directory",
       do: :ok,
       else: {:error, :invalid_protocol}
  end

  defp valid_document_shape(_document), do: {:error, :invalid_protocol}

  # The broker's control channel is JSON too.  Terms are represented by a
  # closed tagged tree so no decoder path ever turns peer text into an atom.
  defp encode_term(value) when is_binary(value), do: {:ok, value}
  defp encode_term(value) when is_integer(value), do: {:ok, value}
  defp encode_term(value) when is_float(value) and value == value, do: {:ok, value}
  defp encode_term(value) when value in [nil, true, false], do: {:ok, value}

  defp encode_term(value) when is_atom(value) do
    if allowed_atom?(value),
      do: {:ok, %{"$type" => "atom", "value" => Atom.to_string(value)}},
      else: {:error, :invalid_protocol}
  end

  defp encode_term(%Probe{} = probe), do: encode_struct("probe", probe)
  defp encode_term(%StartupError{} = error), do: encode_struct("startup_error", error)

  defp encode_term(value) when is_tuple(value) do
    with {:ok, values} <- encode_list(Tuple.to_list(value)) do
      {:ok, %{"$type" => "tuple", "value" => values}}
    end
  end

  defp encode_term(value) when is_list(value) do
    with {:ok, values} <- encode_list(value) do
      {:ok, %{"$type" => "list", "value" => values}}
    end
  end

  defp encode_term(value) when is_map(value) do
    pairs = Map.to_list(value)

    with {:ok, encoded} <- encode_pairs(pairs) do
      {:ok, %{"$type" => "map", "value" => encoded}}
    end
  end

  defp encode_term(_value), do: {:error, :invalid_protocol}

  defp encode_struct(module, struct) do
    with {:ok, fields} <- encode_pairs(Map.to_list(Map.from_struct(struct))) do
      {:ok, %{"$type" => "struct", "module" => module, "value" => fields}}
    end
  end

  defp encode_list(values), do: encode_list(values, [])

  defp encode_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp encode_list([value | rest], acc) do
    with {:ok, encoded} <- encode_term(value), do: encode_list(rest, [encoded | acc])
  end

  defp encode_pairs(pairs), do: encode_pairs(pairs, [])

  defp encode_pairs([], acc), do: {:ok, Enum.reverse(acc)}

  defp encode_pairs([{key, value} | rest], acc) do
    with {:ok, encoded_key} <- encode_term(key),
         {:ok, encoded_value} <- encode_term(value) do
      encode_pairs(rest, [[encoded_key, encoded_value] | acc])
    end
  end

  defp decode_term(value) when is_binary(value), do: {:ok, value}
  defp decode_term(value) when is_integer(value), do: {:ok, value}
  defp decode_term(value) when is_float(value), do: {:ok, value}
  defp decode_term(value) when value in [nil, true, false], do: {:ok, value}

  defp decode_term(%{"$type" => "atom", "value" => value} = map)
       when map_size(map) == 2 and is_binary(value),
       do: decode_atom(value)

  defp decode_term(%{"$type" => "tuple", "value" => values} = map)
       when map_size(map) == 2 and is_list(values) do
    with {:ok, decoded} <- decode_list(values), do: {:ok, List.to_tuple(decoded)}
  end

  defp decode_term(%{"$type" => "list", "value" => values} = map)
       when map_size(map) == 2 and is_list(values),
       do: decode_list(values)

  defp decode_term(%{"$type" => "map", "value" => pairs} = map)
       when map_size(map) == 2 and is_list(pairs),
       do: decode_map(pairs)

  defp decode_term(%{"$type" => "struct", "module" => module, "value" => pairs} = map)
       when map_size(map) == 3 and is_binary(module) and is_list(pairs),
       do: decode_struct(module, pairs)

  defp decode_term(_value) do
    {:error, :invalid_protocol}
  end

  defp decode_list(values), do: decode_list(values, [])

  defp decode_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_list([value | rest], acc) do
    with {:ok, decoded} <- decode_term(value), do: decode_list(rest, [decoded | acc])
  end

  defp decode_map(pairs), do: decode_map(pairs, %{})

  defp decode_map([], acc), do: {:ok, acc}

  defp decode_map([[key, value] | rest], acc) do
    with {:ok, decoded_key} <- decode_term(key),
         true <- is_atom(decoded_key) or is_binary(decoded_key),
         false <- Map.has_key?(acc, decoded_key),
         {:ok, decoded_value} <- decode_term(value) do
      decode_map(rest, Map.put(acc, decoded_key, decoded_value))
    else
      _other -> {:error, :invalid_protocol}
    end
  end

  defp decode_map(_pairs, _acc), do: {:error, :invalid_protocol}

  defp decode_struct("probe", pairs) do
    with {:ok, fields} <- decode_map(pairs),
         true <-
           Enum.sort(Map.keys(fields)) == [
             :application_id,
             :foreign_key_violations,
             :migration_versions,
             :quick_check,
             :schema_sha256,
             :sqlite_source_id,
             :sqlite_version
           ],
         {:ok, probe} <- safe_probe(fields) do
      {:ok, probe}
    else
      _other -> {:error, :invalid_protocol}
    end
  end

  defp decode_struct("startup_error", pairs) do
    with {:ok, fields} <- decode_map(pairs),
         true <-
           Enum.sort(Map.keys(fields)) == [:__exception__, :action, :code, :message, :retryable],
         {:ok, error} <- safe_startup_error(fields) do
      {:ok, error}
    else
      _other -> {:error, :invalid_protocol}
    end
  end

  defp decode_struct(_module, _pairs), do: {:error, :invalid_protocol}

  defp safe_probe(fields) do
    probe = struct(Probe, fields)
    if probe?(probe), do: {:ok, probe}, else: {:error, :invalid_protocol}
  rescue
    _error -> {:error, :invalid_protocol}
  end

  defp safe_startup_error(fields) do
    error = struct(StartupError, fields)
    if startup_error?(error), do: {:ok, error}, else: {:error, :invalid_protocol}
  rescue
    _error -> {:error, :invalid_protocol}
  end

  defp allowed_atom?(value) do
    value in [
      :ok,
      :error,
      :ready,
      :none,
      :absent,
      :normal,
      :regular,
      :directory,
      :main,
      :wal,
      :shm,
      :cancel_copy,
      :close_source,
      :directory_identity,
      :finish_copy,
      :pwd,
      :stop,
      :sync_directory,
      :configure_sources,
      :link,
      :unlink,
      :link_source,
      :unlink_identity,
      :entry_state,
      :private_identity,
      :write_private,
      :read_private,
      :copy_private,
      :prepare_copy,
      :sync_file,
      :adopt,
      :commit,
      :repair_mode,
      :file_entry,
      :verify_database,
      :open_source,
      :vacuum,
      :operation_in_progress,
      :link_owned,
      :application_id,
      :foreign_key_violations,
      :migration_versions,
      :quick_check,
      :schema_sha256,
      :sqlite_source_id,
      :sqlite_version,
      :__exception__,
      :action,
      :code,
      :message,
      :retryable
    ] or value in @error_atoms or value in [:schema_incompatible, :backup_failed]
  end

  defp decode_atom("ok"), do: {:ok, :ok}
  defp decode_atom("error"), do: {:ok, :error}
  defp decode_atom("ready"), do: {:ok, :ready}
  defp decode_atom("none"), do: {:ok, :none}
  defp decode_atom("absent"), do: {:ok, :absent}
  defp decode_atom("normal"), do: {:ok, :normal}
  defp decode_atom("regular"), do: {:ok, :regular}
  defp decode_atom("directory"), do: {:ok, :directory}
  defp decode_atom("main"), do: {:ok, :main}
  defp decode_atom("wal"), do: {:ok, :wal}
  defp decode_atom("shm"), do: {:ok, :shm}
  defp decode_atom("cancel_copy"), do: {:ok, :cancel_copy}
  defp decode_atom("close_source"), do: {:ok, :close_source}
  defp decode_atom("directory_identity"), do: {:ok, :directory_identity}
  defp decode_atom("finish_copy"), do: {:ok, :finish_copy}
  defp decode_atom("pwd"), do: {:ok, :pwd}
  defp decode_atom("stop"), do: {:ok, :stop}
  defp decode_atom("sync_directory"), do: {:ok, :sync_directory}
  defp decode_atom("configure_sources"), do: {:ok, :configure_sources}
  defp decode_atom("link"), do: {:ok, :link}
  defp decode_atom("unlink"), do: {:ok, :unlink}
  defp decode_atom("link_source"), do: {:ok, :link_source}
  defp decode_atom("unlink_identity"), do: {:ok, :unlink_identity}
  defp decode_atom("entry_state"), do: {:ok, :entry_state}
  defp decode_atom("private_identity"), do: {:ok, :private_identity}
  defp decode_atom("write_private"), do: {:ok, :write_private}
  defp decode_atom("read_private"), do: {:ok, :read_private}
  defp decode_atom("copy_private"), do: {:ok, :copy_private}
  defp decode_atom("prepare_copy"), do: {:ok, :prepare_copy}
  defp decode_atom("sync_file"), do: {:ok, :sync_file}
  defp decode_atom("adopt"), do: {:ok, :adopt}
  defp decode_atom("commit"), do: {:ok, :commit}
  defp decode_atom("repair_mode"), do: {:ok, :repair_mode}
  defp decode_atom("file_entry"), do: {:ok, :file_entry}
  defp decode_atom("verify_database"), do: {:ok, :verify_database}
  defp decode_atom("open_source"), do: {:ok, :open_source}
  defp decode_atom("vacuum"), do: {:ok, :vacuum}
  defp decode_atom("link_owned"), do: {:ok, :link_owned}
  defp decode_atom("application_id"), do: {:ok, :application_id}
  defp decode_atom("foreign_key_violations"), do: {:ok, :foreign_key_violations}
  defp decode_atom("migration_versions"), do: {:ok, :migration_versions}
  defp decode_atom("quick_check"), do: {:ok, :quick_check}
  defp decode_atom("schema_sha256"), do: {:ok, :schema_sha256}
  defp decode_atom("sqlite_source_id"), do: {:ok, :sqlite_source_id}
  defp decode_atom("sqlite_version"), do: {:ok, :sqlite_version}
  defp decode_atom("__exception__"), do: {:ok, :__exception__}
  defp decode_atom("action"), do: {:ok, :action}
  defp decode_atom("code"), do: {:ok, :code}
  defp decode_atom("message"), do: {:ok, :message}
  defp decode_atom("retryable"), do: {:ok, :retryable}

  defp decode_atom("schema_incompatible"), do: {:ok, :schema_incompatible}
  defp decode_atom("backup_failed"), do: {:ok, :backup_failed}

  defp decode_atom(value), do: decode_error_atom(value)

  defp decode_error_atom(value) do
    case Enum.find(@error_atoms, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_protocol}
      atom -> {:ok, atom}
    end
  end

  defp push_header(%{remaining: nil, header: header} = decoder, bytes) do
    needed = 4 - byte_size(header)
    take = min(needed, byte_size(bytes))
    <<piece::binary-size(take), rest::binary>> = bytes
    header = <<header::binary, piece::binary>>

    if byte_size(header) < 4 do
      {:more, %{decoder | collected: decoder.collected + take, header: header}}
    else
      <<size::unsigned-big-32>> = header

      if size in 1..@maximum_bytes//1 do
        push_body(
          %{decoder | collected: decoder.collected + take, header: <<>>, remaining: size},
          rest
        )
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
      {:more,
       %{decoder | body: body, collected: decoder.collected + take, remaining: remaining - take}}
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

  defp valid_request_shape?(operation)
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

  defp valid_request_shape?({:configure_sources, sources}), do: source_paths?(sources)

  defp valid_request_shape?({operation, source, destination}) when operation == :link,
    do: safe_basename?(source) and safe_basename?(destination)

  defp valid_request_shape?({:link_owned, source, destination, uid}),
    do: safe_basename?(source) and safe_basename?(destination) and uid?(uid)

  defp valid_request_shape?({:unlink, basename}), do: safe_basename?(basename)

  defp valid_request_shape?({:link_source, index, destination}),
    do: index in 0..2 and safe_basename?(destination)

  defp valid_request_shape?({:unlink_identity, basename, identity}),
    do: safe_basename?(basename) and file_or_object_identity?(identity)

  defp valid_request_shape?({operation, basename, uid})
       when operation in [:entry_state, :private_identity],
       do: safe_basename?(basename) and uid?(uid)

  defp valid_request_shape?({:write_private, basename, contents, uid}),
    do:
      safe_basename?(basename) and is_binary(contents) and
        byte_size(contents) <= @maximum_payload_bytes and
        uid?(uid)

  defp valid_request_shape?({:read_private, basename, uid, maximum}),
    do:
      safe_basename?(basename) and uid?(uid) and is_integer(maximum) and
        maximum in 0..@maximum_payload_bytes//1

  defp valid_request_shape?({operation, source, destination, uid})
       when operation in [:copy_private, :prepare_copy],
       do: safe_basename?(source) and safe_basename?(destination) and uid?(uid)

  defp valid_request_shape?({:sync_file, basename, identity, uid}),
    do: safe_basename?(basename) and file_identity?(identity) and uid?(uid)

  defp valid_request_shape?({:adopt, basename, identity, uid}),
    do: safe_basename?(basename) and file_identity?(identity) and uid?(uid)

  defp valid_request_shape?({:commit, files, uid}),
    do:
      uid?(uid) and is_list(files) and length(files) in 1..2//1 and
        Enum.all?(files, fn
          {basename, identity} -> safe_basename?(basename) and file_identity?(identity)
          _other -> false
        end)

  defp valid_request_shape?({:repair_mode, 0o700, uid}), do: uid?(uid)

  defp valid_request_shape?({:file_entry, basename, uid, published_name}),
    do: safe_basename?(basename) and uid?(uid) and safe_basename?(published_name)

  defp valid_request_shape?({:verify_database, basename, probe}),
    do: safe_basename?(basename) and probe?(probe)

  defp valid_request_shape?({:open_source, specs, probe, uid}),
    do: uid?(uid) and source_specs?(specs) and probe?(probe)

  defp valid_request_shape?({:vacuum, destination, uid}),
    do: safe_basename?(destination) and uid?(uid)

  defp valid_request_shape?(_request), do: false

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
                   :write_private,
                   :link_owned
                 ]),
       do: file_identity?(identity)

  defp valid_reply?({:open_source, specs, _probe, _uid}, {:ok, identities}),
    do: source_identities?(identities, specs)

  defp valid_reply?({:file_entry, _basename, _uid, published}, {:ok, entry}),
    do: file_entry?(entry, published)

  defp valid_reply?({:verify_database, _basename, _probe}, {:ok, verification}),
    do: verification?(verification)

  defp valid_reply?({:entry_state, _basename, _uid}, :absent), do: true

  defp valid_reply?(operation, :ok)
       when operation in [
              :cancel_copy,
              :close_source,
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
      :unlink_identity,
      :link_owned
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
      name not in [".", ".."] and not String.contains?(name, [<<0>>, "\n", "\r"]) and
      Path.basename(name) == name
  end

  defp safe_source_basename?(_name), do: false

  defp safe_source_path?(path), do: safe_path?(path) and Path.type(path) == :absolute

  defp source_specs?(specs) do
    if is_list(specs) and length(specs) in 1..@maximum_sources//1 do
      kinds = Enum.map(specs, &source_kind/1)

      Enum.count(kinds, &(&1 == :main)) == 1 and kinds == Enum.uniq(kinds) and
        Enum.all?(specs, fn
          {kind, source, destination, identity} when kind in [:main, :wal, :shm] ->
            safe_source_path?(source) and safe_basename?(destination) and
              optional_file_identity?(identity) and
              (kind != :main or file_identity?(identity))

          _other ->
            false
        end)
    else
      false
    end
  end

  defp source_kind({kind, _source, _destination, _identity}) when kind in [:main, :wal, :shm],
    do: kind

  defp source_kind(_spec), do: nil

  defp source_identities?(identities, specs) when is_map(identities) and is_list(specs) do
    kinds = Enum.map(specs, &source_kind/1)

    Map.keys(identities) |> Enum.sort() == Enum.sort(kinds) and
      Enum.all?(kinds, fn
        :main -> file_identity?(identities[:main])
        kind when kind in [:wal, :shm] -> optional_file_identity?(identities[kind])
        _other -> false
      end)
  end

  defp source_identities?(_identities, _specs), do: false

  defp safe_basename?(name) when is_binary(name) do
    byte_size(name) in 1..@maximum_basename_bytes//1 and String.valid?(name) and
      name not in [".", ".."] and Regex.match?(~r/\A[.a-zA-Z0-9_-]+\z/, name) and
      Path.basename(name) == name
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
      error.__exception__ == true and
      error.code in [:backup_failed, :schema_incompatible, :cleanup_pending] and
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
