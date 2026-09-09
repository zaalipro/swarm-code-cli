scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule DatabaseBindingTest do
  use ExUnit.Case, async: false
  alias Exqlite.{DatabaseBinding, DirectoryScope, GuardedLease, Sqlite3}

  setup do
    root =
      Path.join(
        System.fetch_env!("SWARM_FEASIBILITY_ROOT"),
        "binding-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    for role <- ["runtime", "data"] do
      File.mkdir!(Path.join(root, role))
      File.chmod!(Path.join(root, role), 0o700)
    end

    path = Path.join([root, "data", "application.db"])
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "CREATE TABLE evidence(value); INSERT INTO evidence VALUES(42)")
    :ok = Sqlite3.close(db)
    File.chmod!(path, 0o600)
    stat = File.stat!(path)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: path, identity: {stat.major_device, stat.inode, stat.uid}}
  end

  defp acquire(c) do
    {:ok, scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(scope, Path.join(c.root, "runtime"))
    {:ok, data} = DirectoryScope.open_root(scope, Path.join(c.root, "data"))
    :ok = DirectoryScope.lock(scope, runtime, data)
    {:ok, lease} = GuardedLease.acquire(scope)
    {:ok, binding} = DatabaseBinding.acquire(lease, c.identity)
    {scope, lease, binding}
  end

  test "pins admitted identity and requires binding before lease before scope close", c do
    before = File.read!(c.path)
    {scope, lease, binding} = acquire(c)
    assert is_reference(binding)
    assert :pinned = DatabaseBinding.status(binding)
    assert :ok = DatabaseBinding.assert_held(binding)
    assert {:error, :database_binding_in_use} = GuardedLease.close(lease)

    assert {:error, :database_binding_already_attempted} =
             DatabaseBinding.acquire(lease, c.identity)

    assert_raise ArgumentError, fn -> DatabaseBinding.assert_held(make_ref()) end
    assert :ok = DatabaseBinding.close(binding)
    assert :closed = DatabaseBinding.status(binding)
    assert {:error, :database_binding_closed} = DatabaseBinding.assert_held(binding)
    assert :ok = GuardedLease.close(lease)
    assert :ok = DirectoryScope.close(scope)
    assert File.read!(c.path) == before
  end

  test "a copied binding does not transfer ownership; owner death revokes retained terms", c do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        handles = acquire(c)
        send(parent, {:handles, handles})

        receive do
          :finish -> handles
        end
      end)

    assert_receive {:handles, {scope, lease, binding}}, 5_000
    assert {:error, :directory_wrong_owner} = DatabaseBinding.assert_held(binding)
    assert {:error, :directory_wrong_owner} = DatabaseBinding.close(binding)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    for _ <- 1..100, DirectoryScope.status(scope) != :closed, do: Process.sleep(10)
    assert :closed = DirectoryScope.status(scope)
    assert :closed = GuardedLease.status(lease)
    assert :closed = DatabaseBinding.status(binding)
    assert {:error, :directory_scope_revoked} = DatabaseBinding.assert_held(binding)
  end

  test "main replacement revokes without writing replacement", c do
    {scope, lease, binding} = acquire(c)
    File.rename!(c.path, c.path <> ".held")
    File.write!(c.path, "replacement")
    File.chmod!(c.path, 0o600)
    assert {:error, :database_binding_changed} = DatabaseBinding.assert_held(binding)
    for _ <- 1..100, DirectoryScope.status(scope) != :closed, do: Process.sleep(10)
    assert :closed = DirectoryScope.status(scope)
    assert :closed = GuardedLease.status(lease)
    assert File.read!(c.path) == "replacement"
  end

  test "sidecar symlink is rejected and revokes the binding", c do
    {scope, lease, binding} = acquire(c)
    sidecar = c.path <> "-wal"
    File.ln_s!(c.path, sidecar)

    assert {:error, :database_binding_changed} = DatabaseBinding.assert_held(binding)
    for _ <- 1..100, DirectoryScope.status(scope) != :closed, do: Process.sleep(10)
    assert :closed = DirectoryScope.status(scope)
    assert :closed = GuardedLease.status(lease)
    File.rm(sidecar)
  end

  test "explicitly closed bindings release retained scope resources on GC", c do
    for _ <- 1..140 do
      close_generation(c)
      :erlang.garbage_collect(self())
    end
  end

  defp opened(binding) do
    {:ok, ticket} = DatabaseBinding.authorize(binding, self())
    {:ok, db} = DatabaseBinding.open(ticket)
    {ticket, db}
  end

  defp rows(db, sql) do
    {:ok, statement} = Sqlite3.prepare(db, sql)
    {:ok, result} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    result
  end

  test "opaque ticket opens writable SQLite, denies replay, and retains statements", c do
    {scope, lease, binding} = acquire(c)
    {ticket, db} = opened(binding)
    assert {:error, :database_binding_ticket_consumed} = DatabaseBinding.open(ticket)
    assert :ok = DatabaseBinding.assert_connection(db)

    assert :ok =
             Sqlite3.execute(
               db,
               "CREATE TABLE writable(id INTEGER); INSERT INTO writable VALUES(7)"
             )

    assert [[7]] = rows(db, "SELECT id FROM writable")
    {:ok, statement} = Sqlite3.prepare(db, "SELECT id FROM writable")
    assert {:error, _} = Sqlite3.close(db)
    assert 1 = DatabaseBinding.connections(binding)
    assert {:error, :database_binding_in_use} = DatabaseBinding.close(binding)
    assert {:error, :database_binding_in_use} = GuardedLease.close(lease)
    assert :ok = Sqlite3.release(db, statement)
    assert :ok = Sqlite3.close(db)
    assert 0 = DatabaseBinding.connections(binding)
    assert :ok = DatabaseBinding.close(binding)
    assert :ok = GuardedLease.close(lease)
    assert :ok = DirectoryScope.close(scope)
  end

  test "multiple WAL connections and replacement preserve locks and committed rows", c do
    {scope, lease, binding} = acquire(c)
    {_, first} = opened(binding)
    assert :ok = Sqlite3.execute(first, "PRAGMA journal_mode=WAL; CREATE TABLE pool(id INTEGER)")
    {_, second} = opened(binding)
    assert 2 = DatabaseBinding.connections(binding)
    assert :ok = Sqlite3.execute(first, "BEGIN IMMEDIATE; INSERT INTO pool VALUES(1)")
    assert :ok = Sqlite3.close(second)
    {_, replacement} = opened(binding)
    :ok = Sqlite3.set_busy_timeout(replacement, 1)
    assert {:error, _} = Sqlite3.execute(replacement, "INSERT INTO pool VALUES(2)")
    assert :ok = Sqlite3.execute(first, "COMMIT")
    assert :ok = Sqlite3.execute(replacement, "INSERT INTO pool VALUES(2)")
    assert [[1], [2]] = rows(first, "SELECT id FROM pool ORDER BY id")
    assert File.exists?(c.path <> "-wal")
    assert File.exists?(c.path <> "-shm")
    assert :ok = Sqlite3.close(first)
    assert :ok = Sqlite3.close(replacement)
    refute File.exists?(c.path <> "-shm")
    refute File.exists?(c.path <> "-wal")
    assert :ok = DatabaseBinding.close(binding)
    assert :ok = GuardedLease.close(lease)
    assert :ok = DirectoryScope.close(scope)
  end

  test "replacement revokes live handles and holds lease until their close", c do
    {scope, lease, binding} = acquire(c)
    {_, db} = opened(binding)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL; INSERT INTO evidence VALUES(8)")
    File.rename!(c.path <> "-wal", c.path <> "-wal.held")
    File.write!(c.path <> "-wal", "replacement")
    File.chmod!(c.path <> "-wal", 0o600)
    assert {:error, :database_binding_changed} = DatabaseBinding.assert_connection(db)
    assert {:error, _} = Sqlite3.execute(db, "INSERT INTO evidence VALUES(9)")
    assert 1 = DatabaseBinding.connections(binding)
    assert {:error, :database_binding_in_use} = GuardedLease.close(lease)
    assert :ok = Sqlite3.close(db)
    assert 0 = DatabaseBinding.connections(binding)
    for _ <- 1..100, DirectoryScope.status(scope) != :closed, do: Process.sleep(10)
    assert :closed = DirectoryScope.status(scope)
    assert File.read!(c.path <> "-wal") == "replacement"
  end

  test "explicit canonical basename and adapter open have no database path option", c do
    target = Path.join(Path.dirname(c.path), "swarm_code.db")
    File.rename!(c.path, target)
    {:ok, scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(scope, Path.join(c.root, "runtime"))
    {:ok, data} = DirectoryScope.open_root(scope, Path.join(c.root, "data"))
    :ok = DirectoryScope.lock(scope, runtime, data)
    {:ok, lease} = GuardedLease.acquire(scope)

    assert {:error, :invalid_database_basename} =
             DatabaseBinding.acquire(lease, c.identity, "../swarm_code.db")

    {:ok, binding} = DatabaseBinding.acquire(lease, c.identity, "swarm_code.db")
    {:ok, ticket} = DatabaseBinding.authorize(binding, self())
    {:ok, connection} = Exqlite.Connection.connect(database_binding: ticket)
    assert connection.path == nil
    assert connection.directory == nil
    assert :ok = Sqlite3.execute(connection.db, "INSERT INTO evidence VALUES(99)")
    assert [[42], [99]] = rows(connection.db, "SELECT value FROM evidence ORDER BY value")
    assert :ok = Exqlite.Connection.disconnect(:normal, connection)
    assert :ok = DatabaseBinding.close(binding)
    assert :ok = GuardedLease.close(lease)
    assert :ok = DirectoryScope.close(scope)
  end

  test "owner-only create admits a new descriptor-relative database", c do
    {:ok, scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(scope, Path.join(c.root, "runtime"))
    {:ok, data} = DirectoryScope.open_root(scope, Path.join(c.root, "data"))
    :ok = DirectoryScope.lock(scope, runtime, data)
    {:ok, lease} = GuardedLease.acquire(scope)
    assert {:ok, binding, {device, inode, uid}} = DatabaseBinding.create(lease, "created.db")
    assert File.stat!(Path.join(c.root, "data/created.db")).inode == inode
    assert File.stat!(Path.join(c.root, "data/created.db")).major_device == device
    assert File.stat!(Path.join(c.root, "data/created.db")).uid == uid
    {:ok, ticket} = DatabaseBinding.authorize(binding, self())
    {:ok, db} = DatabaseBinding.open(ticket)
    assert :ok = Sqlite3.execute(db, "CREATE TABLE created(value); INSERT INTO created VALUES(11)")
    assert :ok = Sqlite3.close(db)
    assert :ok = DatabaseBinding.close(binding)
    assert :ok = GuardedLease.close(lease)
    assert :ok = DirectoryScope.close(scope)
  end

  test "cached and already prepared reads are fenced at each native operation", c do
    {scope, _lease, binding} = acquire(c)
    {_, db} = opened(binding)
    assert :ok = Sqlite3.execute(db, "INSERT INTO evidence VALUES(99)")
    assert [[42], [99]] = rows(db, "SELECT value FROM evidence ORDER BY value")
    {:ok, step_query} = Sqlite3.prepare(db, "SELECT value FROM evidence ORDER BY value")
    {:ok, chunk_query} = Sqlite3.prepare(db, "SELECT value FROM evidence ORDER BY value")
    assert {:row, [42]} = Sqlite3.step(db, step_query)
    assert {:rows, [[42]]} = Sqlite3.multi_step(db, chunk_query, 1)

    File.rename!(c.path, c.path <> ".held")
    File.write!(c.path, "replacement")
    File.chmod!(c.path, 0o600)

    assert {:error, _} = Sqlite3.step(db, step_query)
    assert {:error, _} = Sqlite3.multi_step(db, chunk_query, 1)
    assert {:error, _} = Sqlite3.execute(db, "SELECT 1")
    assert {:error, _} = Sqlite3.prepare(db, "SELECT 1")
    assert {:error, :database_binding_changed} = DatabaseBinding.assert_connection(db)
    assert :ok = Sqlite3.release(db, step_query)
    assert :ok = Sqlite3.release(db, chunk_query)
    assert :ok = Sqlite3.close(db)
    for _ <- 1..100, DirectoryScope.status(scope) != :closed, do: Process.sleep(10)
    assert :closed = DirectoryScope.status(scope)
    assert File.read!(c.path) == "replacement"
  end

  defp close_generation(c) do
    {scope, lease, binding} = acquire(c)
    assert :ok = DatabaseBinding.close(binding)
    assert :ok = GuardedLease.close(lease)
    assert :ok = DirectoryScope.close(scope)
  end
end
