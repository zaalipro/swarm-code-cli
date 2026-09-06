defmodule SwarmCode.Daemon.Platform.GuardedExqliteFeasibilityTest do
  use ExUnit.Case, async: false
  alias Exqlite.{Sqlite3, SwarmGuard}

  test "Mix-built native directory scopes hold and release actual OS directory locks" do
    root =
      Path.join(
        Path.expand("../../../../../..", __DIR__),
        "_build/directory-mix-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    runtime = Path.join(root, "runtime")
    data = Path.join(root, "data")

    for path <- [runtime, data] do
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, scope} = Exqlite.DirectoryScope.new()

    try do
      {:ok, runtime_handle} = Exqlite.DirectoryScope.open_root(scope, runtime)
      {:ok, data_handle} = Exqlite.DirectoryScope.open_root(scope, data)
      assert :ok = Exqlite.DirectoryScope.lock(scope, runtime_handle, data_handle)
      assert :ok = Exqlite.DirectoryScope.assert_locked(scope)
      assert os_directory_lock(runtime) == "busy"
      assert os_directory_lock(data) == "busy"
    after
      assert :ok = Exqlite.DirectoryScope.close(scope)
    end

    assert os_directory_lock(runtime) == "acquired"
    assert os_directory_lock(data) == "acquired"
  end

  defp os_directory_lock(path) do
    code = """
    import fcntl,os,sys
    fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY)
    try:
      fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
      print('acquired')
    except BlockingIOError:
      print('busy')
    finally:
      os.close(fd)
    """

    {output, 0} = System.cmd("python3", ["-c", code, path])
    String.trim(output)
  end

  test "the pinned local NIF consumes an exact read-only fixture descriptor" do
    assert Application.spec(:exqlite, :vsn) |> to_string() == "0.39.0-swarm.1"
    assert Code.ensure_loaded?(SwarmGuard)

    root =
      Path.join(
        System.tmp_dir!(),
        "swarm-guard-mix-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    original = Path.join(root, "original.db")
    replacement = Path.join(root, "replacement.db")
    held = Path.join(root, "held.db")
    on_exit(fn -> File.rm_rf!(root) end)

    for {path, value} <- [{original, 111}, {replacement, 222}] do
      {:ok, conn} = Sqlite3.open(path)
      :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=DELETE; PRAGMA application_id=#{value}")
      :ok = Sqlite3.close(conn)
      File.chmod!(path, 0o600)
    end

    assert {:ok, admission} = SwarmGuard.feasibility_admit(original)
    assert {:ok, identity} = SwarmGuard.resource_identity(admission)
    File.rename!(original, held)
    File.rename!(replacement, original)
    assert {:ok, conn} = SwarmGuard.feasibility_open(admission)

    try do
      assert {:ok, ^identity} = SwarmGuard.connection_identity(conn)
      assert scalar(conn, "PRAGMA application_id") == 111
      assert scalar(conn, "SELECT sqlite_version()") == "3.53.3"
      assert {:error, _} = Sqlite3.execute(conn, "PRAGMA application_id=333")
      assert {:error, :guard_consumed} = SwarmGuard.feasibility_open(admission)
    after
      assert :ok = Sqlite3.close(conn)
      assert :ok = SwarmGuard.close(admission)
    end

    {:ok, direct} = Sqlite3.open(original)
    assert scalar(direct, "PRAGMA application_id") == 222
    assert :ok = Sqlite3.close(direct)
  end

  test "the bundled SQLite inputs match the audited upstream bytes" do
    root = Path.expand("../../../../../..", __DIR__)

    for {name, expected} <- [
          {"sqlite3.c", "87497ab605bedd0dbee27a209c1eeff8c89b229b13f921a7efdbb81a13f779fd"},
          {"sqlite3.h", "4ff81af4849acabc76fc8349abb926814395072617ca18e08800abf734ab7612"}
        ] do
      actual =
        Path.join(root, "vendor/exqlite/c_src/#{name}")
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == expected
    end
  end

  defp scalar(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)

    try do
      assert {:row, [value]} = Sqlite3.step(conn, stmt)
      assert :done = Sqlite3.step(conn, stmt)
      value
    after
      :ok = Sqlite3.release(conn, stmt)
    end
  end
end
