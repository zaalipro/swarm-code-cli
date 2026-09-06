defmodule SchemaFixture do
  @moduledoc false

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Schema.SqliteQuery

  @maximum_tables 512

  @spec database!(:current | {:prefix, integer()}) :: Path.t()
  def database!(lineage, base \\ System.tmp_dir!()) do
    directory =
      Path.join(
        base,
        "swarm-code-schema-fixture-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}"
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)

    database = Path.join(directory, "fixture.db")
    File.write!(database, <<>>, [:exclusive])
    File.chmod!(database, 0o600)
    exec!(database, File.read!(fixture_path(lineage)))
    database
  end

  @spec insert_migration!(Path.t(), integer()) :: :ok
  def insert_migration!(database, version) when is_integer(version) do
    exec!(database, "INSERT INTO schema_migrations(version, inserted_at) VALUES (#{version}, 0)")
  end

  @spec delete_migration!(Path.t(), integer()) :: :ok
  def delete_migration!(database, version) when is_integer(version) do
    exec!(database, "DELETE FROM schema_migrations WHERE version = #{version}")
  end

  @spec exec!(Path.t(), String.t()) :: :ok
  def exec!(database, sql) do
    {:ok, conn} = Sqlite3.open(database, mode: :readwrite)

    try do
      :ok = Sqlite3.execute(conn, sql)
    after
      :ok = Sqlite3.close(conn)
    end
  end

  @spec insert_project!(Path.t(), String.t(), String.t(), String.t()) :: :ok
  def insert_project!(database, id, name, root_path) do
    with_connection(database, :readwrite, fn conn ->
      execute_bound!(
        conn,
        """
        INSERT INTO projects(id, name, root_path, inserted_at, updated_at)
        VALUES (?, ?, ?, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z')
        """,
        [id, name, root_path]
      )
    end)
  end

  @spec insert_foreign_key_violation!(Path.t()) :: :ok
  def insert_foreign_key_violation!(database) do
    with_connection(database, :readwrite, fn conn ->
      :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys=OFF")

      execute_bound!(
        conn,
        """
        INSERT INTO conversations(id, project_id, inserted_at, updated_at)
        VALUES (?, ?, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z')
        """,
        ["orphan-conversation", "missing-project"]
      )
    end)
  end

  @spec open_uncheckpointed_wal!(Path.t()) :: Sqlite3.db()
  def open_uncheckpointed_wal!(database) do
    {:ok, conn} = Sqlite3.open(database, mode: :readwrite)

    try do
      [["wal"]] = SqliteQuery.rows(conn, "PRAGMA journal_mode=WAL", [], max_rows: 1)
      :ok = Sqlite3.execute(conn, "PRAGMA wal_autocheckpoint=0")

      for number <- 1..2 do
        execute_bound!(
          conn,
          """
          INSERT INTO projects(id, name, root_path, inserted_at, updated_at)
          VALUES (?, ?, ?, '2026-09-01T00:00:00Z', '2026-09-01T00:00:00Z')
          """,
          [
            "wal-project-#{number}",
            "WAL project #{number}",
            "/private/wal-project-#{number}"
          ]
        )
      end

      ExUnit.Callbacks.on_exit(fn -> Sqlite3.close(conn) end)
      conn
    rescue
      error ->
        _ = Sqlite3.close(conn)
        reraise error, __STACKTRACE__
    end
  end

  @spec row_counts(Path.t()) :: %{String.t() => non_neg_integer()}
  def row_counts(database) do
    with_connection(database, :readonly, fn conn ->
      table_names =
        SqliteQuery.rows(
          conn,
          """
          SELECT name
          FROM sqlite_schema
          WHERE type = 'table' AND name NOT GLOB 'sqlite_*'
          ORDER BY name
          LIMIT 513
          """,
          [],
          max_rows: @maximum_tables
        )
        |> Enum.map(fn [name] -> name end)

      Map.new(table_names, fn name ->
        [[count]] =
          SqliteQuery.rows(conn, "SELECT count(*) FROM #{quote_identifier(name)}", [],
            max_rows: 1
          )

        {name, count}
      end)
    end)
  end

  defp with_connection(database, mode, function) do
    {:ok, conn} = Sqlite3.open(database, mode: mode)

    try do
      function.(conn)
    after
      :ok = Sqlite3.close(conn)
    end
  end

  defp execute_bound!(conn, sql, parameters) do
    SqliteQuery.reduce(conn, sql, parameters, :ok, fn _row, :ok -> :ok end, max_rows: 0)
  end

  defp quote_identifier(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp fixture_path(:current), do: Path.join(fixtures_directory(), "desktop-current.sql")

  defp fixture_path({:prefix, 20_260_923_000_000}),
    do: Path.join(fixtures_directory(), "desktop-20260923000000.sql")

  defp fixture_path({:prefix, 20_260_924_000_000}),
    do: Path.join(fixtures_directory(), "desktop-20260924000000.sql")

  defp fixture_path({:prefix, version})
       when version in [
              20_260_926_000_000,
              20_260_927_000_000,
              20_260_928_000_000,
              20_260_929_000_000
            ],
       do: Path.join(fixtures_directory(), "desktop-#{version}.sql")

  defp fixtures_directory do
    :swarm_code_daemon
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("schema/fixtures")
  end
end
