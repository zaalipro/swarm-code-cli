defmodule SwarmCode.Daemon.Platform.DirectoryBroker do
  @moduledoc false

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Backup.Gate
  alias SwarmCode.Daemon.Platform.DirectoryProtocol
  alias SwarmCode.Daemon.Schema.Probe

  @private_file_mode 0o600
  @chunk_bytes 1_024 * 1_024
  @test_build Mix.env() == :test

  @doc false
  def main do
    :ok = :io.setopts(:standard_io, [:binary, encoding: :latin1])
    _ = Application.ensure_all_started(:crypto)
    :ok = DirectoryProtocol.preload()
    :ok = configure_test_broker_fault()
    cancel_table = :ets.new(__MODULE__, [:set, :public])
    true = :ets.insert(cancel_table, {:cancelled, false})
    broker = self()
    _reader = spawn_link(fn -> read_loop(broker, cancel_table) end)
    write_ready({:ready, File.cwd!(), directory_identity(".")})

    state = %{
      cancel_table: cancel_table,
      copy: nil,
      operation: nil,
      owned: %{},
      source: nil,
      sources: []
    }

    try do
      loop(state)
    rescue
      _error ->
        cleanup_state(state)
        :init.stop(1)
    catch
      _kind, _reason ->
        cleanup_state(state)
        :init.stop(1)
    end
  catch
    _kind, _reason -> :init.stop(1)
  end

  defp loop(state) do
    receive do
      {:broker_packet, :stop} ->
        if Process.get({__MODULE__, :stall_stop}), do: loop(state), else: stop_broker(state)

      {:broker_packet, request} when is_nil(state.operation) ->
        loop(start_operation(request, state))

      {:broker_packet, request} ->
        write_reply(request, {:error, :operation_in_progress})
        loop(state)

      {:operation_reserve, worker, reserve_ref, basename, identity}
      when state.operation.pid == worker ->
        send(worker, {reserve_ref, :ok})
        loop(put_in(state, [:owned, basename], identity))

      {:operation_release, worker, release_ref, basename, identity}
      when state.operation.pid == worker ->
        send(worker, {release_ref, :ok})
        loop(release_operation_owned(state, basename, identity))

      {:vacuum_pre_step, worker, phase_ref} when state.operation.pid == worker ->
        if cancelled?(state.cancel_table) do
          send(worker, {phase_ref, {:error, :cancelled}})
          loop(state)
        else
          send(worker, {phase_ref, :ok})
          loop(put_in(state.operation[:phase], :stepping))
        end

      {:operation_result, worker, reply, next_state} when state.operation.pid == worker ->
        next_state = retain_copy_owner(state, worker, reply, next_state)

        if is_nil(next_state.copy) or next_state.copy.owner != worker do
          Process.demonitor(state.operation.monitor, [:flush])
        end

        next_state = merge_operation_state(state, next_state)

        case write_reply(state.operation.request, reply) do
          :ok -> loop(next_state)
          {:error, _reason} -> stop_broker(next_state)
        end

      {:DOWN, monitor, :process, worker, {:copy_operation_result, request, reply}}
      when state.operation.monitor == monitor and state.operation.pid == worker and
             state.operation.request == request and request in [:finish_copy, :cancel_copy] ->
        next_state = complete_copy_operation(state, request, reply)

        case write_reply(request, reply) do
          :ok -> loop(next_state)
          {:error, _reason} -> stop_broker(next_state)
        end

      {:DOWN, monitor, :process, worker, _reason}
      when state.operation.monitor == monitor and state.operation.pid == worker ->
        reply = {:error, :directory_operation_failed}
        next_state = operation_worker_down(state)

        case write_reply(state.operation.request, reply) do
          :ok -> loop(next_state)
          {:error, _reason} -> stop_broker(next_state)
        end

      {:DOWN, monitor, :process, worker, _reason}
      when state.copy.monitor == monitor and state.copy.owner == worker ->
        loop(cleanup_dead_copy(state))

      :broker_input_closed ->
        stop_broker(state)

      _other ->
        loop(state)
    end
  end

  defp start_operation(request, state) do
    case {request, state.copy} do
      {request, %{owner: owner, monitor: monitor}}
      when request in [:finish_copy, :cancel_copy] ->
        send(owner, {:copy_operation, request})

        %{
          state
          | operation: %{
              base_owned: state.owned,
              monitor: monitor,
              phase: :running,
              pid: owner,
              request: request
            }
        }

      _other ->
        spawn_operation(request, state)
    end
  end

  defp spawn_operation(request, state) do
    broker = self()
    base_owned = state.owned

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put({__MODULE__, :broker}, broker)
        Process.put({__MODULE__, :operation}, request)
        {reply, next_state} = safe_dispatch(request, state)
        send(broker, {:operation_result, self(), reply, next_state})

        if keep_copy_owner?(request, reply, next_state) do
          copy_owner_loop(next_state.copy, next_state.cancel_table)
        end
      end)

    %{
      state
      | operation: %{
          base_owned: base_owned,
          monitor: monitor,
          phase: :running,
          pid: worker,
          request: request
        }
    }
  end

  defp keep_copy_owner?({:prepare_copy, _source, _destination, _uid}, {:ok, _identity}, %{
         copy: copy
       }),
       do: is_map(copy)

  defp keep_copy_owner?(_request, _reply, _next_state), do: false

  defp retain_copy_owner(state, worker, reply, next_state) do
    if keep_copy_owner?(state.operation.request, reply, next_state) do
      copy = Map.merge(next_state.copy, %{monitor: state.operation.monitor, owner: worker})
      %{next_state | copy: copy}
    else
      next_state
    end
  end

  defp copy_owner_loop(copy, cancel_table) do
    receive do
      {:copy_operation, :finish_copy} ->
        if crash_copy_owner?(), do: exit(:injected_copy_owner_crash)
        reply = safe_finish_copy(copy, cancel_table)
        exit({:copy_operation_result, :finish_copy, reply})

      {:copy_operation, :cancel_copy} ->
        cleanup_copy_owner(copy)
        exit({:copy_operation_result, :cancel_copy, :ok})
    end
  end

  defp safe_finish_copy(copy, cancel_table) do
    finish_copy(copy, cancel_table)
  rescue
    _error -> {:error, :private_copy_failed}
  catch
    _kind, _reason -> {:error, :private_copy_failed}
  end

  defp cleanup_copy_owner(copy) do
    _ = File.close(copy.input)
    _ = File.close(copy.output)
    cleanup_created([{copy.destination, object_identity(copy.identity)}], copy.uid)
    :ok
  end

  defp complete_copy_operation(state, :finish_copy, {:ok, _identity}),
    do: %{state | copy: nil, operation: nil}

  defp complete_copy_operation(%{copy: copy} = state, _request, _reply) when is_map(copy) do
    state
    |> cleanup_dead_copy()
    |> Map.put(:operation, nil)
  end

  defp complete_copy_operation(state, _request, _reply),
    do: %{state | copy: nil, operation: nil}

  defp operation_worker_down(state) do
    worker = state.operation.pid

    state =
      if is_map(state.copy) and state.copy.owner == worker do
        cleanup_dead_copy(state)
      else
        state
      end

    %{state | operation: nil}
  end

  defp cleanup_dead_copy(state) do
    destination = state.copy.destination
    uid = state.copy.uid
    identity = object_identity(state.copy.identity)
    _ = repair_mode(0o700, uid)
    cleanup_created([{destination, identity}], uid)
    %{state | copy: nil}
  end

  defp merge_operation_state(live, next) do
    reservations = Map.drop(live.owned, Map.keys(live.operation.base_owned))
    %{next | operation: nil, owned: Map.merge(next.owned, reservations)}
  end

  defp reserve_owned(basename, identity) do
    case Process.get({__MODULE__, :broker}) do
      broker when is_pid(broker) ->
        reserve_ref = make_ref()
        send(broker, {:operation_reserve, self(), reserve_ref, basename, identity})

        receive do
          {^reserve_ref, result} -> result
        end

      _other ->
        {:error, :missing_cleanup_owner}
    end
  end

  defp release_owned(basename, identity) do
    case Process.get({__MODULE__, :broker}) do
      broker when is_pid(broker) ->
        release_ref = make_ref()
        send(broker, {:operation_release, self(), release_ref, basename, identity})

        receive do
          {^release_ref, result} -> result
        end

      _other ->
        {:error, :missing_cleanup_owner}
    end
  end

  defp release_operation_owned(state, basename, identity) do
    case Map.fetch(state.owned, basename) do
      {:ok, ^identity} -> update_in(state.owned, &Map.delete(&1, basename))
      _other -> state
    end
  end

  defp stop_broker(state) do
    state = cancel_operation(state)
    cleanup_state(state)
    write_reply(:stop, :ok)
    :init.stop(0)
  end

  defp cancel_operation(%{operation: nil} = state), do: state

  defp cancel_operation(state) do
    cancel_open_source(state.cancel_table)
    repeat_cancel? = vacuum_step_active?(state.operation)

    unless vacuum_operation?(state.operation.request) do
      Process.exit(state.operation.pid, :kill)
    end

    state =
      await_operation_down(
        state.operation.pid,
        state.operation.monitor,
        state,
        repeat_cancel?
      )

    state =
      if is_map(state.copy) and state.copy.owner == state.operation.pid do
        %{state | copy: nil}
      else
        state
      end

    %{state | operation: nil}
  end

  defp vacuum_operation?({:vacuum, _destination, _uid}), do: true
  defp vacuum_operation?(_request), do: false

  defp vacuum_step_active?(%{request: {:vacuum, _destination, _uid}, phase: :stepping}),
    do: true

  defp vacuum_step_active?(_operation), do: false

  defp await_operation_down(worker, monitor, state, repeat_cancel? \\ false) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        state

      {:operation_result, ^worker, _reply, _next_state} ->
        await_operation_down(worker, monitor, state, repeat_cancel?)

      {:operation_reserve, ^worker, reserve_ref, basename, identity} ->
        send(worker, {reserve_ref, {:error, :cancelled}})

        await_operation_down(
          worker,
          monitor,
          put_in(state.owned[basename], identity),
          repeat_cancel?
        )

      {:operation_release, ^worker, release_ref, basename, identity} ->
        send(worker, {release_ref, :ok})

        await_operation_down(
          worker,
          monitor,
          release_operation_owned(state, basename, identity),
          repeat_cancel?
        )

      {:vacuum_pre_step, ^worker, phase_ref} ->
        send(worker, {phase_ref, {:error, :cancelled}})
        await_operation_down(worker, monitor, state, repeat_cancel?)
    after
      if(repeat_cancel?, do: 1, else: :infinity) ->
        cancel_source_connection(state.cancel_table)
        await_operation_down(worker, monitor, state, repeat_cancel?)
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

    cancel_source_connection(table)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cancel_source_connection(table) do
    case :ets.lookup(table, :source_connection) do
      [{:source_connection, connection}] -> _ = Sqlite3.cancel(connection)
      [] -> :ok
    end

    :ok
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
    result =
      with {:ok, source_identity} <- file_identity(source),
           :ok <- File.ln(source, destination),
           :ok <- pause_before_reserve(:link, nil),
           :ok <- reserve_owned(destination, object_identity(source_identity)) do
        result =
          with {:ok, ^source_identity} <- file_identity(source),
               {:ok, ^source_identity} <- file_identity(destination),
               do: :ok

        if result != :ok,
          do:
            cleanup_created(
              [{destination, object_identity(source_identity)}],
              elem(source_identity, 4)
            )

        normalize_error(result, :directory_operation_failed)
      else
        _other -> {:error, :directory_operation_failed}
      end

    next_state =
      case {result, Map.fetch(state.owned, source)} do
        {:ok, {:ok, identity}} -> put_in(state, [:owned, destination], identity)
        _other -> state
      end

    {result, next_state}
  end

  # Link-and-reserve is one broker operation: the parent ledger is updated
  # only after this invocation has created and identity-checked the link.
  defp dispatch({:link_owned, source, destination, uid}, state) do
    result = link_owned(source, destination, uid)
    {result, track_result(state, destination, result)}
  end

  defp dispatch({:unlink, basename}, state) do
    result = normalize_ok(File.rm(basename))
    {result, if(result == :ok, do: drop_owned(state, basename), else: state)}
  end

  defp dispatch({:link_source, index, destination}, %{sources: sources} = state) do
    result =
      case Enum.fetch(sources, index) do
        {:ok, source} ->
          with {:ok, source_identity} <- file_identity(source),
               :ok <- File.ln(source, destination),
               :ok <- pause_before_reserve(:link_source, nil),
               :ok <- reserve_owned(destination, object_identity(source_identity)) do
            result =
              with {:ok, ^source_identity} <- file_identity(source),
                   {:ok, ^source_identity} <- file_identity(destination),
                   do: {:ok, source_identity}

            if not match?({:ok, _identity}, result),
              do:
                cleanup_created(
                  [{destination, object_identity(source_identity)}],
                  elem(source_identity, 4)
                )

            case result do
              {:ok, _identity} = success -> success
              _other -> {:error, :directory_operation_failed}
            end
          else
            _other -> {:error, :directory_operation_failed}
          end

        :error ->
          {:error, :invalid_source_index}
      end

    case result do
      {:ok, identity} -> {:ok, track_result(state, destination, {:ok, identity})}
      {:error, _reason} = error -> {error, state}
    end
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
    result = vacuum(connection, destination, uid, state.cancel_table)
    {result, state}
  end

  defp dispatch({:vacuum, _destination, _uid}, state), do: {{:error, :source_not_open}, state}

  defp dispatch(:close_source, %{source: nil} = state), do: {:ok, state}

  defp dispatch(:close_source, %{source: source} = state) do
    result = close_source(source)
    true = :ets.delete(state.cancel_table, :source_connection)
    {result, %{state | source: nil}}
  end

  defp dispatch(_request, state), do: {{:error, :unsupported_directory_operation}, state}

  # Backup.Gate supplies a coherent private SourceSnapshot. Copy every file into
  # independently broker-owned inodes before opening SQLite: snapshot cancellation
  # may unlink its workspace while our own receipt-bound copies remain valid.
  defp open_source(specs, expected_probe, uid, cancel_table)
       when is_list(specs) and length(specs) in 1..3//1 and is_integer(uid) and uid >= 0 do
    with :ok <- private_directory(uid),
         {:ok, identities, created} <- copy_source_specs(specs, uid, cancel_table),
         {:ok, main_basename} <- main_basename(specs) do
      open_copied_source(
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

  defp open_copied_source(
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

  defp copy_source_specs(specs, uid, cancel_table) do
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

        {kind, source, destination, expected}, {:ok, identities, created}
        when kind in [:main, :wal, :shm] and is_binary(source) and is_binary(destination) ->
          case copy_source_pin(source, destination, expected, uid, cancel_table, kind) do
            {:ok, actual_identity} ->
              {:cont,
               {:ok, Map.put(identities, kind, actual_identity),
                [{destination, object_identity(actual_identity)} | created]}}

            {:error, _reason} ->
              cleanup_created(created, uid)
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

  defp copy_source_pin(source, destination, expected, uid, cancel_table, kind) do
    with {:ok, input} <- File.open(source, [:read, :binary]) do
      try do
        with {:ok, ^expected} <- handle_identity(input),
             {:error, :enoent} <- File.lstat(destination),
             {:ok, output} <- File.open(destination, [:write, :binary, :exclusive]),
             :ok <- pause_before_reserve(kind, nil),
             {:ok, opened_identity} <- handle_identity(output),
             :ok <- reserve_owned(destination, object_identity(opened_identity)) do
          result =
            try do
              with :ok <- copy_chunks(input, output, cancel_table),
                   :ok <- :file.sync(output),
                   {:ok, actual} <- handle_identity(output),
                   {:regular, _major, _minor, _inode, ^uid, mode, _size} = actual,
                   true <- band(mode, 0o7777) == @private_file_mode,
                   {:ok, ^expected} <- handle_identity(input),
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

  defp vacuum(connection, destination, uid, cancel_table) do
    result =
      with :ok <- private_directory(uid),
           :ok <- paths_absent(destination) do
        with_reserved_vacuum_files(destination, uid, fn output, journal ->
          vacuum_into(connection, destination, uid, cancel_table, output, journal)
        end)
      else
        _other -> {:error, :snapshot_failed}
      end

    strict_after = private_directory(uid)
    _ = repair_mode(0o700, uid)
    sidecars = vacuum_sidecars_absent(destination)

    case {result, strict_after, sidecars} do
      {{:ok, identity}, :ok, :ok} ->
        {:ok, identity}

      _other ->
        {:error, :snapshot_failed}
    end
  end

  defp vacuum_into(connection, destination, uid, cancel_table, output, journal) do
    with false <- cancelled?(cancel_table),
         :ok <- verify_reserved_path(destination <> "-journal", journal.identity, false),
         :ok <- Sqlite3.set_busy_timeout(connection, 5_000),
         :ok <- Sqlite3.execute(connection, "PRAGMA query_only=OFF"),
         :ok <- Sqlite3.execute(connection, "PRAGMA foreign_keys=ON"),
         {:ok, statement} <- Sqlite3.prepare(connection, "VACUUM main INTO ?") do
      try do
        step = vacuum_step(connection, statement, destination, cancel_table)

        with :done <- step,
             :ok <- pause_after_vacuum_step(cancel_table),
             :ok <- verify_reserved_path(destination <> "-journal", journal.identity, true),
             {:ok, identity} <- secure_reserved_output(output, uid),
             true <- object_identity(identity) == object_identity(output.identity),
             :ok <- private_directory(uid) do
          {:ok, identity}
        else
          _other -> {:error, :snapshot_failed}
        end
      after
        _ = Sqlite3.release(connection, statement)
      end
    else
      _other -> {:error, :snapshot_failed}
    end
  end

  defp vacuum_step(connection, statement, destination, cancel_table) do
    with :ok <- Sqlite3.bind(statement, [destination]),
         :ok <- request_vacuum_step() do
      with :ok <- pause_before_vacuum_step(cancel_table) do
        Sqlite3.step(connection, statement)
      end
    else
      _other -> {:error, :snapshot_failed}
    end
  end

  defp request_vacuum_step do
    case Process.get({__MODULE__, :broker}) do
      broker when is_pid(broker) ->
        phase_ref = make_ref()
        send(broker, {:vacuum_pre_step, self(), phase_ref})

        receive do
          {^phase_ref, result} -> result
        end

      _other ->
        {:error, :missing_operation_owner}
    end
  end

  defp with_reserved_vacuum_files(destination, uid, function) when is_function(function, 2) do
    case open_reserved_empty_file(destination, uid) do
      {:ok, output} ->
        try do
          case open_reserved_empty_file(destination <> "-journal", uid) do
            {:ok, journal} ->
              try do
                result = function.(output, journal)

                with :ok <- verify_open_object(output),
                     :ok <- verify_open_object(journal),
                     :ok <- release_absent_journal(journal) do
                  result
                else
                  _other -> {:error, :snapshot_failed}
                end
              after
                _ = File.close(journal.io)
              end

            {:error, _reason} = error ->
              error
          end
        after
          _ = File.close(output.io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp open_reserved_empty_file(path, uid) do
    with {:error, :enoent} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      case reserve_open_empty_file(path, io, uid) do
        {:ok, identity} ->
          {:ok, %{identity: identity, io: io, path: path}}

        {:error, _reason} = error ->
          _ = File.close(io)
          error
      end
    else
      _other -> {:error, :snapshot_failed}
    end
  end

  defp reserve_open_empty_file(path, io, uid) do
    case handle_identity(io) do
      {:ok, identity} ->
        result =
          with {:regular, _major, _minor, _inode, ^uid, mode, 0} <- identity,
               true <- band(mode, 0o7777) == @private_file_mode,
               :ok <- reserve_owned(path, object_identity(identity)),
               {:ok, ^identity} <- private_identity(path, uid) do
            {:ok, identity}
          else
            _other -> {:error, :snapshot_failed}
          end

        if match?({:error, _reason}, result),
          do: cleanup_created([{path, object_identity(identity)}], uid)

        result

      _other ->
        {:error, :snapshot_failed}
    end
  end

  defp verify_open_object(%{identity: identity, io: io}) do
    case handle_identity(io) do
      {:ok, {:regular, _major, _minor, _inode, _uid, mode, _size} = actual} ->
        if object_identity(actual) == object_identity(identity) and
             band(mode, 0o7777) == @private_file_mode,
           do: :ok,
           else: {:error, :snapshot_failed}

      _other ->
        {:error, :snapshot_failed}
    end
  end

  defp release_absent_journal(%{identity: identity, path: path}) do
    case File.lstat(path) do
      {:error, :enoent} -> release_owned(path, object_identity(identity))
      _other -> :ok
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

  defp vacuum_sidecars_absent(destination) do
    Enum.reduce_while(["-journal", "-wal", "-shm"], :ok, fn suffix, :ok ->
      path = destination <> suffix

      case File.lstat(path) do
        {:error, :enoent} ->
          {:cont, :ok}

        _other ->
          {:halt, {:error, :ambiguous_vacuum_sidecar}}
      end
    end)
  end

  defp verify_reserved_path(path, expected_identity, allow_absent?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode} = stat} ->
        if object_identity(stat) == object_identity(expected_identity) and
             band(mode, 0o7777) == @private_file_mode,
           do: :ok,
           else: {:error, :ambiguous_vacuum_sidecar}

      {:error, :enoent} when allow_absent? ->
        :ok

      _other ->
        {:error, :ambiguous_vacuum_sidecar}
    end
  end

  defp cleanup_created(created, uid) do
    _ = repair_mode(0o700, uid)

    Enum.each(created, fn {path, expected_object} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, uid: ^uid} = stat} ->
          if object_identity(stat) == expected_object, do: File.rm(path)

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
    Process.exit(copy.owner, :kill)
    state = await_operation_down(copy.owner, copy.monitor, state)
    %{state | copy: nil}
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

  defp secure_reserved_output(%{path: path, io: io, identity: expected}, uid) do
    with {:ok, actual} <- handle_identity(io),
         {:regular, _major, _minor, _inode, ^uid, mode, _size} <- actual,
         true <- object_identity(actual) == object_identity(expected),
         true <- band(mode, 0o7777) == @private_file_mode,
         {:ok, ^actual} <- private_identity(path, uid) do
      {:ok, actual}
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
         :ok <- pause_before_reserve(:write_private, nil),
         {:ok, opened_identity} <- handle_identity(output),
         :ok <- reserve_owned(path, object_identity(opened_identity)) do
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
             {:ok, opened_identity} <- handle_identity(output),
             :ok <- reserve_owned(destination, object_identity(opened_identity)) do
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
    case handle_identity(output) do
      {:ok, identity} ->
        case reserve_owned(destination, object_identity(identity)) do
          :ok ->
            with {:regular, _major, _minor, _inode, ^uid, mode, 0} = identity,
                 true <- band(mode, 0o7777) == @private_file_mode,
                 {:ok, ^identity} <- private_identity(destination, uid) do
              {:ok, identity}
            else
              _other ->
                cleanup_created([{destination, object_identity(identity)}], uid)
                {:error, :private_copy_failed}
            end

          _other ->
            {:error, :private_copy_failed}
        end

      _other ->
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

  defp link_owned(source, destination, uid) do
    with :ok <- private_directory(uid),
         {:ok, source_identity} <- private_identity(source, uid),
         {:error, :enoent} <- File.lstat(destination) do
      case File.ln(source, destination) do
        :ok ->
          result =
            with {:ok, destination_identity} <- private_identity(destination, uid),
                 true <-
                   object_identity(destination_identity) == object_identity(source_identity),
                 :ok <- reserve_owned(destination, object_identity(destination_identity)),
                 {:ok, ^source_identity} <- private_identity(source, uid),
                 {:ok, ^destination_identity} <- private_identity(destination, uid) do
              {:ok, destination_identity}
            else
              _other -> {:error, :directory_operation_failed}
            end

          case result do
            {:ok, _identity} = success ->
              success

            {:error, _reason} = error ->
              cleanup_created([{destination, object_identity(source_identity)}], uid)
              error
          end

        {:error, _reason} ->
          {:error, :directory_operation_failed}
      end
    else
      _other ->
        {:error, :directory_operation_failed}
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
    with {:ok, payload} <- DirectoryProtocol.read_frame(&IO.binread(:stdio, &1)),
         {:ok, request} <- DirectoryProtocol.decode_request(payload) do
      {:ok, request}
    else
      _other -> {:error, :invalid_broker_packet}
    end
  end

  defp write_ready(ready) do
    case DirectoryProtocol.encode_ready(ready) do
      {:ok, frame} -> IO.binwrite(:stdio, frame)
      {:error, _reason} -> :init.stop(1)
    end
  end

  defp write_encoded_reply(operation, reply) do
    case DirectoryProtocol.encode_reply(operation, reply) do
      {:ok, frame} ->
        IO.binwrite(:stdio, frame)

      {:error, _reason} ->
        case DirectoryProtocol.encode_reply(operation, {:error, :helper_operation_failed}) do
          {:ok, frame} -> IO.binwrite(:stdio, frame)
          {:error, _reason} -> :ok
        end
    end
  end

  if @test_build do
    defp configure_test_broker_fault do
      fault =
        case System.get_env("SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT") do
          "extra_frame_write_private" -> :extra_frame_write_private
          "malformed_write_private" -> :malformed_write_private
          "oversized_write_private" -> :oversized_write_private
          "pause_link_before_reserve" -> :pause_link_before_reserve
          "pause_link_source_before_reserve" -> :pause_link_source_before_reserve
          "pause_shm_before_reserve" -> :pause_shm_before_reserve
          "pause_vacuum_after_step" -> :pause_vacuum_after_step
          "pause_vacuum_before_step" -> :pause_vacuum_before_step
          "pause_write_private_before_reserve" -> :pause_write_private_before_reserve
          "stall_stop" -> :stall_stop
          _other -> nil
        end

      Process.put({__MODULE__, :test_reply_fault}, fault)
      Process.put({__MODULE__, :stall_stop}, fault == :stall_stop)
      :ok
    end

    defp write_reply(operation, reply) do
      case take_test_reply_fault(operation) do
        :extra_frames ->
          case DirectoryProtocol.encode_reply(operation, reply) do
            {:ok, frame} ->
              extra = IO.iodata_to_binary(frame)
              IO.binwrite(:stdio, [extra, extra])

            {:error, _reason} ->
              :ok
          end

        :malformed ->
          IO.binwrite(:stdio, <<1::unsigned-big-32, 0>>)

        :oversized ->
          IO.binwrite(:stdio, <<DirectoryProtocol.maximum_bytes() + 1::unsigned-big-32>>)

        nil ->
          write_encoded_reply(operation, reply)
      end
    end

    defp take_test_reply_fault({:write_private, _basename, _contents, _uid}) do
      case Process.delete({__MODULE__, :test_reply_fault}) do
        :extra_frame_write_private -> :extra_frames
        :malformed_write_private -> :malformed
        :oversized_write_private -> :oversized
        _other -> nil
      end
    end

    defp take_test_reply_fault(_operation), do: nil

    defp crash_copy_owner?,
      do: System.get_env("SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT") == "crash_finish_copy"

    defp pause_before_reserve(kind, cancel_table) do
      fault =
        case System.get_env("SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT") do
          "pause_link_before_reserve" -> :pause_link_before_reserve
          "pause_link_source_before_reserve" -> :pause_link_source_before_reserve
          "pause_shm_before_reserve" -> :pause_shm_before_reserve
          "pause_write_private_before_reserve" -> :pause_write_private_before_reserve
          _other -> nil
        end

      operation = Process.get({__MODULE__, :operation})

      if pause_reservation?(fault, operation, kind) do
        await_test_reservation_continue(cancel_table)
      else
        :ok
      end
    end

    defp await_test_reservation_continue(cancel_table) do
      receive do
        :directory_broker_test_continue ->
          :ok
      after
        1 ->
          if not is_nil(cancel_table) and cancelled?(cancel_table),
            do: {:error, :cancelled},
            else: await_test_reservation_continue(cancel_table)
      end
    end

    defp pause_reservation?(:pause_link_before_reserve, {:link, _source, _destination}, :link),
      do: true

    defp pause_reservation?(
           :pause_link_source_before_reserve,
           {:link_source, _index, _destination},
           :link_source
         ),
         do: true

    defp pause_reservation?(
           :pause_shm_before_reserve,
           {:open_source, _specs, _probe, _uid},
           :shm
         ),
         do: true

    defp pause_reservation?(
           :pause_write_private_before_reserve,
           {:write_private, _basename, _contents, _uid},
           :write_private
         ),
         do: true

    defp pause_reservation?(_fault, _operation, _kind), do: false

    defp pause_after_vacuum_step(cancel_table) do
      if System.get_env("SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT") ==
           "pause_vacuum_after_step" do
        await_test_reservation_continue(cancel_table)
      else
        :ok
      end
    end

    defp pause_before_vacuum_step(cancel_table) do
      if System.get_env("SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT") ==
           "pause_vacuum_before_step" do
        await_test_vacuum_cancel(cancel_table)
      else
        :ok
      end
    end

    defp await_test_vacuum_cancel(cancel_table) do
      if cancelled?(cancel_table) do
        :ok
      else
        receive do
        after
          1 -> await_test_vacuum_cancel(cancel_table)
        end
      end
    end
  else
    defp configure_test_broker_fault, do: :ok
    defp write_reply(operation, reply), do: write_encoded_reply(operation, reply)
    defp crash_copy_owner?, do: false
    defp pause_before_reserve(_kind, _cancel_table), do: :ok
    defp pause_after_vacuum_step(_cancel_table), do: :ok
    defp pause_before_vacuum_step(_cancel_table), do: :ok
  end
end
