defmodule SwarmCode.Daemon.Schema.Probe do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Schema.SqliteQuery
  alias SwarmCode.Daemon.StartupError

  @maximum_migrations 43
  @migration_sentinel_rows 44
  @maximum_schema_rows 512
  @maximum_schema_bytes 4_194_304

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
    with :ok <- regular_file(path),
         {:ok, conn} <- open_readonly(path) do
      try do
        inspect_connection(conn)
      after
        _ = Sqlite3.close(conn)
      end
    end
  end

  def inspect(_path), do: {:error, incompatible_error()}

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

  defp regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _other -> {:error, incompatible_error()}
    end
  end

  defp open_readonly(path) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> {:error, incompatible_error()}
    end
  end

  defp build_probe(conn) do
    [[application_id]] = bounded_rows(conn, "PRAGMA application_id", [], 1)

    migration_versions =
      bounded_rows(
        conn,
        "SELECT version FROM schema_migrations ORDER BY version LIMIT 44",
        [],
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
