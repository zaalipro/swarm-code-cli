scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule LeaseCloseErrorTest do
  use ExUnit.Case, async: false
  alias Exqlite.{DirectoryScope, GuardedLease, Sqlite3NIF}

  setup do
    root = Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "lease-close-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    for name <- ["runtime", "data"] do
      File.mkdir!(Path.join(root, name))
      File.chmod!(Path.join(root, name), 0o700)
    end
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, scope} = DirectoryScope.new()
    {:ok, runtime} = DirectoryScope.open_root(scope, Path.join(root, "runtime"))
    {:ok, data} = DirectoryScope.open_root(scope, Path.join(root, "data"))
    :ok = DirectoryScope.lock(scope, runtime, data)
    %{root: root, scope: scope}
  end

  defp await_failed(scope, attempts \\ 100)
  defp await_failed(scope, 0), do: assert(DirectoryScope.status(scope) == :close_failed)
  defp await_failed(scope, attempts) do
    case DirectoryScope.status(scope) do
      :close_failed -> :ok
      :closed -> flunk("duplicate close error was silently reported as closed")
      _ ->
        Process.sleep(10)
        await_failed(scope, attempts - 1)
    end
  end

  defp assert_directory_locks_retained(root) do
    script = """
    import fcntl,os,sys
    for path in sys.argv[1:]:
      fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY)
      try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        print('free')
      except BlockingIOError:
        print('busy')
      finally:
        os.close(fd)
    """
    {output, 0} = System.cmd("python3", ["-c", script, Path.join(root, "runtime"), Path.join(root, "data")])
    assert String.split(output, "\n", trim: true) == ["busy", "busy"]
  end

  test "main duplicate close error is recorded rather than swallowed", c do
    {:ok, lease} = GuardedLease.acquire(c.scope)
    :ok = Sqlite3NIF.lease_test_close_fault(c.scope, :main_duplicate)
    result = GuardedLease.close(lease)
    assert Sqlite3NIF.lease_test_close_hits(c.scope) == 1
    assert {:error, :lease_close_failed} = result
    assert GuardedLease.status(lease) == :close_failed
    await_failed(c.scope)
    assert_directory_locks_retained(c.root)
  end

  test "journal duplicate close error during bootstrap prevents clean acquisition", c do
    :ok = Sqlite3NIF.lease_test_close_fault(c.scope, :journal_duplicate)
    result = GuardedLease.acquire(c.scope)
    assert Sqlite3NIF.lease_test_close_hits(c.scope) == 1
    assert {:error, :lease_acquisition_failed} = result
    await_failed(c.scope)
    assert_directory_locks_retained(c.root)
  end

  test "failed-open duplicate cleanup preserves its close error", c do
    :ok = Sqlite3NIF.lease_test_close_fault(c.scope, :failed_main_open)
    assert {:error, :lease_acquisition_failed} = GuardedLease.acquire(c.scope)
    assert Sqlite3NIF.lease_test_close_hits(c.scope) == 1
    await_failed(c.scope)
    assert_directory_locks_retained(c.root)
  end
end
