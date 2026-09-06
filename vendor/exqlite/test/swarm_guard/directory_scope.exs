scratch = System.fetch_env!("SWARM_FEASIBILITY_ROOT")
Code.prepend_paths(Path.wildcard(Path.join(scratch, "lib/*/ebin")))
ExUnit.start()

defmodule ExqliteDirectoryScopeTest do
  use ExUnit.Case, async: false
  alias Exqlite.DirectoryScope, as: Scope

  setup do
    root = Path.join(System.fetch_env!("SWARM_FEASIBILITY_ROOT"), "directories-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    for path <- ["runtime", "data", "runtime/child"] do
      File.mkdir!(Path.join(root, path))
      File.chmod!(Path.join(root, path), 0o700)
    end
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, runtime: Path.join(root, "runtime"), data: Path.join(root, "data")}
  end

  defp open_pair(context) do
    {:ok, scope} = Scope.new()
    {:ok, runtime} = Scope.open_root(scope, context.runtime)
    {:ok, data} = Scope.open_root(scope, context.data)
    {scope, runtime, data}
  end

  defp os_lock(path) do
    script = """
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
    {output, 0} = System.cmd("python3", ["-c", script, path])
    String.trim(output)
  end

  defp set_fixture_mode!(path, mode) do
    {"", 0} =
      System.cmd("python3", [
        "-c",
        "import os,sys; os.chmod(sys.argv[1], int(sys.argv[2]))",
        path,
        Integer.to_string(mode)
      ])
  end

  defp await_closed(scope, attempts \\ 100)
  defp await_closed(scope, 0), do: assert(Scope.status(scope) == :closed)
  defp await_closed(scope, attempts) do
    if Scope.status(scope) != :closed do
      Process.sleep(10)
      await_closed(scope, attempts - 1)
    end
  end

  test "production exports admit opaque exact private directories and lock in order", context do
    assert {:module, Exqlite.Sqlite3NIF} = Code.ensure_loaded(Exqlite.Sqlite3NIF)
    assert function_exported?(Exqlite.Sqlite3NIF, :directory_scope_new, 0)
    {scope, runtime, data} = open_pair(context)
    assert is_reference(scope) and is_reference(runtime) and is_reference(data)
    assert {:ok, {:directory, _, _, _, 0o700}} = Scope.identity(runtime)
    assert {:ok, child} = Scope.open_child(runtime, "child")
    assert {:ok, {:directory, _, _, _, 0o700}} = Scope.identity(child)
    assert :ok = Scope.lock(scope, runtime, data)
    assert :ok = Scope.assert_locked(scope)
    assert {:error, :directory_already_locked} = Scope.lock(scope, runtime, data)
    assert os_lock(context.runtime) == "busy"
    assert os_lock(context.data) == "busy"
    assert :ok = Scope.close(scope)
    assert :ok = Scope.close(scope)
    assert :closed = Scope.status(scope)
    assert {:error, :directory_scope_revoked} = Scope.identity(runtime)
    assert os_lock(context.runtime) == "acquired"
    assert os_lock(context.data) == "acquired"
  end

  test "unsafe modes, symlinks, files, invalid basenames and aliases refuse", context do
    {scope, runtime, data} = open_pair(context)
    for bad <- ["", ".", "..", "a/b", <<0>>, <<255>>] do
      assert {:error, :directory_invalid_basename} = Scope.open_child(runtime, bad)
    end
    File.write!(Path.join(context.runtime, "regular"), "fixture")
    File.ln_s!(context.data, Path.join(context.runtime, "symlink"))
    assert {:error, _} = Scope.open_child(runtime, "regular")
    assert {:error, _} = Scope.open_child(runtime, "symlink")
    assert {:error, :directory_alias} = Scope.lock(scope, runtime, runtime)
    {:ok, foreign} = Scope.new()
    assert {:error, :directory_wrong_scope} = Scope.lock(foreign, runtime, data)
    assert :ok = Scope.close(foreign)
    assert :ok = Scope.close(scope)
    try do
      for mode <- [0o755, 0o770, 0o1700] do
        set_fixture_mode!(context.data, mode)
        {os_mode_text, 0} =
          System.cmd("python3", [
            "-c",
            "import os,stat,sys; print(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode))",
            context.data
          ])

        os_mode = os_mode_text |> String.trim() |> String.to_integer()
        beam_mode = Bitwise.band(File.lstat!(context.data).mode, 0o7777)

        assert os_mode == mode,
               "fixture chmod requested 0o#{Integer.to_string(mode, 8)}, " <>
                 "OS observed 0o#{Integer.to_string(os_mode, 8)}, " <>
                 "BEAM observed 0o#{Integer.to_string(beam_mode, 8)}"

        {:ok, another} = Scope.new()

        try do
          assert {:error, :unsafe_private_directory} = Scope.open_root(another, context.data)
        after
          assert :ok = Scope.close(another)
        end
      end
    after
      set_fixture_mode!(context.data, 0o700)
    end
    assert_raise ArgumentError, fn -> Scope.open_child(make_ref(), "child") end
  end

  test "held-parent replacement revokes without opening replacement child", context do
    {scope, runtime, data} = open_pair(context)
    :ok = Scope.lock(scope, runtime, data)
    File.rename!(context.runtime, context.runtime <> "-held")
    File.mkdir!(context.runtime)
    File.chmod!(context.runtime, 0o700)
    File.mkdir!(Path.join(context.runtime, "child"))
    File.chmod!(Path.join(context.runtime, "child"), 0o700)
    assert {:error, :directory_binding_changed} = Scope.open_child(runtime, "child")
    await_closed(scope)
    assert os_lock(context.runtime <> "-held") == "acquired"
    assert os_lock(context.data) == "acquired"
  end

  test "owner death revokes copied capabilities and releases real OS locks", context do
    receiver = self()
    {owner, monitor} = spawn_monitor(fn ->
      {scope, runtime, data} = open_pair(context)
      :ok = Scope.lock(scope, runtime, data)
      send(receiver, {:resources, scope, runtime, data})
      receive do :stop -> :ok end
    end)
    assert_receive {:resources, scope, runtime, data}
    assert {:error, :directory_wrong_owner} = Scope.identity(runtime)
    assert {:error, :directory_wrong_owner} = Scope.lock(scope, runtime, data)
    assert os_lock(context.runtime) == "busy"
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    await_closed(scope)
    assert {:error, :directory_scope_revoked} = Scope.open_child(runtime, "child")
    assert os_lock(context.runtime) == "acquired"
    assert os_lock(context.data) == "acquired"
  end

  test "data contention releases runtime before reporting failure", context do
    executable = System.find_executable("python3")
    script = """
    import fcntl,os,sys
    fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    print('held',flush=True)
    sys.stdin.buffer.read(1)
    os.close(fd)
    """
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: ["-c", script, context.data]])
    assert_receive {^port, {:data, "held\n"}}, 5_000
    {scope, runtime, data} = open_pair(context)
    assert {:error, :foundation_lock_held} = Scope.lock(scope, runtime, data)
    assert os_lock(context.runtime) == "acquired"
    assert os_lock(context.data) == "busy"
    assert :ok = Scope.close(scope)
    Port.command(port, "x")
    assert_receive {^port, {:exit_status, 0}}, 5_000
  end

  test "runtime contention prevents holding the data lock", context do
    executable = System.find_executable("python3")
    script = """
    import fcntl,os,sys
    fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    print('held',flush=True)
    sys.stdin.buffer.read(1)
    os.close(fd)
    """
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: ["-c", script, context.runtime]])
    assert_receive {^port, {:data, "held\n"}}, 5_000
    {scope, runtime, data} = open_pair(context)
    assert {:error, :foundation_lock_held} = Scope.lock(scope, runtime, data)
    assert os_lock(context.runtime) == "busy"
    assert os_lock(context.data) == "acquired"
    assert :ok = Scope.close(scope)
    Port.command(port, "x")
    assert_receive {^port, {:exit_status, 0}}, 5_000
  end

  # Return no resource term to the caller. Keeping scope live through the receive
  # lets the test observe held locks before this helper's stack frame disappears.
  defp hold_pair_until_drop(context, receiver, ref) do
    {scope, runtime, data} = open_pair(context)
    :ok = Scope.lock(scope, runtime, data)
    send(receiver, {:held, ref})

    receive do
      {:drop, ^ref} -> :ok = Scope.assert_locked(scope)
    end

    :resources_dropped
  end

  defp alive_after_gc(receiver, ref) do
    receive do
      {:ping, ^ref} ->
        send(receiver, {:alive, ref})
        alive_after_gc(receiver, ref)

      {:finish, ^ref} ->
        :ok
    end
  end

  test "owner-alive GC without resource terms releases real directory locks", context do
    receiver = self()
    ref = make_ref()

    {owner, monitor} = spawn_monitor(fn ->
      :resources_dropped = hold_pair_until_drop(context, receiver, ref)
      true = :erlang.garbage_collect(self())
      send(receiver, {:gc_complete, ref})
      alive_after_gc(receiver, ref)
    end)

    try do
      assert_receive {:held, ^ref}
      assert os_lock(context.runtime) == "busy"
      assert os_lock(context.data) == "busy"
      send(owner, {:drop, ref})
      assert_receive {:gc_complete, ^ref}, 5_000
      assert Process.alive?(owner)

      # Neither explicit close nor owner death occurs before OS-observed release.
      assert Enum.reduce_while(1..100, nil, fn _, _ ->
        if os_lock(context.runtime) == "acquired" && os_lock(context.data) == "acquired" do
          {:halt, :released}
        else
          Process.sleep(10)
          {:cont, nil}
        end
      end) == :released

      send(owner, {:ping, ref})
      assert_receive {:alive, ^ref}
      assert Process.alive?(owner)
      refute_received {:DOWN, ^monitor, :process, ^owner, _}
    after
      send(owner, {:drop, ref})
      send(owner, {:finish, ref})
    end

    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
  end

  test "directory graph capacity bounds retained descriptors", context do
    {:ok, scope} = Scope.new()
    {:ok, runtime} = Scope.open_root(scope, context.runtime)
    attempts = for _ <- 1..128, do: Scope.open_child(runtime, "child")
    assert Enum.any?(attempts, &match?({:error, :directory_capacity}, &1))
    assert :ok = Scope.close(scope)
    assert os_lock(context.runtime) == "acquired"
  end
end
