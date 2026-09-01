defmodule SchemaFixture do
  @moduledoc false

  alias Exqlite.Sqlite3

  @spec database!(:current | {:prefix, integer()}) :: Path.t()
  def database!(lineage) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-schema-fixture-#{System.unique_integer([:positive, :monotonic])}"
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

  defp fixture_path(:current), do: Path.join(fixtures_directory(), "desktop-current.sql")

  defp fixture_path({:prefix, 20_260_923_000_000}),
    do: Path.join(fixtures_directory(), "desktop-20260923000000.sql")

  defp fixture_path({:prefix, 20_260_924_000_000}),
    do: Path.join(fixtures_directory(), "desktop-20260924000000.sql")

  defp fixtures_directory do
    :swarm_code_daemon
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("schema/fixtures")
  end
end
