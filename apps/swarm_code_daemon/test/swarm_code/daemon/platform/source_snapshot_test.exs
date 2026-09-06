defmodule SwarmCode.Daemon.Platform.SourceSnapshotTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Platform.SourceSnapshot

  setup do
    directory =
      Path.join(System.tmp_dir!(), "snapshot-test-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      path: Path.join(directory, "source.db"),
      uid: File.lstat!(directory).uid
    }
  end

  test "main-only snapshot reads exact rows and leaves source bytes untouched", ctx do
    create_database(ctx.path, false)
    before = bytes(ctx.path)
    assert {:ok, [["committed", 42]]} = snapshot(ctx, &read_rows/1)
    assert bytes(ctx.path) == before
    assert File.ls!(ctx.directory) == ["source.db"]
  end

  test "live WAL snapshot includes committed rows without changing main WAL or SHM", ctx do
    connection = create_database(ctx.path, true)
    before = bytes(ctx.path)
    assert {:ok, [["committed", 42]]} = snapshot(ctx, &read_rows/1)
    assert bytes(ctx.path) == before
    assert Enum.sort(File.ls!(ctx.directory)) == ["source.db", "source.db-shm", "source.db-wal"]
    assert :ok = Sqlite3.close(connection)
  end

  test "unopened private main WAL pair does not need source SHM", ctx do
    original = Path.join(ctx.directory, "original.db")
    connection = create_database(original, true)

    for suffix <- ["", "-wal"] do
      File.cp!(original <> suffix, ctx.path <> suffix)
      File.chmod!(ctx.path <> suffix, 0o600)
    end

    :ok = Sqlite3.close(connection)
    before = bytes(ctx.path)
    assert {:ok, [["committed", 42]]} = snapshot(ctx, &read_rows/1)
    assert bytes(ctx.path) == before
    refute File.exists?(ctx.path <> "-shm")
  end

  test "registered connection accepts only its exact private snapshot path", ctx do
    create_database(ctx.path, false)

    assert {:error, :snapshot_failed} =
             snapshot(ctx, fn _path ->
               SourceSnapshot.with_connection(ctx.path, fn _connection ->
                 :wrong_database_opened
               end)
             end)

    assert File.ls!(ctx.directory) == ["source.db"]
  end

  test "callback error returns only after cleanup", ctx do
    create_database(ctx.path, false)
    assert {:error, :custom_error} = snapshot(ctx, fn _ -> {:error, :custom_error} end)
    assert File.ls!(ctx.directory) == ["source.db"]
    assert {:error, :snapshot_failed} = snapshot(ctx, fn _ -> raise "callback failure" end)
    assert File.ls!(ctx.directory) == ["source.db"]
  end

  test "callback timeout stops reader before cleaning workspace", ctx do
    create_database(ctx.path, false)
    parent = self()

    callback = fn path ->
      send(parent, {:reader, self(), path})

      receive do
        :never -> :ok
      end
    end

    task = Task.async(fn -> snapshot(ctx, callback, callback_timeout: 30) end)
    assert_receive {:reader, reader, path}, 5_000
    monitor = Process.monitor(reader)
    assert {:error, :snapshot_timeout} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}
    refute File.exists?(Path.dirname(path))
  end

  test "registered SQLite query is cancelled and closed before callback timeout returns", ctx do
    create_database(ctx.path, false)
    parent = self()

    task =
      Task.async(fn ->
        snapshot(
          ctx,
          fn path ->
            SourceSnapshot.with_connection(path, fn connection ->
              send(parent, {:registered_reader, connection, path})

              {:ok, statement} =
                Sqlite3.prepare(
                  connection,
                  "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT sum(x) FROM n"
                )

              try do
                Sqlite3.step(connection, statement)
              after
                Sqlite3.release(connection, statement)
              end
            end)
          end,
          callback_timeout: 50
        )
      end)

    assert_receive {:registered_reader, connection, path}, 5_000

    on_exit(fn ->
      Sqlite3.cancel(connection)
      Sqlite3.close(connection)
    end)

    assert {:error, :snapshot_timeout} = Task.await(task, 5_000)
    refute File.exists?(Path.dirname(path))
    assert {:error, _} = Sqlite3.execute(connection, "SELECT 1")
  end

  test "requester loss settles worker and owned workspace", ctx do
    create_database(ctx.path, false)
    parent = self()

    requester =
      spawn(fn ->
        snapshot(
          ctx,
          fn path ->
            send(parent, {:reader, self(), path})

            receive do
              :never -> :ok
            end
          end,
          observer: parent
        )
      end)

    assert_receive {:snapshot_owner_started, owner}, 5_000
    monitor = Process.monitor(owner)
    assert_receive {:reader, reader, path}, 5_000
    reader_monitor = Process.monitor(reader)
    Process.exit(requester, :kill)
    assert_receive {:DOWN, ^reader_monitor, :process, ^reader, _}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    refute File.exists?(Path.dirname(path))
    assert File.ls!(ctx.directory) == ["source.db"]
  end

  test "requester loss during pre-copy barrier settles owned files", ctx do
    create_database(ctx.path, false)
    parent = self()

    requester =
      spawn(fn ->
        snapshot(ctx, &read_rows/1,
          observer: parent,
          test_before_copy: fn path ->
            send(parent, {:copy_barrier, self(), path})

            receive do
              :never -> :ok
            end
          end
        )
      end)

    assert_receive {:snapshot_owner_started, owner}, 5_000
    monitor = Process.monitor(owner)
    assert_receive {:copy_barrier, worker, path}, 5_000
    worker_monitor = Process.monitor(worker)
    Process.exit(requester, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    refute File.exists?(Path.dirname(path))
  end

  test "live WAL writer lock refuses snapshot without changing canonical bytes", ctx do
    connection = create_database(ctx.path, true)
    :ok = Sqlite3.execute(connection, "BEGIN IMMEDIATE")
    # POSIX locks are process-wide: opening/closing SHM from this BEAM to hash it
    # would drop the writer lock. Read bytes in a separate owned cat process.
    before = external_bytes(ctx.path)
    assert {:error, :snapshot_failed} = snapshot(ctx, &read_rows/1)
    assert external_bytes(ctx.path) == before
    assert Enum.sort(File.ls!(ctx.directory)) == ["source.db", "source.db-shm", "source.db-wal"]
    :ok = Sqlite3.execute(connection, "ROLLBACK")
    :ok = Sqlite3.close(connection)
  end

  test "replaced workspace is preserved and cannot be reported as settled", ctx do
    create_database(ctx.path, false)
    parent = self()

    assert {:error, :snapshot_cleanup_pending} =
             snapshot(
               ctx,
               fn path ->
                 directory = Path.dirname(path)
                 File.rename!(directory, directory <> "-moved")
                 File.mkdir!(directory)
                 File.chmod!(directory, 0o700)
                 File.write!(Path.join(directory, "unowned"), "preserve")
                 send(parent, {:replaced_workspace, directory})
                 :ok
               end,
               observer: parent
             )

    assert_receive {:snapshot_owner_started, owner}
    assert_receive {:replaced_workspace, directory}
    assert File.read!(Path.join(directory, "unowned")) == "preserve"
    assert File.ls!(directory <> "-moved") == []
    assert Process.alive?(owner)
    # This intentionally ambiguous owner has no live children after the broker
    # settled. The private test tears down its retained receipt-only process.
    Process.exit(owner, :kill)
  end

  test "invalid options and expected identities refuse before workspace effects", ctx do
    create_database(ctx.path, false)

    for opts <- [
          [unexpected: true],
          [:invalid],
          [timeout: 0],
          [timeout: 300_001],
          [timeout: 1, timeout: 2]
        ] do
      assert {:error, :snapshot_failed} = snapshot(ctx, &read_rows/1, opts)
      assert File.ls!(ctx.directory) == ["source.db"]
    end

    expected = expected(ctx.path)
    wrong = put_in(expected.main.inode, expected.main.inode + 1)

    assert {:error, :snapshot_failed} =
             SourceSnapshot.with_snapshot(ctx.path, ctx.uid, wrong, &read_rows/1)

    assert File.ls!(ctx.directory) == ["source.db"]
  end

  defp snapshot(ctx, callback, opts \\ []),
    do: SourceSnapshot.with_snapshot(ctx.path, ctx.uid, expected(ctx.path), callback, opts)

  defp expected(path) do
    %{
      main: File.lstat!(path),
      wal: stat(path <> "-wal"),
      shm: stat(path <> "-shm"),
      parent: File.lstat!(Path.dirname(path))
    }
  end

  defp stat(path) do
    case File.lstat(path) do
      {:ok, value} -> value
      {:error, :enoent} -> nil
    end
  end

  defp external_bytes(path) do
    Enum.map(["", "-wal", "-shm"], fn suffix ->
      {bytes, 0} = System.cmd("/bin/cat", [path <> suffix])
      bytes
    end)
  end

  defp bytes(path), do: Enum.map(["", "-wal", "-shm"], &File.read(path <> &1))

  defp create_database(path, wal?) do
    {:ok, connection} = Sqlite3.open(path)

    if wal?,
      do: Sqlite3.execute(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")

    :ok =
      Sqlite3.execute(
        connection,
        "CREATE TABLE items(name TEXT, value INTEGER); INSERT INTO items VALUES ('committed', 42);"
      )

    for suffix <- ["", "-wal", "-shm"],
        File.exists?(path <> suffix),
        do: File.chmod!(path <> suffix, 0o600)

    if wal?, do: connection, else: Sqlite3.close(connection)
  end

  defp read_rows(path) do
    SourceSnapshot.with_connection(path, fn connection ->
      {:ok, statement} = Sqlite3.prepare(connection, "SELECT name, value FROM items")

      try do
        Sqlite3.fetch_all(connection, statement)
      after
        Sqlite3.release(connection, statement)
      end
    end)
  end
end
