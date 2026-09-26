defmodule SwarmCode.Daemon.GuardedRepoTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.{RepoLauncher, CrossAppLease, FoundationGate}
  alias SwarmCode.Domain.Repo

  setup context do
    source =
      SchemaFixture.database!(
        Map.get(context, :lineage, :current),
        SwarmCode.Daemon.Test.LeaseFixture.build_root()
      )

    database = Path.join(Path.dirname(source), "swarm_code.db")
    File.rename!(source, database)
    SchemaFixture.insert_project!(database, "project", "Before", "/fixture")
    if context[:absent], do: File.rm!(database)
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
           process_start_id: "guarded-test",
           boot_id: "guarded-test"
         }}
      end
    ]

    %{boot: boot, database: database}
  end

  @tag absent: true, timeout: 120_000
  test "absent database runs all audited migrations before publication and reopens", %{boot: boot} do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    assert {:ok, _repo} = RepoLauncher.await_ready(launcher, 90_000)

    Task.async(fn ->
      assert [[57]] = Repo.query!("SELECT count(*) FROM schema_migrations").rows

      assert %{num_rows: 1} =
               Repo.query!(
                 "INSERT INTO projects(id,name,root_path,inserted_at,updated_at) VALUES ('created','New','/fixture',datetime('now'),datetime('now'))"
               )
    end)
    |> Task.await(15_000)

    assert :ok = RepoLauncher.close(launcher)
    {:ok, next} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    assert {:ok, _} = RepoLauncher.await_ready(next, 60_000)

    Task.async(fn ->
      assert [["New"]] = Repo.query!("SELECT name FROM projects WHERE id='created'").rows
    end)
    |> Task.await()

    assert :ok = RepoLauncher.close(next)
  end

  @tag lineage: {:prefix, 20_261_015_000_003}, timeout: 120_000
  test "old schema is backed up and migrated without losing data", %{
    boot: boot,
    database: database
  } do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    assert {:ok, _} = RepoLauncher.await_ready(launcher, 90_000)

    Task.async(fn ->
      assert [[57]] = Repo.query!("SELECT count(*) FROM schema_migrations").rows
      assert [["Before"]] = Repo.query!("SELECT name FROM projects WHERE id='project'").rows
    end)
    |> Task.await()

    assert Path.wildcard(Path.join([Path.dirname(database), "**", "*.manifest.json"])) != []
    assert :ok = RepoLauncher.close(launcher)
  end

  @tag lineage: {:prefix, 20_261_015_000_003}, timeout: 120_000
  test "backup failure refuses migration without altering the existing database", %{
    boot: boot,
    database: database
  } do
    before = File.read!(database)
    refused_boot = Keyword.put(boot, :backup_options, fault: :after_snapshot)
    {:ok, launcher} = RepoLauncher.start_link(boot_config: refused_boot, pool_size: 3)
    assert {:error, %{code: :backup_failed}} = RepoLauncher.await_ready(launcher, 60_000)
    assert File.read!(database) == before
    refute Process.whereis(Repo)
    assert :ok = RepoLauncher.close(launcher)
    {:ok, next} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    assert {:ok, _} = RepoLauncher.await_ready(next, 90_000)
    assert :ok = RepoLauncher.close(next)
  end

  @tag timeout: 120_000
  test "real guarded pool writes, replaces connections, and survives launcher restart", %{
    boot: boot
  } do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    assert {:ok, repo} = RepoLauncher.await_ready(launcher, 60_000)

    Task.async(fn ->
      Repo.put_dynamic_repo(repo)
      assert %{num_rows: 1} = Repo.query!("UPDATE projects SET name='Saved' WHERE id='project'")
      :ok = Ecto.Adapters.SQL.disconnect_all(repo, 0)

      assert [["Saved"]] =
               Repo.query!("SELECT name FROM projects WHERE id='project'", [], timeout: 10_000).rows
    end)
    |> Task.await(15_000)

    assert %{phase: :live, initialized_slots: 3} = RepoLauncher.status(launcher)
    assert :ok = RepoLauncher.close(launcher)
    refute Process.alive?(repo)
    {:ok, next} = RepoLauncher.start_link(boot_config: boot, pool_size: 3)
    assert {:ok, next_repo} = RepoLauncher.await_ready(next, 60_000)

    Task.async(fn ->
      Repo.put_dynamic_repo(next_repo)
      assert [["Saved"]] = Repo.query!("SELECT name FROM projects WHERE id='project'").rows
    end)
    |> Task.await()

    assert :ok = RepoLauncher.close(next)
  end

  # cli74 F42 (found in the sandbox): Storage said "0 B on disk" on the guarded repo,
  # whose config never names the file.
  test "Storage measures the file the guarded repo has open", %{boot: boot, database: database} do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 1)
    assert {:ok, repo} = RepoLauncher.await_ready(launcher, 60_000)

    Task.async(fn ->
      Repo.put_dynamic_repo(repo)
      assert SwarmCode.Domain.Storage.file_bytes().db == File.stat!(database).size
      assert SwarmCode.Domain.Storage.file_bytes().db > 0
    end)
    |> Task.await(15_000)

    assert :ok = RepoLauncher.close(launcher)
    refute SwarmCode.Domain.Storage.db_path() == database
  end

  test "capability is creator-bound, opaque and consumed once", %{boot: boot} do
    {:ok, ready} = FoundationGate.prepare(boot)
    {:ok, capability} = FoundationGate.seal_ready(ready)
    assert {:error, :invalid_ready_capability} = CrossAppLease.consume(ready.lease, make_ref(), 2)
    task = Task.async(fn -> CrossAppLease.consume(ready.lease, capability, 2) end)
    assert {:error, :invalid_ready_capability} = Task.await(task)
    assert {:ok, _generation} = CrossAppLease.consume(ready.lease, capability, 2)
    assert {:error, :invalid_ready_capability} = CrossAppLease.consume(ready.lease, capability, 2)
    assert :ok = CrossAppLease.close_binding(ready.lease)
    GenServer.stop(ready.lease)
  end

  test "Repo refuses raw pathname and forged handoffs before file creation", %{database: database} do
    assert {:error, :guarded_database_required} = Repo.init(:supervisor, database: database)

    assert {:error, :guarded_database_required} =
             Repo.init(:supervisor, guarded_repo: {self(), make_ref()}, database: database)
  end

  test "coordinator death closes the pool before releasing the retained lease", %{boot: boot} do
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 2)
    Process.unlink(launcher)
    assert {:ok, repo} = RepoLauncher.await_ready(launcher)
    lease = :sys.get_state(launcher).lease
    repo_monitor = Process.monitor(repo)
    lease_monitor = Process.monitor(lease)
    Process.exit(launcher, :kill)

    assert_receive {:DOWN, ^repo_monitor, :process, ^repo, _}, 10_000
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, _}, 10_000
    refute Process.whereis(Repo)

    {:ok, next} = RepoLauncher.start_link(boot_config: boot, pool_size: 2)
    assert {:ok, _} = RepoLauncher.await_ready(next)
    assert :ok = RepoLauncher.close(next)
  end
end
