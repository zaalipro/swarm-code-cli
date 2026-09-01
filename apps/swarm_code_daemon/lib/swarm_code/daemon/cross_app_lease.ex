defmodule SwarmCode.Daemon.CrossAppLease do
  @moduledoc false

  use GenServer

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord
  alias SwarmCode.Daemon.Files.AtomicReplace
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
    case GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:ok, server} = success ->
        Process.link(server)
        success

      {:error, _reason} = error ->
        error
    end
  end

  @spec owner(GenServer.server()) :: OwnerRecord.t()
  def owner(server), do: GenServer.call(server, :owner)

  @spec assert_held(GenServer.server()) :: :ok
  def assert_held(server), do: GenServer.call(server, :assert_held)

  @impl true
  def init(opts) do
    with :ok <- secure_lease_file(opts[:lease_path], opts[:identity].uid),
         {:ok, conn} <- open_and_acquire(opts[:lease_path]) do
      finish_init(conn, opts)
    else
      {:error, :busy} -> {:stop, held_error(opts[:owner_path])}
      {:error, reason} -> {:stop, lease_failed(reason)}
    end
  end

  @impl true
  def handle_call(:owner, _from, state), do: {:reply, state.record, state}

  @impl true
  def handle_call(:assert_held, _from, state), do: {:reply, :ok, state}

  @impl true
  def terminate(_reason, state) do
    close_connection(state.conn)
    remove_if_same_nonce(state.owner_path, state.record.lease_nonce)
    :ok
  end

  defp finish_init(conn, opts) do
    result =
      try do
        record = OwnerRecord.new(opts)
        contents = [Jason.encode_to_iodata!(OwnerRecord.to_map(record)), "\n"]

        case AtomicReplace.write(opts[:owner_path], contents, mode: @private_mode) do
          :ok -> {:ok, %{conn: conn, record: record, owner_path: opts[:owner_path]}}
          {:error, _reason} = error -> error
        end
      rescue
        error -> {:error, {:exception, error}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, _state} = success ->
        Process.flag(:trap_exit, true)
        success

      {:error, reason} ->
        close_connection(conn)
        {:stop, lease_failed(reason)}
    end
  end

  defp secure_lease_file(path, uid) do
    case File.lstat(path) do
      {:ok, stat} ->
        validate_lease_file(path, stat, uid)

      {:error, :enoent} ->
        case AtomicReplace.write(path, <<>>, mode: @private_mode, replace: false) do
          :ok -> validate_lease_path(path, uid)
          {:error, :eexist} -> validate_lease_path(path, uid)
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        unsafe_lease(path, reason)
    end
  end

  defp validate_lease_path(path, uid) do
    case File.lstat(path) do
      {:ok, stat} -> validate_lease_file(path, stat, uid)
      {:error, reason} -> unsafe_lease(path, reason)
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

  defp open_and_acquire(path) do
    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, conn} ->
        result =
          try do
            with :ok <- Sqlite3.set_busy_timeout(conn, 0),
                 :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON"),
                 :ok <- acquire_exclusive(conn),
                 :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=DELETE") do
              :ok
            end
          rescue
            error -> {:error, {:exception, error}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        case result do
          :ok ->
            {:ok, conn}

          {:error, _reason} = error ->
            close_connection(conn)
            error
        end

      {:error, _reason} = error ->
        error
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

  defp close_connection(conn) do
    try do
      _ = Sqlite3.execute(conn, "ROLLBACK")
    after
      _ = Sqlite3.close(conn)
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

  defp lease_failed(reason) do
    StartupError.new(
      :lease_failed,
      false,
      inspect(reason),
      "Inspect private path permissions and SQLite diagnostics."
    )
  end
end
