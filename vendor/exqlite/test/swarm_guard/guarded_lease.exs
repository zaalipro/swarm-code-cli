scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule GuardedLeaseTest do
  use ExUnit.Case, async: false
  alias Exqlite.{DirectoryScope, GuardedLease, Sqlite3}

  setup do
    root = Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "lease-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    for role <- ["runtime", "data"] do
      File.mkdir!(Path.join(root, role))
      File.chmod!(Path.join(root, role), 0o700)
    end
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, runtime: Path.join(root, "runtime"), data: Path.join(root, "data"),
      lease_path: Path.join([root, "data", "instance_lease.db"])}
  end

  defp locked_scope(c) do
    {:ok, scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(scope, c.runtime)
    {:ok, data} = DirectoryScope.open_root(scope, c.data)
    :ok = DirectoryScope.lock(scope, runtime, data)
    scope
  end

  defp existing_lease(path) do
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=DELETE; PRAGMA user_version=1")
    :ok = Sqlite3.close(db)
    File.chmod!(path, 0o600)
  end

  defp os_observe(c) do
    script = """
    import fcntl,os,sqlite3,sys
    result=[]
    for path in sys.argv[1:3]:
      fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY)
      try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        result.append('free')
      except BlockingIOError:
        result.append('busy')
      finally:
        os.close(fd)
    db=sqlite3.connect('file:'+sys.argv[3]+'?mode=rw',uri=True,timeout=0)
    try:
      db.execute('BEGIN EXCLUSIVE')
      result.append('free')
      db.rollback()
    except sqlite3.OperationalError as error:
      if 'locked' not in str(error): raise
      result.append('busy')
    finally:
      db.close()
    print(','.join(result))
    """
    {output, 0} = System.cmd("python3", ["-c", script, c.runtime, c.data, c.lease_path])
    String.trim(output)
  end

  defp await_free(c, attempts \\ 100)
  defp await_free(c, 0), do: assert(os_observe(c) == "free,free,free")
  defp await_free(c, attempts) do
    observation = os_observe(c)
    # Cleanup must never free directory exclusion while SQLite remains held.
    refute observation in ["free,free,busy", "free,busy,busy", "busy,free,busy"]
    if observation != "free,free,free" do
      Process.sleep(10)
      await_free(c, attempts - 1)
    end
  end

  test "missing lease is privately created and SQLite closes before directory locks", c do
    assert {:module, Exqlite.Sqlite3NIF} = Code.ensure_loaded(Exqlite.Sqlite3NIF)
    assert function_exported?(Exqlite.Sqlite3NIF, :lease_acquire, 1)
    scope = locked_scope(c)
    {:ok, lease} = GuardedLease.acquire(scope)
    assert is_reference(lease)
    assert :ok = GuardedLease.assert_held(lease)
    assert :held = GuardedLease.status(lease)
    stat = File.lstat!(c.lease_path)
    assert Bitwise.band(stat.mode, 0o7777) == 0o600
    assert stat.size >= 512
    assert {:ok, {:regular, _, inode, uid, 0o600}} = GuardedLease.identity(lease)
    assert inode == stat.inode and uid == stat.uid
    assert os_observe(c) == "busy,busy,busy"
    assert {:error, :directory_scope_in_use} = DirectoryScope.close(scope)
    assert :ok = DirectoryScope.assert_locked(scope)
    assert {:error, :lease_already_attempted} = GuardedLease.acquire(scope)
    assert {:error, _} = Sqlite3.execute(lease, "COMMIT")
    assert :ok = GuardedLease.close(lease)
    assert :closed = GuardedLease.status(lease)
    assert os_observe(c) == "busy,busy,free"
    assert :ok = DirectoryScope.close(scope)
    assert os_observe(c) == "free,free,free"
    assert File.ls!(c.data) == ["instance_lease.db"]
  end

  test "existing rollback lease remains byte-identical after a hold", c do
    existing_lease(c.lease_path)
    before = File.read!(c.lease_path)
    scope = locked_scope(c)
    {:ok, lease} = GuardedLease.acquire(scope)
    assert :ok = GuardedLease.assert_held(lease)
    assert os_observe(c) == "busy,busy,busy"
    :ok = GuardedLease.close(lease)
    :ok = DirectoryScope.close(scope)
    assert File.read!(c.lease_path) == before
  end

  test "occupied SQLite with user schema or application identity refuses unchanged", c do
    {:ok, db} = Sqlite3.open(c.lease_path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=DELETE; PRAGMA application_id=123; CREATE TABLE user_data(value); INSERT INTO user_data VALUES(17)")
    :ok = Sqlite3.close(db)
    File.chmod!(c.lease_path, 0o600)
    before = File.read!(c.lease_path)
    scope = locked_scope(c)
    assert {:error, :lease_acquisition_failed} = GuardedLease.acquire(scope)
    assert :ok = DirectoryScope.close(scope)
    assert File.read!(c.lease_path) == before
    assert File.ls!(c.data) == ["instance_lease.db"]
  end

  test "observed main replacement revokes without mutating replacement", c do
    existing_lease(c.lease_path)
    scope = locked_scope(c)
    {:ok, lease} = GuardedLease.acquire(scope)
    File.rename!(c.lease_path, c.lease_path <> "-held")
    existing_lease(c.lease_path)
    replacement = File.read!(c.lease_path)
    assert {:error, :lease_binding_changed} = GuardedLease.assert_held(lease)
    await_free(c)
    assert File.read!(c.lease_path) == replacement
    assert os_observe(%{c | lease_path: c.lease_path <> "-held"}) == "free,free,free"
  end

  test "unexpected journal appearance is retained and refuses binding", c do
    scope = locked_scope(c)
    {:ok, lease} = GuardedLease.acquire(scope)
    journal = c.lease_path <> "-journal"
    File.write!(journal, "replacement-journal")
    File.chmod!(journal, 0o600)
    assert {:error, :lease_binding_changed} = GuardedLease.assert_held(lease)
    # The foreign journal is not cleaned merely because startup/holding failed.
    assert File.read!(journal) == "replacement-journal"
    for _ <- 1..100, GuardedLease.status(lease) not in [:closed, :close_failed], do: Process.sleep(10)
    assert :closed = GuardedLease.status(lease)
    assert File.read!(journal) == "replacement-journal"
  end

  test "owner death with copied lease terms releases SQLite and both directory locks", c do
    receiver = self()
    {owner, monitor} = spawn_monitor(fn ->
      scope = locked_scope(c)
      {:ok, lease} = GuardedLease.acquire(scope)
      send(receiver, {:held, scope, lease})
      receive do :finish -> GuardedLease.assert_held(lease) end
    end)
    assert_receive {:held, scope, lease}, 5_000
    assert os_observe(c) == "busy,busy,busy"
    assert {:error, :directory_wrong_owner} = GuardedLease.assert_held(lease)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    await_free(c)
    assert :closed = GuardedLease.status(lease)
    assert :closed = DirectoryScope.status(scope)
    assert {:error, :directory_scope_revoked} = GuardedLease.assert_held(lease)
  end

  defp hold_lease_until_drop(scope, receiver, ref) do
    {:ok, lease} = GuardedLease.acquire(scope)
    send(receiver, {:lease_held, ref})
    receive do
      {:drop_lease, ^ref} -> :ok = GuardedLease.assert_held(lease)
    end
    :lease_dropped
  end

  test "lease GC revokes dependent graph while owner and copied scope remain alive", c do
    receiver = self()
    ref = make_ref()
    {owner, monitor} = spawn_monitor(fn ->
      scope = locked_scope(c)
      send(receiver, {:scope, scope, ref})
      :lease_dropped = hold_lease_until_drop(scope, receiver, ref)
      true = :erlang.garbage_collect(self())
      send(receiver, {:collected, ref})
      receive do
        {:heartbeat, ^ref} -> send(receiver, {:alive, ref, DirectoryScope.status(scope)})
      end
      receive do {:finish, ^ref} -> :ok end
    end)
    assert_receive {:scope, scope, ^ref}, 5_000
    assert_receive {:lease_held, ^ref}, 5_000
    assert os_observe(c) == "busy,busy,busy"
    send(owner, {:drop_lease, ref})
    assert_receive {:collected, ^ref}, 5_000
    await_free(c)
    send(owner, {:heartbeat, ref})
    assert_receive {:alive, ^ref, :closed}
    assert Process.alive?(owner)
    assert DirectoryScope.status(scope) == :closed
    send(owner, {:finish, ref})
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "incompatible or aliased lease roles refuse without repair", c do
    existing_lease(c.lease_path)
    original = File.read!(c.lease_path)
    for suffix <- ["-wal", "-shm"] do
      File.write!(c.lease_path <> suffix, "foreign")
      scope = locked_scope(c)
      assert {:error, :lease_acquisition_failed} = GuardedLease.acquire(scope)
      assert :ok = DirectoryScope.close(scope)
      assert File.read!(c.lease_path <> suffix) == "foreign"
      assert File.read!(c.lease_path) == original
      File.rm!(c.lease_path <> suffix)
    end
    File.ln!(c.lease_path, c.lease_path <> "-journal")
    scope = locked_scope(c)
    assert {:error, :lease_acquisition_failed} = GuardedLease.acquire(scope)
    assert :ok = DirectoryScope.close(scope)
    assert File.read!(c.lease_path) == original
    File.rm!(c.lease_path <> "-journal")
    File.chmod!(c.lease_path, 0o644)
    scope = locked_scope(c)
    assert {:error, :lease_acquisition_failed} = GuardedLease.acquire(scope)
    assert :ok = DirectoryScope.close(scope)
    assert Bitwise.band(File.lstat!(c.lease_path).mode, 0o7777) == 0o644
  end

  defp start_os_holder(c) do
    script = """
    [scratch, root] = System.argv()
    Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
    alias Exqlite.{DirectoryScope, GuardedLease}
    {:ok, scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(scope, Path.join(root, "runtime"))
    {:ok, data} = DirectoryScope.open_root(scope, Path.join(root, "data"))
    result = with :ok <- DirectoryScope.lock(scope, runtime, data),
                  {:ok, lease} <- GuardedLease.acquire(scope), do: {:ok, lease}
    case result do
      {:ok, lease} ->
        IO.puts("held")
        IO.gets("")
        :ok = GuardedLease.close(lease)
        :ok = DirectoryScope.close(scope)
      {:error, reason} ->
        IO.puts("refused:" <> Atom.to_string(reason))
        DirectoryScope.close(scope)
    end
    """
    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary, :exit_status, :use_stdio, :stderr_to_stdout,
      args: ["-e", script, "--", System.fetch_env!("SWARM_FEASIBILITY_ROOT"), c.root]
    ])
  end

  test "fresh OS producers exclude one another and admit successor after process kill", c do
    holder = start_os_holder(c)
    assert_receive {^holder, {:data, "held\n"}}, 10_000
    assert os_observe(c) == "busy,busy,busy"
    contender = start_os_holder(c)
    assert_receive {^contender, {:data, "refused:foundation_lock_held\n"}}, 10_000
    assert_receive {^contender, {:exit_status, 0}}, 10_000
    {:os_pid, pid} = Port.info(holder, :os_pid)
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
    assert_receive {^holder, {:exit_status, _}}, 10_000
    await_free(c)
    successor = start_os_holder(c)
    assert_receive {^successor, {:data, "held\n"}}, 10_000
    Port.command(successor, "close\n")
    assert_receive {^successor, {:exit_status, 0}}, 10_000
    assert os_observe(c) == "free,free,free"
  end
end
