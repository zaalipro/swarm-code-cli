defmodule SwarmCode.Daemon.Schema.Probe do
  @moduledoc false

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Platform.{BoundFile, PhysicalPath, SourceSnapshot}
  alias SwarmCode.Daemon.Schema.{Binding, SqliteQuery}
  alias SwarmCode.Daemon.StartupError

  @maximum_migrations SwarmCode.Daemon.Schema.Contract.maximum_migrations()
  @migration_sentinel_rows @maximum_migrations + 1
  @maximum_schema_rows 512
  @maximum_schema_bytes 4_194_304
  @private_file_mode 0o600

  @enforce_keys [
    :application_id,
    :migration_versions,
    :schema_sha256,
    :sqlite_version,
    :sqlite_source_id,
    :quick_check,
    :foreign_key_violations
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          application_id: non_neg_integer(),
          migration_versions: [pos_integer()],
          schema_sha256: String.t(),
          sqlite_version: String.t(),
          sqlite_source_id: String.t(),
          quick_check: [[term()]],
          foreign_key_violations: [[term()]]
        }

  @spec inspect(Path.t()) :: {:ok, t()} | {:error, StartupError.t()}
  def inspect(path) when is_binary(path) do
    case inspect_bound(path) do
      {:ok, %{probe: probe}} -> {:ok, probe}
      {:error, %StartupError{} = error} -> {:error, error}
      _other -> {:error, incompatible_error()}
    end
  end

  def inspect(_path), do: {:error, incompatible_error()}

  @doc "Inspect an owned coherent snapshot and return the original source binding."
  @spec inspect_bound(Path.t(), keyword()) ::
          {:ok, %{probe: t(), binding: Binding.t()}} | {:error, StartupError.t()}
  def inspect_bound(path, opts \\ [])

  def inspect_bound(path, opts) when is_binary(path) and is_list(opts) do
    if not valid_options?(opts),
      do: {:error, incompatible_error()},
      else: safe_inspect_bound(path, opts)
  end

  defp valid_options?(opts) do
    keys = Keyword.keys(opts)

    Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
      Enum.all?(keys, &(&1 in [:uid, :before_open, :probe_hook])) and
      (not Keyword.has_key?(opts, :uid) or (is_integer(opts[:uid]) and opts[:uid] >= 0)) and
      valid_hook_option?(opts, :before_open) and valid_hook_option?(opts, :probe_hook)
  end

  defp valid_hook_option?(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        true

      {:ok, function} ->
        Mix.env() == :test and (is_function(function, 1) or is_function(function, 2))
    end
  end

  @spec inspect_connection(term()) :: {:ok, t()} | {:error, StartupError.t()}
  def inspect_connection(conn) do
    try do
      with :ok <- execute(conn, "PRAGMA query_only=ON"),
           :ok <- execute(conn, "PRAGMA foreign_keys=ON"),
           [[1]] <- bounded_rows(conn, "PRAGMA query_only", [], 1),
           [[1]] <- bounded_rows(conn, "PRAGMA foreign_keys", [], 1) do
        {:ok, build_probe(conn)}
      else
        _other -> {:error, incompatible_error()}
      end
    rescue
      _error -> {:error, incompatible_error()}
    catch
      _kind, _reason -> {:error, incompatible_error()}
    end
  end

  defp safe_inspect_bound(path, opts) do
    uid = Keyword.get(opts, :uid) || trusted_uid()

    with {:ok, resolved} <- PhysicalPath.resolve_regular(path),
         {:ok, main_stat} <- regular_stat(resolved.path, uid),
         :ok <- BoundFile.same_object(main_stat, resolved.stat),
         {:ok, sidecars} <- sidecar_stats(resolved.path, uid),
         {:ok, parent_stat} <- File.lstat(Path.dirname(resolved.path)) do
      expected = %{
        main: main_stat,
        wal: sidecar_stat(sidecars, "-wal"),
        shm: sidecar_stat(sidecars, "-shm"),
        parent: parent_stat
      }

      SourceSnapshot.with_snapshot(
        resolved.path,
        uid,
        expected,
        fn snapshot_path ->
          with {:ok, probe} <-
                 SourceSnapshot.with_connection(snapshot_path, &inspect_connection/1),
               :ok <- invoke_probe_hook(Keyword.get(opts, :probe_hook), path),
               :ok <- verify_bound_paths_now(resolved.path, main_stat, sidecars, uid),
               :ok <- verify_bound_paths_now(path, main_stat, sidecars, uid) do
            binding = %Binding{
              path: path,
              identity: BoundFile.object_identity(main_stat),
              sidecars: sidecar_identity_map(sidecars)
            }

            {:ok, %{probe: probe, binding: binding}}
          end
        end,
        snapshot_options(opts, path, main_stat, sidecars)
      )
      |> normalize_snapshot_result()
    else
      {:error, %StartupError{} = error} -> {:error, error}
      _other -> {:error, incompatible_error()}
    end
  rescue
    _error -> {:error, incompatible_error()}
  catch
    _kind, _reason -> {:error, incompatible_error()}
  end

  defp sidecar_stat(sidecars, suffix) do
    case List.keyfind(sidecars, suffix, 0) do
      {^suffix, _path, stat} -> stat
      nil -> nil
    end
  end

  defp snapshot_options(opts, path, main_stat, sidecars) do
    case Keyword.get(opts, :before_open) do
      nil ->
        []

      hook ->
        binding = %{
          path: path,
          identity: BoundFile.object_identity(main_stat),
          sidecars: sidecars
        }

        [
          test_before_copy: fn _snapshot_path ->
            result =
              if is_function(hook, 2),
                do: hook.(:before_sqlite_open, path),
                else: hook.(binding)

            if result == :ok, do: :ok, else: {:error, incompatible_error()}
          end
        ]
    end
  end

  defp normalize_snapshot_result({:ok, %{probe: %__MODULE__{}, binding: %Binding{}}} = result),
    do: result

  defp normalize_snapshot_result({:error, %StartupError{}} = error), do: error

  defp normalize_snapshot_result({:error, :snapshot_cleanup_pending}) do
    {:error,
     StartupError.new(
       :cleanup_pending,
       true,
       "Schema snapshot cleanup is still pending.",
       "Keep the source directory private until the snapshot owner has finished cleanup."
     )}
  end

  defp normalize_snapshot_result(_result), do: {:error, incompatible_error()}

  defp trusted_uid do
    case System.cmd("/usr/bin/id", ["-u"], stderr_to_stdout: true) do
      {output, 0} when is_binary(output) and byte_size(output) <= 32 ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> uid
          _other -> nil
        end

      _other ->
        nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp regular_stat(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: actual_uid, mode: mode} = stat}
      when is_integer(uid) and actual_uid == uid and band(mode, 0o7777) == @private_file_mode ->
        {:ok, stat}

      _other ->
        {:error, incompatible_error()}
    end
  end

  defp sidecar_stats(path, uid) do
    Enum.reduce_while(["-wal", "-shm"], {:ok, []}, fn suffix, {:ok, acc} ->
      case File.lstat(path <> suffix) do
        {:error, :enoent} ->
          {:cont, {:ok, acc}}

        {:ok, %File.Stat{type: :regular, uid: actual_uid, mode: mode} = stat}
        when is_integer(uid) and actual_uid == uid and band(mode, 0o7777) == @private_file_mode ->
          {:cont, {:ok, [{suffix, path <> suffix, stat} | acc]}}

        _other ->
          {:halt, {:error, incompatible_error()}}
      end
    end)
  end

  @doc false
  @spec verify_bound_paths(Path.t(), Binding.t(), non_neg_integer()) ::
          :ok | {:error, StartupError.t()}
  def verify_bound_paths(path, %Binding{} = binding, uid)
      when is_binary(path) and is_integer(uid) do
    with {:ok, main_stat} <- regular_stat(path, uid),
         :ok <- BoundFile.same_object(main_stat, binding.identity),
         {:ok, sidecars} <- sidecar_stats(path, uid),
         :ok <- equal(sidecar_identity_map(sidecars), binding.sidecars) do
      :ok
    else
      _other -> {:error, incompatible_error()}
    end
  end

  def verify_bound_paths(_path, _binding, _uid), do: {:error, incompatible_error()}

  defp verify_bound_paths_now(path, main_stat, sidecars, uid) do
    with {:ok, current} <- regular_stat(path, uid),
         :ok <- BoundFile.same_object(current, main_stat),
         {:ok, current_sidecars} <- sidecar_stats(path, uid),
         :ok <- equal(sidecar_identity_map(current_sidecars), sidecar_identity_map(sidecars)) do
      :ok
    end
  end

  defp sidecar_identity_map(sidecars) do
    Map.new(sidecars, fn {suffix, _path, stat_or_identity} ->
      {suffix, BoundFile.object_identity(stat_or_identity)}
    end)
  end

  defp equal(value, value), do: :ok
  defp equal(_actual, _expected), do: {:error, incompatible_error()}

  defp invoke_probe_hook(nil, _path), do: :ok

  defp invoke_probe_hook(hook, path) when is_function(hook, 2) do
    case hook.(:after_probe, path) do
      :ok -> :ok
      _other -> {:error, incompatible_error()}
    end
  rescue
    _error -> {:error, incompatible_error()}
  catch
    _kind, _reason -> {:error, incompatible_error()}
  end

  defp invoke_probe_hook(hook, path) when is_function(hook, 1) do
    case hook.(path) do
      :ok -> :ok
      _other -> {:error, incompatible_error()}
    end
  rescue
    _error -> {:error, incompatible_error()}
  catch
    _kind, _reason -> {:error, incompatible_error()}
  end

  defp invoke_probe_hook(_hook, _path), do: :ok

  defp build_probe(conn) do
    [[application_id]] = bounded_rows(conn, "PRAGMA application_id", [], 1)

    migration_versions =
      bounded_rows(
        conn,
        "SELECT version FROM schema_migrations ORDER BY version LIMIT ?",
        [@migration_sentinel_rows],
        @migration_sentinel_rows
      )
      |> Enum.map(fn [version] when is_integer(version) -> version end)
      |> reject_migration_overflow!()

    [[sqlite_version, sqlite_source_id]] =
      bounded_rows(conn, "SELECT sqlite_version(), sqlite_source_id()", [], 1)

    %__MODULE__{
      application_id: application_id,
      migration_versions: migration_versions,
      schema_sha256: normalized_schema_sha256(conn),
      sqlite_version: sqlite_version,
      sqlite_source_id: sqlite_source_id,
      quick_check: bounded_rows(conn, "PRAGMA quick_check(1)", [], 1),
      foreign_key_violations:
        bounded_rows(conn, "SELECT 1 FROM pragma_foreign_key_check LIMIT 1", [], 1)
    }
  end

  defp normalized_schema_sha256(conn) do
    {hash_context, _encoded_bytes} =
      SqliteQuery.reduce(
        conn,
        """
        WITH bounded_schema AS (
          SELECT
            type,
            name,
            tbl_name,
            coalesce(sql, '') AS schema_sql,
            length(CAST(type AS BLOB)) +
              length(CAST(name AS BLOB)) +
              length(CAST(tbl_name AS BLOB)) +
              length(CAST(coalesce(sql, '') AS BLOB)) AS raw_bytes
          FROM sqlite_schema
          WHERE name NOT LIKE 'sqlite_%'
        )
        SELECT
          CASE WHEN raw_bytes <= ? THEN type END,
          CASE WHEN raw_bytes <= ? THEN name END,
          CASE WHEN raw_bytes <= ? THEN tbl_name END,
          CASE WHEN raw_bytes <= ? THEN schema_sql END,
          raw_bytes
        FROM bounded_schema
        ORDER BY type, name
        LIMIT 513
        """,
        List.duplicate(@maximum_schema_bytes, 4),
        {:crypto.hash_init(:sha256), 0},
        &hash_schema_row/2,
        max_rows: @maximum_schema_rows
      )

    hash_context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp hash_schema_row([nil, nil, nil, nil, _raw_bytes], _accumulator) do
    raise RuntimeError, "normalized schema byte limit exceeded"
  end

  defp hash_schema_row([type, name, table_name, schema_sql, _raw_bytes], accumulator) do
    Enum.reduce([type, name, table_name, schema_sql], accumulator, &hash_schema_field/2)
  end

  defp hash_schema_field(value, {hash_context, encoded_bytes}) do
    bytes = to_string(value)

    encoded_field =
      [Integer.to_string(byte_size(bytes)), ?:, bytes, ?\n]
      |> IO.iodata_to_binary()

    next_encoded_bytes = encoded_bytes + byte_size(encoded_field)

    if next_encoded_bytes > @maximum_schema_bytes do
      raise RuntimeError, "normalized schema byte limit exceeded"
    end

    {:crypto.hash_update(hash_context, encoded_field), next_encoded_bytes}
  end

  defp reject_migration_overflow!(versions) when length(versions) <= @maximum_migrations,
    do: versions

  defp reject_migration_overflow!(_versions),
    do: raise(RuntimeError, "migration row limit exceeded")

  defp bounded_rows(conn, sql, parameters, maximum_rows) do
    SqliteQuery.rows(conn, sql, parameters, max_rows: maximum_rows)
  end

  defp execute(conn, sql) do
    case Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, _reason} -> {:error, incompatible_error()}
    end
  end

  defp incompatible_error do
    StartupError.new(
      :schema_incompatible,
      false,
      "The canonical database could not pass the read-only schema probe.",
      "Use a supported SwarmCode version and restore only from a verified backup."
    )
  end
end
