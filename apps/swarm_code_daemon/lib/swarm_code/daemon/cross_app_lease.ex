defmodule SwarmCode.Daemon.CrossAppLease do
  @moduledoc false

  use GenServer

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord
  alias SwarmCode.Daemon.Files.AtomicReplace
  alias SwarmCode.Daemon.Platform.BoundFile
  alias SwarmCode.Daemon.Platform.ProcessIdentity
  alias SwarmCode.Daemon.StartupError

  @private_mode 0o600
  @maximum_owner_bytes 32 * 1_024

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      significant: true
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    startup_ref = make_ref()
    init_opts = Keyword.put(opts, :startup_reply, {self(), startup_ref})

    case GenServer.start_link(__MODULE__, init_opts, Keyword.take(opts, [:name])) do
      {:error, :normal} ->
        receive do
          {^startup_ref, %StartupError{} = error} -> {:error, error}
        end

      result ->
        result
    end
  end

  @spec owner(GenServer.server()) :: OwnerRecord.t()
  def owner(server), do: GenServer.call(server, :owner)

  @spec assert_held(GenServer.server()) :: :ok
  def assert_held(server), do: GenServer.call(server, :assert_held)

  @impl true
  def init(opts) do
    try do
      do_init(opts)
    rescue
      error -> stop_with_error(opts, lease_failed({:exception, error}))
    catch
      kind, reason -> stop_with_error(opts, lease_failed({kind, reason}))
    end
  end

  defp do_init(opts) do
    with :ok <- validate_options(opts),
         {:ok, uid} <- option_uid(opts),
         {:ok, binding} <- secure_lease_file(opts[:lease_path], uid),
         {:ok, connection_state} <- open_and_acquire(binding, opts) do
      finish_init(connection_state, opts)
    else
      {:error, :busy} -> stop_with_error(opts, held_error(opts[:owner_path]))
      {:error, reason} -> stop_with_error(opts, lease_failed(reason))
    end
  end

  @impl true
  def handle_call(:owner, _from, state), do: {:reply, state.record, state}

  @impl true
  def handle_call(:assert_held, _from, state) do
    case verify_bound_lease(state.connection_state.binding) do
      :ok ->
        {:reply, :ok, state}

      {:error, _reason} = error ->
        # The connection remains bound to the original inode, but the
        # canonical pathname is no longer the leased object.  Stop this owner
        # rather than allowing a second runtime to acquire the replacement.
        {:stop, :normal, error, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    result =
      try do
        remove_if_same_nonce(state.owner_path, state.record.lease_nonce)
        invoke_cleanup_barrier(state.cleanup_barrier)
      after
        BoundFile.close_sqlite(state.connection_state)
      end

    case result do
      :ok -> :ok
      {:error, :cleanup_barrier_failed} -> exit(:cleanup_barrier_failed)
    end
  end

  defp finish_init(connection_state, opts) do
    result =
      try do
        record = OwnerRecord.new(opts)
        contents = [Jason.encode_to_iodata!(OwnerRecord.to_map(record)), "\n"]

        atomic_opts =
          opts
          |> Keyword.get(:owner_atomic_replace_opts, [])
          |> Keyword.put(:mode, @private_mode)

        case AtomicReplace.write(opts[:owner_path], contents, atomic_opts) do
          :ok ->
            {:ok,
             %{
               conn: connection_state.connection,
               connection_state: connection_state,
               binding: connection_state.binding,
               record: record,
               owner_path: opts[:owner_path],
               cleanup_barrier: Keyword.get(opts, :cleanup_barrier, fn -> :ok end)
             }}

          {:error, {:post_publication, _reason}} = error ->
            remove_if_same_nonce(opts[:owner_path], record.lease_nonce)
            error

          {:error, _reason} = error ->
            error
        end
      rescue
        error -> {:error, {:exception, error}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, _state} = success ->
        success

      {:error, reason} ->
        BoundFile.close_sqlite(connection_state)
        stop_with_error(opts, lease_failed(reason))
    end
  end

  defp secure_lease_file(path, uid) do
    case File.lstat(path) do
      {:ok, stat} ->
        with :ok <- validate_lease_file(path, stat, uid),
             {:ok, sidecars} <- lease_sidecars(path, uid),
             {:ok, binding} <-
               BoundFile.open(path,
                 mode: :readwrite,
                 uid: uid,
                 expected: stat,
                 sidecars: sidecars
               ) do
          {:ok, binding}
        end

      {:error, :enoent} ->
        case AtomicReplace.write(path, <<>>, mode: @private_mode, replace: false) do
          :ok -> secure_lease_file(path, uid)
          {:error, {:pre_publication, :eexist}} -> secure_lease_file(path, uid)
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        unsafe_lease(path, reason)
    end
  end

  defp validate_lease_file(path, %File.Stat{type: :symlink}, _uid),
    do: unsafe_lease(path, :symlink)

  defp validate_lease_file(path, %File.Stat{type: type}, _uid) when type != :regular,
    do: unsafe_lease(path, :not_regular)

  defp validate_lease_file(path, %File.Stat{uid: actual_uid}, expected_uid)
       when actual_uid != expected_uid,
       do: unsafe_lease(path, :wrong_owner)

  defp validate_lease_file(path, %File.Stat{mode: mode}, _uid)
       when band(mode, 0o7777) != @private_mode,
       do: unsafe_lease(path, :permissions)

  defp validate_lease_file(_path, %File.Stat{}, _uid), do: :ok

  defp unsafe_lease(path, reason), do: {:error, {:unsafe_lease_file, path, reason}}

  defp lease_sidecars(path, uid) do
    Enum.reduce_while(["-wal", "-shm"], {:ok, []}, fn suffix, {:ok, acc} ->
      case File.lstat(path <> suffix) do
        {:error, :enoent} ->
          {:cont, {:ok, acc}}

        {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = stat}
        when band(mode, 0o7777) == @private_mode ->
          {:cont, {:ok, [{suffix, path <> suffix, stat} | acc]}}

        _other ->
          {:halt, {:error, {:unsafe_lease_file, path <> suffix, :sidecar}}}
      end
    end)
  end

  defp open_and_acquire(binding, opts) do
    hook = Keyword.get(opts, :test_open_hook)

    case BoundFile.open_sqlite_from_binding(binding,
           mode: :readwrite,
           uid: option_uid_value(opts),
           before_open: hook
         ) do
      {:ok, connection_state} ->
        conn = connection_state.connection

        result =
          try do
            with :ok <- Sqlite3.set_busy_timeout(conn, 0) do
              journal_result = set_and_verify_delete_journal(conn)
              foreign_keys_result = Sqlite3.execute(conn, "PRAGMA foreign_keys=ON")

              case acquire_exclusive(conn) do
                :ok ->
                  with :ok <- journal_result,
                       :ok <- foreign_keys_result,
                       :ok <- verify_bound_lease(binding) do
                    :ok
                  end

                {:error, _reason} = error ->
                  error
              end
            end
          rescue
            error -> {:error, {:exception, error}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        case result do
          :ok ->
            {:ok, connection_state}

          {:error, _reason} = error ->
            BoundFile.close_sqlite(connection_state)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp set_and_verify_delete_journal(conn) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "PRAGMA journal_mode=DELETE") do
      try do
        case Sqlite3.step(conn, statement) do
          {:row, ["delete"]} -> :ok
          {:row, [mode]} -> {:error, {:unexpected_journal_mode, mode}}
          :busy -> {:error, :journal_mode_busy}
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_journal_mode_result, other}}
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp acquire_exclusive(conn) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "BEGIN EXCLUSIVE") do
      try do
        case Sqlite3.step(conn, statement) do
          :done -> :ok
          :busy -> {:error, :busy}
          {:error, reason} -> {:error, reason}
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp verify_bound_lease(%{path: path, identity: identity}) do
    case File.lstat(path) do
      {:ok, stat} ->
        if BoundFile.object_identity(stat) == BoundFile.object_identity(identity),
          do: :ok,
          else: {:error, :lease_identity_changed}

      {:error, reason} ->
        {:error, {:lease_identity_changed, reason}}
    end
  end

  defp invoke_cleanup_barrier(function) when is_function(function, 0) do
    try do
      case function.() do
        :ok -> :ok
        _other -> {:error, :cleanup_barrier_failed}
      end
    rescue
      _error -> {:error, :cleanup_barrier_failed}
    catch
      _kind, _reason -> {:error, :cleanup_barrier_failed}
    end
  end

  defp invoke_cleanup_barrier(_function), do: {:error, :cleanup_barrier_failed}

  defp validate_options(opts) when is_list(opts) do
    keys = Keyword.keys(opts)

    allowed = [
      :lease_path,
      :owner_path,
      :identity,
      :database_fingerprint,
      :schema_contract,
      :socket_path,
      :app_version,
      :cleanup_barrier,
      :startup_reply,
      :name,
      :test_open_hook,
      :ipc_nonce,
      :owner_atomic_replace_opts
    ]

    required = [
      :lease_path,
      :owner_path,
      :identity,
      :database_fingerprint,
      :schema_contract,
      :socket_path,
      :app_version
    ]

    if Keyword.keyword?(opts) and keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in allowed)) and
         Enum.all?(required, &Keyword.has_key?(opts, &1)) and valid_boot_values?(opts) and
         (not Keyword.has_key?(opts, :test_open_hook) or Mix.env() == :test) and
         (not Keyword.has_key?(opts, :owner_atomic_replace_opts) or Mix.env() == :test),
       do: :ok,
       else: {:error, :invalid_lease_options}
  end

  defp validate_options(_opts), do: {:error, :invalid_lease_options}

  defp valid_boot_values?(opts) do
    identity = Keyword.get(opts, :identity)
    contract = Keyword.get(opts, :schema_contract)

    match?(%ProcessIdentity{}, identity) and
      valid_text_path?(Keyword.get(opts, :lease_path)) and
      valid_text_path?(Keyword.get(opts, :owner_path)) and
      valid_text_path?(Keyword.get(opts, :socket_path)) and
      valid_text?(Keyword.get(opts, :database_fingerprint), 4_096) and
      valid_text?(Keyword.get(opts, :app_version), 128) and
      is_map(contract) and
      Map.keys(contract) |> Enum.sort() == [:epoch, :manifest_sha256, :newest_migration] and
      is_integer(contract.epoch) and contract.epoch >= 0 and
      is_integer(contract.newest_migration) and contract.newest_migration > 0 and
      valid_text?(contract.manifest_sha256, 64) and valid_optional_values?(opts)
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp valid_optional_values?(opts) do
    valid_optional_function?(opts, :cleanup_barrier, 0) and
      valid_optional_function_arities?(opts, :test_open_hook, [1, 2]) and
      valid_optional_nonce?(opts) and valid_optional_startup_reply?(opts)
  end

  defp valid_optional_function?(opts, key, arity) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, function} -> is_function(function, arity)
    end
  end

  defp valid_optional_function_arities?(opts, key, arities) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, function} -> Enum.any?(arities, &is_function(function, &1))
    end
  end

  defp valid_optional_nonce?(opts) do
    case Keyword.fetch(opts, :ipc_nonce) do
      :error -> true
      {:ok, nonce} -> valid_text?(nonce, 4_096)
    end
  end

  defp valid_optional_startup_reply?(opts) do
    case Keyword.fetch(opts, :startup_reply) do
      :error -> true
      {:ok, {pid, ref}} -> is_pid(pid) and is_reference(ref)
      _other -> false
    end
  end

  defp valid_text_path?(path), do: valid_text?(path, 16 * 1_024) and Path.type(path) == :absolute

  defp valid_text?(value, maximum),
    do:
      is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
        not String.contains?(value, [<<0>>, "\n", "\r"])

  defp option_uid(opts) do
    case Keyword.get(opts, :identity) do
      %{uid: uid} when is_integer(uid) and uid >= 0 -> {:ok, uid}
      _other -> {:error, :invalid_identity}
    end
  end

  defp option_uid_value(opts) do
    case option_uid(opts) do
      {:ok, uid} -> uid
      _other -> -1
    end
  end

  defp remove_if_same_nonce(path, nonce) do
    with {:ok, contents} <- read_bounded(path),
         {:ok, %{"lease_nonce" => ^nonce}} <- Jason.decode(contents) do
      _ = File.rm(path)
    else
      _other -> :ok
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @maximum_owner_bytes + 1) do
            contents when is_binary(contents) and byte_size(contents) <= @maximum_owner_bytes ->
              {:ok, contents}

            _other ->
              {:error, :owner_record_too_large}
          end
        after
          _ = File.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp held_error(_owner_path) do
    StartupError.new(
      :data_lease_held,
      true,
      "The canonical data lease is held by another runtime.",
      "Stop the owning runtime; never delete or force-unlock the lease."
    )
  end

  defp stop_with_error(opts, %StartupError{} = error) do
    case Keyword.fetch(opts, :startup_reply) do
      {:ok, {caller, startup_ref}} -> send(caller, {startup_ref, error})
      :error -> :ok
    end

    {:stop, :normal}
  end

  defp lease_failed(reason) do
    StartupError.new(
      :lease_failed,
      false,
      inspect(reason),
      "Inspect private path permissions and SQLite diagnostics."
    )
  end
end
