defmodule SwarmCode.Daemon.RepoLauncherTest do
  # pass70 B1 (rel F1): a process killed while it holds a guarded checkout used
  # to crash its pooled connection (`:ok = disconnect(...)` MatchError) and pin
  # the native handle in the idle lease heap, so guarded cleanup never finished.
  use ExUnit.Case, async: false
  import Ecto.Query
  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Domain.Repo

  setup do
    source = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    database = Path.join(Path.dirname(source), "swarm_code.db")
    File.rename!(source, database)
    SchemaFixture.insert_project!(database, "project", "Before", "/fixture")
    root = Path.dirname(database)
    uid = File.stat!(root).uid

    boot = [
      platform: :linux,
      mode: :test,
      home: root,
      env:
        Map.new(
          ~w(XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR),
          &{&1, root}
        ),
      database_path: database,
      app_version: "0.1.0-dev",
      desktop_detector: fn -> :none end,
      directory_ensure: fn path, owner ->
        case File.mkdir(path) do
          :ok -> File.chmod!(path, 0o700)
          {:error, :eexist} -> :ok
        end

        SwarmCode.Daemon.Platform.PrivateDirectory.ensure(path, owner)
      end,
      identity: fn ->
        {:ok,
         %SwarmCode.Daemon.Platform.ProcessIdentity{
           uid: uid,
           pid: String.to_integer(System.pid()),
           process_start_id: "repo-launcher-test",
           boot_id: "repo-launcher-test"
         }}
      end
    ]

    %{boot: boot}
  end

  @tag timeout: 120_000
  test "killing a checkout holder keeps the pool live and close settles within 3 s", %{
    boot: boot
  } do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 4)
    Process.unlink(launcher)
    on_exit(fn -> if Process.alive?(launcher), do: Process.exit(launcher, :kill) end)
    assert {:ok, repo} = RepoLauncher.await_ready(launcher, 60_000)

    # Warm Ecto's query cache through every pooled connection, exactly like
    # the reproduction: cached queries are what pinned statements before.
    1..16
    |> Enum.map(fn _ -> Task.async(fn -> Repo.all(from(p in "projects", select: p.id)) end) end)
    |> Enum.each(&assert(["project"] = Task.await(&1, 15_000)))

    parent = self()

    holder =
      spawn(fn ->
        Repo.checkout(fn ->
          # A query first prepared on this connection is cached with a
          # statement of this connection, the case that made close refuse.
          Repo.all(from(p in "projects", where: p.name == "Before", select: p.name))
          send(parent, :holding)

          receive do
          after
            30_000 -> :ok
          end
        end)
      end)

    assert_receive :holding, 15_000
    monitor = Process.monitor(holder)
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}
    settle_pool(launcher, repo)

    # The pool keeps serving and the launcher never saw a fenced binding.
    assert [[1]] =
             Task.async(fn ->
               Repo.query!("SELECT count(*) FROM projects", [], timeout: 10_000).rows
             end)
             |> Task.await(15_000)

    assert %{phase: :live} = RepoLauncher.status(launcher)
    assert Process.alive?(repo)

    launcher_monitor = Process.monitor(launcher)
    {elapsed, result} = :timer.tc(fn -> RepoLauncher.close(launcher) end)
    assert result == :ok
    assert elapsed < 3_000_000, "close took #{div(elapsed, 1000)} ms"
    assert_receive {:DOWN, ^launcher_monitor, :process, ^launcher, :normal}, 5_000
    refute Process.whereis(Repo)
  end

  @tag timeout: 120_000
  test "a disconnect of every pooled connection still closes cleanly", %{boot: boot} do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 2)
    Process.unlink(launcher)
    on_exit(fn -> if Process.alive?(launcher), do: Process.exit(launcher, :kill) end)
    assert {:ok, repo} = RepoLauncher.await_ready(launcher, 60_000)

    Task.async(fn ->
      for _ <- 1..4, do: Repo.all(from(p in "projects", select: p.id))
      :ok = Ecto.Adapters.SQL.disconnect_all(repo, 0)
      assert [["project"]] = Repo.query!("SELECT id FROM projects", [], timeout: 10_000).rows
    end)
    |> Task.await(15_000)

    {elapsed, result} = :timer.tc(fn -> RepoLauncher.close(launcher) end)
    assert result == :ok
    assert elapsed < 3_000_000, "close took #{div(elapsed, 1000)} ms"
  end

  @tag timeout: 120_000
  test "a replaced connection's refused handle is retired, then closed at cleanup", %{
    boot: boot
  } do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 2)
    Process.unlink(launcher)
    on_exit(fn -> if Process.alive?(launcher), do: Process.exit(launcher, :kill) end)
    assert {:ok, _repo} = RepoLauncher.await_ready(launcher, 60_000)
    lease = :sys.get_state(launcher).lease
    %{pid: old_pid, db: db} = :sys.get_state(lease).slots[1]

    # A live statement makes SQLite refuse the close of this handle.
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, "SELECT 1")
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    replaced = await_slot(lease, 1, old_pid, 250)
    assert replaced.ready
    assert :sys.get_state(lease).retired == [db]

    :ok = Exqlite.Sqlite3.release(db, statement)
    {elapsed, result} = :timer.tc(fn -> RepoLauncher.close(launcher) end)
    assert result == :ok
    assert elapsed < 3_000_000, "close took #{div(elapsed, 1000)} ms"
  end

  defp await_slot(lease, slot, old_pid, attempts) do
    case :sys.get_state(lease).slots[slot] do
      %{pid: pid, ready: true} = entry when pid != old_pid ->
        entry

      _ when attempts > 0 ->
        receive do
        after
          20 -> await_slot(lease, slot, old_pid, attempts - 1)
        end

      other ->
        flunk("slot #{slot} was not re-authorized: #{inspect(other)}")
    end
  end

  # The pool learns about the dead client from its monitor and then tells the
  # connection to disconnect. A synchronous call to the pool, then to every
  # pooled connection, orders the test after both hops without sleeping.
  defp settle_pool(launcher, repo) do
    for {_, pool, _, _} <- Supervisor.which_children(repo), is_pid(pool) do
      sync(pool)
    end

    lease = :sys.get_state(launcher).lease

    for _round <- 1..2, {_, slot} <- :sys.get_state(lease).slots do
      sync(slot.pid)
    end

    :ok
  end

  # A connection that crashed (the pre-fix behaviour) is simply gone.
  defp sync(pid) do
    :sys.get_state(pid, 5_000)
  catch
    :exit, _ -> :ok
  end
end
