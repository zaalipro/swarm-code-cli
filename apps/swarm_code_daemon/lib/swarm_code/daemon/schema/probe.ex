defmodule SwarmCode.Daemon.Schema.Probe do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Schema.SqliteQuery
  alias SwarmCode.Daemon.StartupError

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
      inspect_connection(conn)
    end
  end

  def inspect(_path), do: {:error, incompatible_error()}

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

  defp inspect_connection(conn) do
    try do
      with :ok <- execute(conn, "PRAGMA query_only=ON"),
           :ok <- execute(conn, "PRAGMA foreign_keys=ON"),
           [[1]] <- SqliteQuery.rows(conn, "PRAGMA query_only", []),
           [[1]] <- SqliteQuery.rows(conn, "PRAGMA foreign_keys", []) do
        {:ok, build_probe(conn)}
      else
        _other -> {:error, incompatible_error()}
      end
    rescue
      _error -> {:error, incompatible_error()}
    catch
      _kind, _reason -> {:error, incompatible_error()}
    after
      _ = Sqlite3.close(conn)
    end
  end

  defp build_probe(conn) do
    [[application_id]] = SqliteQuery.rows(conn, "PRAGMA application_id", [])

    migration_versions =
      SqliteQuery.rows(conn, "SELECT version FROM schema_migrations ORDER BY version", [])
      |> Enum.map(fn [version] when is_integer(version) -> version end)

    [[sqlite_version, sqlite_source_id]] =
      SqliteQuery.rows(conn, "SELECT sqlite_version(), sqlite_source_id()", [])

    %__MODULE__{
      application_id: application_id,
      migration_versions: migration_versions,
      schema_sha256: normalized_schema_sha256(conn),
      sqlite_version: sqlite_version,
      sqlite_source_id: sqlite_source_id,
      quick_check: SqliteQuery.rows(conn, "PRAGMA quick_check", []),
      foreign_key_violations: SqliteQuery.rows(conn, "PRAGMA foreign_key_check", [])
    }
  end

  defp normalized_schema_sha256(conn) do
    rows =
      SqliteQuery.rows(
        conn,
        """
        SELECT type, name, tbl_name, coalesce(sql, '')
        FROM sqlite_schema
        WHERE name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """,
        []
      )

    schema_iodata =
      Enum.flat_map(rows, fn row ->
        Enum.map(row, fn value ->
          bytes = to_string(value)
          [Integer.to_string(byte_size(bytes)), ?:, bytes, ?\n]
        end)
      end)

    schema_iodata
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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
