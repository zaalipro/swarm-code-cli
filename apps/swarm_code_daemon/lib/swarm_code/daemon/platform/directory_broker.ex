defmodule SwarmCode.Daemon.Platform.DirectoryBroker do
  @moduledoc false

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Backup.Gate
  alias SwarmCode.Daemon.Schema.Probe

  @private_file_mode 0o600
  @chunk_bytes 1_024 * 1_024
  @maximum_packet_bytes 8 * 1_024 * 1_024

  @doc false
  def main do
    :ok = :io.setopts(:standard_io, [:binary, encoding: :latin1])
    _ = Application.ensure_all_started(:crypto)
    cancel_table = :ets.new(__MODULE__, [:set, :public])
    true = :ets.insert(cancel_table, {:cancelled, false})
    broker = self()
    _reader = spawn_link(fn -> read_loop(broker, cancel_table) end)
    write_packet({:ready, File.cwd!(), directory_identity(".")})
    loop(%{cancel_table: cancel_table, copy: nil, owned: %{}, source: nil, sources: []})
  catch
    _kind, _reason -> :init.stop(1)
  end

  defp loop(state) do
    receive do
      {:broker_packet, :stop} ->
        cleanup_state(state)
        write_packet(:ok)
        :init.stop(0)

      {:broker_packet, request} ->
        {reply, next_state} = safe_dispatch(request, state)
        write_packet(reply)
        loop(next_state)

      :broker_input_closed ->
        cleanup_state(state)
        :init.stop(0)

      _other ->
        loop(state)
    end
  end

  defp read_loop(broker, cancel_table) do
    case read_packet() do
      {:ok, request} ->
        if request == :stop, do: cancel_open_source(cancel_table)
        send(broker, {:broker_packet, request})
        read_loop(broker, cancel_table)

      {:error, _reason} ->
        cancel_open_source(cancel_table)
        send(broker, :broker_input_closed)
    end
  catch
    _kind, _reason ->
      cancel_open_source(cancel_table)
      send(broker, :broker_input_closed)
  end

  defp cancel_open_source(table) do
    true = :ets.insert(table, {:cancelled, true})

    case :ets.lookup(table, :source_connection) do
      [{:source_connection, connection}] -> _ = Sqlite3.cancel(connection)
      [] -> :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_dispatch(request, state) do
    dispatch(request, state)
  rescue
    _error -> {{:error, :directory_broker_failed}, state}
  catch
    _kind, _reason -> {{:error, :directory_broker_failed}, state}
  end

  defp dispatch(:pwd, state), do: {{:ok, File.cwd!()}, state}

  defp dispatch({:configure_sources, sources}, state) when is_list(sources),
    do: {:ok, %{state | sources: sources}}

  defp dispatch({:link, source, destination}, state) do
    result = normalize_ok(File.ln(source, destination))

    next_state =
      case {result, Map.fetch(state.owned, source)} do
        {:ok, {:ok, identity}} -> put_in(state, [:owned, destination], identity)
        _other -> state
      end

    {result, next_state}
  end

  defp dispatch({:unlink, basename}, state) do
    result = normalize_ok(File.rm(basename))
    {result, if(result == :ok, do: drop_owned(state, basename), else: state)}
  end

  defp dispatch({:link_source, index, destination}, %{sources: sources} = state) do
    result =
      case Enum.fetch(sources, index) do
        {:ok, source} -> normalize_ok(File.ln(source, destination))
        :error -> {:error, :invalid_source_index}
      end

    {result, state}
  end

  defp dispatch({:unlink_identity, basename, identity}, state) do
    result =
      with {:ok, actual} <- file_identity(basename),
           true <- identity_matches?(actual, identity),
           :ok <- File.rm(basename),
           do: :ok

    result = normalize_error(result, :file_identity_changed)
    {result, if(result == :ok, do: drop_owned(state, basename), else: state)}
  end

  defp dispatch({:private_identity, basename, uid}, state),
    do: {private_identity(basename, uid), state}

  defp dispatch({:write_private, basename, contents, uid}, state) do
    result = write_private(basename, contents, uid)
    {result, track_result(state, basename, result)}
  end

  defp dispatch({:read_private, basename, uid, maximum}, state),
    do: {read_private(basename, uid, maximum), state}

  defp dispatch({:copy_private, source, destination, uid}, state) do
    result = copy_private(source, destination, uid)
    {result, track_result(state, destination, result)}
  end

  defp dispatch({:prepare_copy, source, destination, uid}, %{copy: nil} = state) do
    case prepare_copy(source, destination, uid) do
      {:ok, copy} ->
        next_state =
          state
          |> Map.put(:copy, copy)
          |> put_in([:owned, destination], object_identity(copy.identity))

        {{:ok, copy.identity}, next_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp dispatch({:prepare_copy, _source, _destination, _uid}, state),
    do: {{:error, :copy_already_open}, state}

  defp dispatch(:finish_copy, %{copy: nil} = state), do: {{:error, :copy_not_open}, state}

  defp dispatch(:finish_copy, %{copy: copy} = state) do
    result = finish_copy(copy, state.cancel_table)
    next_state = %{state | copy: nil}

    {result,
     if(match?({:ok, _identity}, result),
       do: next_state,
       else: drop_owned(next_state, copy.destination)
     )}
  end

  defp dispatch(:cancel_copy, %{copy: nil} = state), do: {:ok, state}

  defp dispatch(:cancel_copy, state) do
    {:ok, cleanup_open_copy(state)}
  end

  defp dispatch({:sync_file, basename, identity, uid}, state),
    do: {sync_file(basename, identity, uid), state}

  defp dispatch({:adopt, basename, identity, uid}, state) do
    result =
      with {:ok, ^identity} <- private_identity(basename, uid), do: :ok

    {normalize_error(result, :file_identity_changed),
     if(result == :ok, do: drop_owned(state, basename), else: state)}
  end

  defp dispatch({:commit, files, uid}, state) when is_list(files) do
    result =
      Enum.reduce_while(files, :ok, fn {basename, identity}, :ok ->
        case private_identity(basename, uid) do
          {:ok, ^identity} -> {:cont, :ok}
          _other -> {:halt, {:error, :file_identity_changed}}
        end
      end)

    next_state =
      if result == :ok do
        Enum.reduce(files, state, fn {basename, _identity}, acc -> drop_owned(acc, basename) end)
      else
        state
      end

    {result, next_state}
  end

  defp dispatch(:sync_directory, state), do: {sync_directory(), state}

  defp dispatch({:repair_mode, mode, uid}, state), do: {repair_mode(mode, uid), state}
  defp dispatch(:directory_identity, state), do: {directory_identity("."), state}

  defp dispatch({:entry_state, basename, uid}, state) do
    result =
      case File.lstat(basename) do
        {:error, :enoent} -> :absent
        {:ok, _stat} -> private_identity(basename, uid)
        _other -> {:error, :unsafe_private_file}
      end

    {result, state}
  end

  defp dispatch({:file_entry, basename, uid, published_name}, state),
    do: {Gate.broker_file_entry(basename, uid, published_name), state}

  defp dispatch({:verify_database, basename, expected_probe}, state),
    do: {Gate.broker_verify_database(basename, expected_probe), state}

  defp dispatch({:open_source, specs, expected_probe, uid}, %{source: nil} = state) do
    case open_source(specs, expected_probe, uid, state.cancel_table) do
      {:ok, source} ->
        {{:ok, source.identities}, %{state | source: source}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp dispatch({:open_source, _specs, _expected_probe, _uid}, state),
    do: {{:error, :source_already_open}, state}

  defp dispatch({:vacuum, destination, uid}, %{source: %{connection: connection}} = state) do
    result = vacuum(connection, destination, uid)
    {result, track_result(state, destination, result)}
  end

  defp dispatch({:vacuum, _destination, _uid}, state), do: {{:error, :source_not_open}, state}

  defp dispatch(:close_source, %{source: nil} = state), do: {:ok, state}

  defp dispatch(:close_source, %{source: source} = state) do
    result = close_source(source)
    true = :ets.delete(state.cancel_table, :source_connection)
    {result, %{state | source: nil}}
  end

  defp dispatch(_request, state), do: {{:error, :unsupported_directory_operation}, state}

  defp open_source(specs, expected_probe, uid, cancel_table)
       when is_list(specs) and length(specs) in 1..3//1 and is_integer(uid) and uid >= 0 do
    with :ok <- private_directory(uid),
         {:ok, identities, created} <- link_source_specs(specs, uid),
         {:ok, main_basename} <- main_basename(specs) do
      open_linked_source(
        main_basename,
        identities,
        created,
        expected_probe,
        uid,
        cancel_table
      )
    else
      {:error, _reason} = error -> error
      _other -> {:error, :source_pin_failed}
    end
  end

  defp open_source(_specs, _expected_probe, _uid, _cancel_table),
    do: {:error, :source_pin_failed}

  defp open_linked_source(
         main_basename,
         identities,
         created,
         expected_probe,
         uid,
         cancel_table
       ) do
    result =
      with :ok <- protect_directory_for_source_open(uid),
           {:ok, connection} <- Sqlite3.open(main_basename, mode: :readonly) do
        true = :ets.insert(cancel_table, {:source_connection, connection})

        case source_connection_ready(connection, expected_probe) do
          :ok ->
            {:ok, %{connection: connection, created: created, identities: identities, uid: uid}}

          {:error, _reason} = error ->
            _ = Sqlite3.close(connection)
            true = :ets.delete(cancel_table, :source_connection)
            error
        end
      else
        {:error, _reason} = error -> error
        _other -> {:error, :source_pin_failed}
      end

    _ = repair_mode(0o700, uid)

    case result do
      {:ok, _source} = success ->
        success

      {:error, _reason} = error ->
        cleanup_created(created, uid)
        error
    end
  end

  defp link_source_specs(specs, uid) do
    result =
      Enum.reduce_while(specs, {:ok, %{}, []}, fn
        {kind, source, destination, nil}, {:ok, identities, created}
        when kind in [:wal, :shm] and is_binary(source) and is_binary(destination) ->
          case {File.lstat(source), File.lstat(destination)} do
            {{:error, :enoent}, {:error, :enoent}} ->
              {:cont, {:ok, Map.put(identities, kind, nil), created}}

            _other ->
              cleanup_created(created, uid)
              {:halt, {:error, :source_pin_failed}}
          end

        {:shm, source, destination, expected}, {:ok, identities, created}
        when is_binary(source) and is_binary(destination) ->
          case copy_source_pin(source, destination, expected, uid) do
            {:ok, actual_identity} ->
              {:cont,
               {:ok, Map.put(identities, :shm, expected),
                [{destination, object_identity(actual_identity)} | created]}}

            {:error, _reason} ->
              cleanup_created(created, uid)
              {:halt, {:error, :source_pin_failed}}
          end

        {kind, source, destination, expected}, {:ok, identities, created}
        when kind in [:main, :wal, :shm] and is_binary(source) and is_binary(destination) ->
          object = object_identity(expected)

          result = link_source_exact(source, destination, expected, uid)

          case result do
            :ok ->
              {:cont,
               {:ok, Map.put(identities, kind, expected), [{destination, object} | created]}}

            _other ->
              cleanup_created([{destination, object} | created], uid)
              {:halt, {:error, :source_pin_failed}}
          end

        _spec, {:ok, _identities, created} ->
          cleanup_created(created, uid)
          {:halt, {:error, :source_pin_failed}}
      end)

    ensure_private_shm_pin(result, specs, uid)
  end

  defp ensure_private_shm_pin({:ok, identities, created} = result, specs, uid) do
    if identities[:wal] && is_nil(identities[:shm]) do
      with {:ok, main} <- main_basename(specs),
           destination = main <> "-shm",
           {:ok, identity} <- write_private(destination, <<>>, uid) do
        {:ok, identities, [{destination, object_identity(identity)} | created]}
      else
        _other ->
          cleanup_created(created, uid)
          {:error, :source_pin_failed}
      end
    else
      result
    end
  end

  defp ensure_private_shm_pin(error, _specs, _uid), do: error

  defp link_source_exact(source, destination, expected, uid) do
    with {:error, :enoent} <- File.lstat(destination),
         :ok <- File.ln(source, destination) do
      case private_identity(destination, uid) do
        {:ok, ^expected} ->
          :ok

        {:ok, actual} ->
          _ = unlink_exact_local(destination, actual)
          {:error, :source_pin_failed}

        _other ->
          case file_identity(destination) do
            {:ok, actual} -> _ = unlink_exact_local(destination, actual)
            _other -> :ok
          end

          {:error, :source_pin_failed}
      end
    else
      _other -> {:error, :source_pin_failed}
    end
  end

  defp unlink_exact_local(path, expected) do
    with {:ok, ^expected} <- file_identity(path), do: File.rm(path)
  end

  defp copy_source_pin(source, destination, expected, uid) do
    with {:ok, input} <- File.open(source, [:read, :binary]) do
      try do
        with {:ok, ^expected} <- handle_identity(input),
             {:error, :enoent} <- File.lstat(destination),
             {:ok, output} <- File.open(destination, [:write, :binary, :exclusive]),
             {:ok, opened_identity} <- handle_identity(output) do
          result =
            try do
              with :ok <- copy_chunks(input, output),
                   :ok <- :file.sync(output),
                   {:ok, actual} <- handle_identity(output),
                   {:regular, _major, _minor, _inode, ^uid, mode, _size} = actual,
                   true <- band(mode, 0o7777) == @private_file_mode,
                   {:ok, ^expected} <- source_identity(source, uid) do
                {:ok, actual}
              else
                _other -> {:error, :source_pin_failed}
              end
            after
              _ = File.close(output)
            end

          cleanup_failed_creation(result, destination, opened_identity, uid)
        else
          _other -> {:error, :source_pin_failed}
        end
      after
        _ = File.close(input)
      end
    else
      _other -> {:error, :source_pin_failed}
    end
  end

  defp source_identity(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = stat}
      when band(mode, 0o7777) == @private_file_mode ->
        {:ok, stat_identity(stat)}

      _other ->
        {:error, :unsafe_source_file}
    end
  end

  defp main_basename(specs) do
    case Enum.find(specs, fn {kind, _source, _destination, _identity} -> kind == :main end) do
      {:main, _source, destination, _identity} -> {:ok, destination}
      nil -> {:error, :source_pin_failed}
    end
  end

  defp source_connection_ready(connection, expected_probe) do
    with :ok <- Sqlite3.set_busy_timeout(connection, 5_000),
         {:ok, probe} <- Probe.inspect_connection(connection),
         true <- probe == expected_probe do
      :ok
    else
      _other -> {:error, :source_pin_failed}
    end
  end

  defp close_source(source) do
    close_result = Sqlite3.close(source.connection)
    _ = repair_mode(0o700, source.uid)
    cleanup_created(source.created, source.uid)
    normalize_error(close_result, :source_close_failed)
  end

  defp vacuum(connection, destination, uid) do
    result =
      with :ok <- private_directory(uid),
           :ok <- paths_absent(destination),
           :ok <- Sqlite3.set_busy_timeout(connection, 5_000),
           :ok <- Sqlite3.execute(connection, "PRAGMA query_only=OFF"),
           :ok <- Sqlite3.execute(connection, "PRAGMA foreign_keys=ON"),
           {:ok, statement} <- Sqlite3.prepare(connection, "VACUUM main INTO ?") do
        step =
          try do
            with :ok <- Sqlite3.bind(statement, [destination]) do
              Sqlite3.step(connection, statement)
            end
          after
            _ = Sqlite3.release(connection, statement)
          end

        with :done <- step,
             {:ok, identity} <- secure_created_file(destination, uid),
             :ok <- private_directory(uid) do
          {:ok, identity}
        else
          _other -> {:error, :snapshot_failed}
        end
      else
        _other -> {:error, :snapshot_failed}
      end

    strict_after = private_directory(uid)
    _ = repair_mode(0o700, uid)
    sidecars = cleanup_sidecars(destination, uid)

    case {result, strict_after, sidecars} do
      {{:ok, identity}, :ok, :ok} ->
        {:ok, identity}

      _other ->
        cleanup_failed_vacuum_output(destination, uid)
        {:error, :snapshot_failed}
    end
  end

  defp paths_absent(destination) do
    Enum.reduce_while(["", "-journal", "-wal", "-shm"], :ok, fn suffix, :ok ->
      case File.lstat(destination <> suffix) do
        {:error, :enoent} -> {:cont, :ok}
        _other -> {:halt, {:error, :snapshot_path_exists}}
      end
    end)
  end

  defp cleanup_sidecars(destination, uid) do
    Enum.reduce_while(["-journal", "-wal", "-shm"], :ok, fn suffix, :ok ->
      path = destination <> suffix

      case File.lstat(path) do
        {:error, :enoent} ->
          {:cont, :ok}

        {:ok, %File.Stat{type: :regular, uid: ^uid}} ->
          case file_identity(path) do
            {:ok, identity} -> unlink_exact_local(path, identity)
            _other -> {:error, :sidecar_identity_failed}
          end
          |> case do
            :ok -> {:cont, :ok}
            _other -> {:halt, {:error, :sidecar_cleanup_failed}}
          end

        _other ->
          {:halt, {:error, :sidecar_cleanup_failed}}
      end
    end)
  end

  defp cleanup_failed_vacuum_output(destination, uid) do
    case File.lstat(destination) do
      {:ok, %File.Stat{type: :regular, uid: ^uid} = stat} ->
        cleanup_created([{destination, object_identity(stat)}], uid)

      _other ->
        :ok
    end
  end

  defp cleanup_created(created, uid) do
    Enum.each(created, fn {path, expected_object} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, uid: ^uid} = stat} ->
          if is_nil(expected_object) or object_identity(stat) == expected_object,
            do: File.rm(path)

        _other ->
          :ok
      end
    end)

    :ok
  end

  defp cleanup_state(state) do
    state = cleanup_open_copy(state)

    state =
      case state.source do
        nil ->
          state

        source ->
          true = :ets.delete(state.cancel_table, :source_connection)
          _ = close_source(source)
          %{state | source: nil}
      end

    uid =
      case directory_identity(".") do
        {:ok, {:directory, _major, _minor, _inode, uid, _mode}} -> uid
        _other -> nil
      end

    if is_integer(uid) do
      _ = repair_mode(0o700, uid)
      cleanup_created(cleanable_owned_files(state.owned), uid)
      _ = sync_directory()
    end

    :ok
  end

  defp cleanup_open_copy(%{copy: nil} = state), do: state

  defp cleanup_open_copy(%{copy: copy} = state) do
    _ = File.close(copy.input)
    _ = File.close(copy.output)
    cleanup_created([{copy.destination, object_identity(copy.identity)}], copy.uid)
    state |> Map.put(:copy, nil) |> drop_owned(copy.destination)
  end

  defp track_result(state, basename, {:ok, identity}) do
    put_in(state, [:owned, basename], object_identity(identity))
  end

  defp track_result(state, _basename, _result), do: state
  defp drop_owned(state, basename), do: update_in(state.owned, &Map.delete(&1, basename))

  defp cleanable_owned_files(owned) do
    Enum.reject(owned, fn {basename, _identity} -> committed_artifact_name?(basename) end)
  end

  defp committed_artifact_name?(basename) do
    cond do
      String.starts_with?(basename, ".") ->
        false

      String.ends_with?(basename, ".manifest.json") ->
        File.lstat(basename) != {:error, :enoent}

      String.ends_with?(basename, ".sqlite3") ->
        operation_id = Path.basename(basename, ".sqlite3")
        File.lstat(operation_id <> ".manifest.json") != {:error, :enoent}

      true ->
        false
    end
  end

  defp private_directory(uid) do
    case File.lstat(".") do
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}}
      when band(mode, 0o7777) == 0o700 ->
        :ok

      _other ->
        {:error, :unsafe_directory}
    end
  end

  defp protect_directory_for_source_open(uid) do
    with {:ok, %File.Stat{type: :directory, uid: ^uid}} <- File.lstat("."),
         :ok <- File.chmod(".", 0o500),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat("."),
         true <- band(mode, 0o7777) == 0o500 do
      :ok
    else
      _other -> {:error, :source_pin_failed}
    end
  end

  defp secure_created_file(path, uid) do
    with {:ok, %File.Stat{type: :regular, uid: ^uid} = before} <- File.lstat(path),
         :ok <- File.chmod(path, @private_file_mode),
         {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = after_chmod} <-
           File.lstat(path),
         true <- object_identity(before) == object_identity(after_chmod),
         true <- band(mode, 0o7777) == @private_file_mode do
      {:ok, stat_identity(after_chmod)}
    else
      _other -> {:error, :unsafe_created_file}
    end
  end

  defp object_identity({type, major, minor, inode, uid, _mode, _size}),
    do: {type, major, minor, inode, uid}

  defp object_identity(%File.Stat{} = stat),
    do: {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid}

  defp identity_matches?(identity, identity), do: true

  defp identity_matches?(
         {type, major, minor, inode, uid, _mode, _size},
         {type, major, minor, inode, uid}
       ),
       do: true

  defp identity_matches?(_actual, _expected), do: false

  defp write_private(path, contents, uid) when is_binary(contents) do
    with {:error, :enoent} <- File.lstat(path),
         {:ok, output} <- File.open(path, [:write, :binary, :exclusive]),
         {:ok, opened_identity} <- handle_identity(output) do
      result =
        try do
          with :ok <- IO.binwrite(output, contents),
               :ok <- :file.sync(output),
               {:ok, identity} <- handle_identity(output),
               {:regular, _major, _minor, _inode, ^uid, mode, _size} = identity,
               true <- band(mode, 0o7777) == @private_file_mode,
               {:ok, ^identity} <- private_identity(path, uid) do
            {:ok, identity}
          else
            _other -> {:error, :private_write_failed}
          end
        after
          _ = File.close(output)
        end

      cleanup_failed_creation(result, path, opened_identity, uid)
    else
      _other -> {:error, :private_write_failed}
    end
  end

  defp write_private(_path, _contents, _uid), do: {:error, :private_write_failed}

  defp read_private(path, uid, maximum) when is_integer(maximum) and maximum >= 0 do
    with {:ok, before} <- private_identity(path, uid),
         {:ok, input} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(input, maximum + 1) do
          bytes when is_binary(bytes) and byte_size(bytes) <= maximum ->
            case private_identity(path, uid) do
              {:ok, ^before} -> {:ok, bytes}
              _other -> {:error, :private_read_failed}
            end

          :eof ->
            {:ok, <<>>}

          _other ->
            {:error, :private_read_failed}
        end
      after
        _ = File.close(input)
      end
    else
      _other -> {:error, :private_read_failed}
    end
  end

  defp read_private(_path, _uid, _maximum), do: {:error, :private_read_failed}

  defp copy_private(source, destination, uid) do
    with {:error, :enoent} <- File.lstat(destination),
         {:ok, input} <- File.open(source, [:read, :binary]) do
      try do
        with {:ok, output} <- File.open(destination, [:write, :binary, :exclusive]),
             {:ok, opened_identity} <- handle_identity(output) do
          result =
            try do
              with :ok <- copy_chunks(input, output),
                   :ok <- :file.sync(output),
                   {:ok, identity} <- handle_identity(output),
                   {:regular, _major, _minor, _inode, ^uid, mode, _size} = identity,
                   true <- band(mode, 0o7777) == @private_file_mode,
                   {:ok, ^identity} <- private_identity(destination, uid) do
                {:ok, identity}
              else
                _other -> {:error, :private_copy_failed}
              end
            after
              _ = File.close(output)
            end

          cleanup_failed_creation(result, destination, opened_identity, uid)
        else
          _other -> {:error, :private_copy_failed}
        end
      after
        _ = File.close(input)
      end
    else
      _other -> {:error, :private_copy_failed}
    end
  end

  defp prepare_copy(source, destination, uid) do
    with {:error, :enoent} <- File.lstat(destination),
         {:ok, input} <- File.open(source, [:read, :binary]) do
      case File.open(destination, [:write, :binary, :exclusive]) do
        {:ok, output} ->
          case prepare_copy_output(input, output, destination, uid) do
            {:ok, identity} ->
              {:ok,
               %{
                 destination: destination,
                 identity: identity,
                 input: input,
                 output: output,
                 uid: uid
               }}

            {:error, _reason} = error ->
              _ = File.close(input)
              _ = File.close(output)
              error
          end

        {:error, _reason} ->
          _ = File.close(input)
          {:error, :private_copy_failed}
      end
    else
      _other -> {:error, :private_copy_failed}
    end
  end

  defp prepare_copy_output(_input, output, destination, uid) do
    with {:ok, identity} <- handle_identity(output),
         {:regular, _major, _minor, _inode, ^uid, mode, 0} = identity,
         true <- band(mode, 0o7777) == @private_file_mode,
         {:ok, ^identity} <- private_identity(destination, uid) do
      {:ok, identity}
    else
      _other ->
        case handle_identity(output) do
          {:ok, identity} -> cleanup_created([{destination, object_identity(identity)}], uid)
          _other -> :ok
        end

        {:error, :private_copy_failed}
    end
  end

  defp finish_copy(copy, cancel_table) do
    result =
      try do
        with :ok <- copy_chunks(copy.input, copy.output, cancel_table),
             :ok <- :file.sync(copy.output),
             {:ok, identity} <- handle_identity(copy.output),
             {:regular, _major, _minor, _inode, uid, mode, _size} = identity,
             true <- uid == copy.uid,
             true <- band(mode, 0o7777) == @private_file_mode,
             {:ok, ^identity} <- private_identity(copy.destination, copy.uid) do
          {:ok, identity}
        else
          _other -> {:error, :private_copy_failed}
        end
      after
        _ = File.close(copy.input)
        _ = File.close(copy.output)
      end

    case result do
      {:ok, _identity} = success ->
        success

      {:error, _reason} = error ->
        cleanup_created([{copy.destination, object_identity(copy.identity)}], copy.uid)
        error
    end
  end

  defp copy_chunks(input, output, cancel_table) do
    if cancelled?(cancel_table) do
      {:error, :private_copy_cancelled}
    else
      case IO.binread(input, @chunk_bytes) do
        :eof ->
          :ok

        bytes when is_binary(bytes) ->
          case IO.binwrite(output, bytes) do
            :ok -> copy_chunks(input, output, cancel_table)
            _other -> {:error, :private_copy_failed}
          end

        _other ->
          {:error, :private_copy_failed}
      end
    end
  end

  defp cancelled?(table), do: :ets.lookup(table, :cancelled) == [{:cancelled, true}]

  defp cleanup_failed_creation({:ok, _identity} = success, _path, _opened, _uid), do: success

  defp cleanup_failed_creation({:error, _reason} = error, path, opened, uid) do
    cleanup_created([{path, object_identity(opened)}], uid)
    error
  end

  defp copy_chunks(input, output) do
    case IO.binread(input, @chunk_bytes) do
      :eof ->
        :ok

      bytes when is_binary(bytes) ->
        case IO.binwrite(output, bytes) do
          :ok -> copy_chunks(input, output)
          _other -> {:error, :private_copy_failed}
        end

      _other ->
        {:error, :private_copy_failed}
    end
  end

  defp sync_file(path, expected, uid) do
    with {:ok, ^expected} <- private_identity(path, uid),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :raw]) do
      try do
        with {:ok, ^expected} <- handle_identity(io),
             :ok <- :file.sync(io),
             {:ok, ^expected} <- private_identity(path, uid) do
          :ok
        else
          _other -> {:error, :file_sync_failed}
        end
      after
        _ = :file.close(io)
      end
    else
      _other -> {:error, :file_sync_failed}
    end
  end

  defp sync_directory do
    case :file.open(~c".", [:read, :raw, :directory]) do
      {:ok, io} ->
        try do
          :file.sync(io)
        after
          _ = :file.close(io)
        end

      _other ->
        {:error, :directory_sync_failed}
    end
  end

  defp repair_mode(0o700, uid) do
    with {:ok, %File.Stat{type: :directory, uid: ^uid}} <- File.lstat("."),
         :ok <- File.chmod(".", 0o700),
         {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}} <- File.lstat("."),
         true <- band(mode, 0o7777) == 0o700 do
      :ok
    else
      _other -> {:error, :directory_mode_repair_failed}
    end
  end

  defp repair_mode(_mode, _uid), do: {:error, :directory_mode_repair_failed}

  defp private_identity(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = stat}
      when band(mode, 0o7777) == @private_file_mode ->
        {:ok, stat_identity(stat)}

      _other ->
        {:error, :unsafe_private_file}
    end
  end

  defp file_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat_identity(stat)}
      _other -> {:error, :unsafe_file}
    end
  end

  defp handle_identity(io) do
    case :file.read_file_info(io) do
      {:ok,
       {:file_info, size, :regular, _access, _atime, _mtime, _ctime, mode, _links, major, minor,
        inode, uid, _gid}} ->
        {:ok, {:regular, major, minor, inode, uid, mode, size}}

      _other ->
        {:error, :unsafe_open_file}
    end
  end

  defp directory_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {:directory, stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.mode}}

      _other ->
        {:error, :unsafe_directory}
    end
  end

  defp stat_identity(stat),
    do:
      {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.mode,
       stat.size}

  defp normalize_ok(:ok), do: :ok
  defp normalize_ok(_other), do: {:error, :directory_operation_failed}
  defp normalize_error(:ok, _error), do: :ok
  defp normalize_error(_other, error), do: {:error, error}

  defp read_packet do
    with <<size::unsigned-big-32>> <- IO.binread(:stdio, 4),
         true <- size in 1..@maximum_packet_bytes//1,
         payload when is_binary(payload) and byte_size(payload) == size <-
           IO.binread(:stdio, size) do
      {:ok, :erlang.binary_to_term(payload)}
    else
      _other -> {:error, :invalid_broker_packet}
    end
  end

  defp write_packet(term) do
    payload = :erlang.term_to_binary(term)
    IO.binwrite(:stdio, <<byte_size(payload)::unsigned-big-32, payload::binary>>)
  end
end
