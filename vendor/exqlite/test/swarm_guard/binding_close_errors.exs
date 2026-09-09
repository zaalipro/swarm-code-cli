scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule BindingCloseErrorsTest do
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

  test "consumed descriptor close error quarantines the binding and retains lease", c do
    {scope, lease, binding} = acquire(c)
    {:ok, ticket} = DatabaseBinding.authorize(binding, self())
    {:ok, db} = DatabaseBinding.open(ticket)
    assert :ok = Sqlite3.execute(db, "SELECT 1")
    assert :ok = Exqlite.Sqlite3NIF.database_binding_test_close_fault(binding)
    assert {:error, :database_binding_close_failed} = Sqlite3.close(db)
    assert 1 = Exqlite.Sqlite3NIF.database_binding_test_close_hits(binding)
    assert :close_failed = DatabaseBinding.status(binding)
    assert 0 = DatabaseBinding.connections(binding)
    assert {:error, :database_binding_in_use} = GuardedLease.close(lease)
    assert {:error, :database_binding_close_failed} = DatabaseBinding.close(binding)
    assert :close_failed = DirectoryScope.status(scope)
    assert {:ok, sibling_scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(sibling_scope, Path.join(c.root,"runtime"))
    {:ok, data} = DirectoryScope.open_root(sibling_scope, Path.join(c.root,"data"))
    assert {:error, _} = DirectoryScope.lock(sibling_scope,runtime,data)
    DirectoryScope.close(sibling_scope)
  end
end
