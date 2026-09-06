scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule ScratchGuardProof do
  use ExUnit.Case, async: false
  alias Exqlite.Sqlite3, as: DB
  alias Exqlite.Sqlite3NIF, as: Guard

  def scalar(db, sql) do
    {:ok, stmt} = DB.prepare(db, sql)
    try do
      {:row, [value]} = DB.step(db, stmt)
      :done = DB.step(db, stmt)
      value
    after
      :ok = DB.release(db, stmt)
    end
  end

  def fixture do
    root = Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "main.db")
    {:ok, db} = DB.open(path)
    :ok = DB.execute(db, "PRAGMA journal_mode=DELETE; PRAGMA application_id=111; CREATE TABLE item(value); INSERT INTO item VALUES(111)")
    :ok = DB.close(db)
    File.chmod!(path, 0o600)
    on_exit(fn ->
      File.rm!(path)
      assert [] = File.ls!(root)
      File.rmdir!(root)
    end)
    path
  end

  def await_counts(expected, remaining \\ 100)
  def await_counts(expected, 0), do: assert(Guard.guard_counts() == expected)
  def await_counts(expected, remaining) do
    if Guard.guard_counts() != expected do
      Process.sleep(10)
      await_counts(expected, remaining - 1)
    end
  end

  test "admission GC after owner death closes its descriptor without registration" do
    path = fixture()
    owner = self()
    {pid, monitor} = spawn_monitor(fn ->
      {:ok, admission} = Guard.guard_admit(path)
      send(owner, :admitted)
      receive do :keep -> Guard.guard_resource_identity(admission) end
    end)
    assert_receive :admitted
    assert {1, 0, 0} = Guard.guard_counts()
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    await_counts({0, 0, 0})
  end

  test "owner death with a live statement finalizes connection and admission" do
    path = fixture()
    owner = self()
    {pid, monitor} = spawn_monitor(fn ->
      {:ok, admission} = Guard.guard_admit(path)
      {:ok, conn} = Guard.guard_open(admission)
      {:ok, stmt} = DB.prepare(conn, "SELECT value FROM item")
      assert {:row, [111]} = DB.step(conn, stmt)
      send(owner, :opened)
      receive do :keep -> {admission, conn, stmt} end
    end)
    assert_receive :opened
    assert {1, 1, 0} = Guard.guard_counts()
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    await_counts({0, 0, 0})
  end

  test "connection retains admission across admitting process death" do
    path = fixture()
    owner = self()
    {pid, monitor} = spawn_monitor(fn ->
      {:ok, admission} = Guard.guard_admit(path)
      {:ok, conn} = Guard.guard_open(admission)
      send(owner, {:connection, conn})
    end)
    assert_receive {:connection, conn}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert scalar(conn, "PRAGMA application_id") == 111
    assert {1, 1, 0} = Guard.guard_counts()
    assert :ok = DB.close(conn)
    await_counts({0, 0, 0})
  end

  test "known sidecars and WAL header are refused as non-main-only fixtures" do
    path = fixture()
    for suffix <- ["-journal", "-wal", "-shm"] do
      File.write!(path <> suffix, "fixture")
      assert {:error, :guard_admission_failed} = Guard.guard_admit(path)
      File.rm!(path <> suffix)
    end
    bytes = File.read!(path)
    <<head::binary-size(18), _::binary-size(2), tail::binary>> = bytes
    File.write!(path, head <> <<2, 2>> <> tail)
    assert {:error, :guard_admission_failed} = Guard.guard_admit(path)
    assert {0, 0, 0} = Guard.guard_counts()
  end

  test "native registration and lifecycle counters are available" do
    assert {:module, Guard} = Code.ensure_loaded(Guard)
    assert function_exported?(Guard, :guard_counts, 0)
    Application.load(:exqlite)
    assert Application.spec(:exqlite, :vsn) == ~c"0.39.0-swarm.1"
    assert {0, 0, 0} = Guard.guard_counts()
  end

  test "actual Exqlite connection consumes a read-only admitted descriptor" do
    root = Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "fixtures-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    original = Path.join(root, "main.db")
    held = Path.join(root, "held.db")
    replacement = Path.join(root, "replacement.db")

    for {path, id} <- [{original, 111}, {replacement, 222}] do
      {:ok, db} = DB.open(path)
      :ok = DB.execute(db, "PRAGMA journal_mode=DELETE; PRAGMA application_id=#{id}; CREATE TABLE item(value); INSERT INTO item VALUES(#{id});")
      :ok = DB.close(db)
      File.chmod!(path, 0o600)
    end

    assert Path.expand(:code.priv_dir(:exqlite) |> to_string()) ==
             Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "lib/exqlite/priv")
    {:ok, admitted} = Guard.guard_admit(original)
    assert is_reference(admitted)
    {:ok, identity} = Guard.guard_resource_identity(admitted)
    assert {:regular, _, _, _, 0o600} = identity
    File.rename!(original, held)
    File.rename!(replacement, original)

    {:ok, guarded} = Guard.guard_open(admitted)
    assert is_reference(guarded)
    assert {:ok, ^identity} = Guard.guard_connection_identity(guarded)
    assert scalar(guarded, "PRAGMA application_id") == 111
    assert scalar(guarded, "SELECT value FROM item") == 111
    assert scalar(guarded, "SELECT sqlite_version()") == "3.53.3"
    assert scalar(guarded, "SELECT sqlite_source_id()") ==
             "2026-06-26 20:14:12 d4c0e51e4aeb96955b99185ab9cde75c339e2c29c3f3f12428d364a10d782c62"
    assert :ok = DB.set_busy_timeout(guarded, 25)
    assert :ok = DB.set_progress_handler_steps(guarded, 100)
    assert :ok = DB.cancel(guarded)
    assert scalar(guarded, "SELECT sum(value) FROM item") == 111
    assert {:error, _} = DB.execute(guarded, "UPDATE item SET value=999")
    assert {:error, :guard_operation_refused} = DB.deserialize(guarded, "main", <<>>)
    assert {:error, :guard_in_use} = Guard.guard_resource_close(admitted)
    assert {:error, :guard_consumed} = Guard.guard_open(admitted)

    {:ok, direct} = DB.open(original)
    assert scalar(direct, "PRAGMA application_id") == 222
    assert :ok = DB.execute(direct, "UPDATE item SET value=223")
    assert scalar(direct, "SELECT value FROM item") == 223
    assert :ok = DB.close(direct)
    IO.puts("PASS actual Exqlite guarded ID=111; direct Exqlite replacement ID=222; handlers and read-only refusal")

    {:ok, outstanding} = DB.prepare(guarded, "SELECT value FROM item")
    assert {:error, _} = DB.close(guarded)
    assert {:error, :guard_in_use} = Guard.guard_resource_close(admitted)
    assert scalar(guarded, "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000) SELECT sum(x) FROM n") == 500500
    assert :ok = DB.release(guarded, outstanding)
    assert :ok = DB.close(guarded)
    assert Guard.guard_close_attested(admitted)
    assert {:error, :connection_closed} = Guard.guard_connection_identity(guarded)
    assert :ok = Guard.guard_resource_close(admitted)
    assert {:error, :guard_closed} = Guard.guard_resource_identity(admitted)
    assert {:error, :guard_closed} = Guard.guard_resource_close(admitted)
    assert {:error, :guard_closed} = Guard.guard_open(admitted)
    IO.puts("PASS outstanding-statement close refusal; SQLite main xClose observed before explicit admission close; stale resource refused")

    File.rm!(held)
    File.rm!(original)
    assert [] = File.ls!(root)
    File.rmdir!(root)
    IO.puts("PASS own NIF fixture directory removed")
  end
end
