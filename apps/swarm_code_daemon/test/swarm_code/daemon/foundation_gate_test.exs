defmodule SwarmCode.Daemon.FoundationGateTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.FoundationGate
  alias SwarmCode.Daemon.Platform.{DatabaseFingerprint, PrivateDirectory, ProcessIdentity}
  alias SwarmCode.Daemon.StartupError

  @app_version "0.1.0-dev"
  @backup_operation_id "5cebddf0-68ee-4f79-9129-b17f1ca2d6de"
  @manifest_sha256 "16c5bb6d88c007fad7042c6f13afa65455a8a6157e2e86c25d68748d7c984e82"
  @newest_migration 20_261_015_000_003
  @now ~U[2026-09-01 12:00:00Z]

  test "database fingerprint contract has a canonical distinct absent-path marker" do
    root = private_tmp!("absent-fingerprint-contract")
    absent = Path.join(root, "absent.db")

    assert {:ok, first} = DatabaseFingerprint.for_absent_path(absent)
    assert {:ok, ^first} = DatabaseFingerprint.for_absent_path(Path.join(root, "./absent.db"))
    assert String.starts_with?(first, "sqlite-absent-v1:")
    refute File.exists?(absent)

    File.write!(absent, <<>>)
    File.chmod!(absent, 0o600)
    assert {:error, :database_path_present} = DatabaseFingerprint.for_absent_path(absent)
  end

  test "lease publication refusal preserves abnormal cleanup uncertainty" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    File.mkdir!(Path.join(root, "instance_owner.json"))
    barrier = fn -> raise "private cleanup failure" end
    opts = test_opts(fixture, fn -> :none end, lease_options: [cleanup_barrier: barrier])

    assert {:error, %StartupError{code: :lease_failed} = error} = FoundationGate.prepare(opts)
    assert error.message =~ "native settlement is unconfirmed"
    refute error.message =~ "private cleanup failure"
    assert File.dir?(Path.join(root, "instance_owner.json"))
    File.rmdir!(Path.join(root, "instance_owner.json"))
    assert_reacquirable!(opts)
  end

  test "foundation orders identity, private directories, detection, lease, and schema without Repo" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    test = self()

    identity = fn ->
      send(test, {:stage, :identity, File.exists?(Path.join(root, "swarm-code"))})
      {:ok, identity(root)}
    end

    directory_ensure = fn path, uid ->
      send(test, {:stage, :directory, path})
      test_directory_ensure(path, uid)
    end

    counter = :counters.new(1, [])

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)

      send(
        test,
        {:stage, :detector, call, File.exists?(Path.join(root, "instance_lease.db"))}
      )

      :none
    end

    assert {:ok, ready} =
             FoundationGate.prepare(
               test_opts(fixture, detector,
                 identity: identity,
                 directory_ensure: directory_ensure
               )
             )

    assert ready.paths.database == fixture
    assert ready.identity == identity(root)
    assert ready.schema.status == :ready
    assert ready.backup == nil
    assert length(ready.schema.applied) == 53
    assert List.last(ready.schema.applied) == @newest_migration
    owner = CrossAppLease.owner(ready.lease)
    assert owner.schema_epoch == 0
    assert owner.newest_migration == @newest_migration
    assert owner.manifest_sha256 == @manifest_sha256
    assert :ok = CrossAppLease.assert_held(ready.lease)
    assert self() in (Process.info(ready.lease, :links) |> elem(1))
    refute Process.whereis(SwarmCode.Repo)

    assert_receive {:stage, :identity, false}

    directory_messages = receive_directory_messages([])

    assert directory_messages ==
             [root, Path.join(root, "backups"), Path.join(root, "swarm-code")]

    assert_receive {:stage, :detector, 1, false}
    assert_receive {:stage, :detector, 2, true}
    refute_received {:stage, _, _, _}

    GenServer.stop(ready.lease)
  end

  test "path resolution fails before the trusted identity callback" do
    fixture = fixture_database!(:current)
    test = self()

    identity = fn ->
      send(test, :identity_called)
      {:ok, identity(Path.dirname(fixture))}
    end

    opts =
      test_opts(fixture, fn -> :none end,
        identity: identity,
        env: %{"XDG_DATA_HOME" => "relative"}
      )

    assert {:error, %{code: :path_resolution_failed}} = FoundationGate.prepare(opts)
    refute_received :identity_called
  end

  test "a symlink XDG ancestor is rejected before any child is created" do
    root = private_tmp!("symlink-ancestor")
    target = private_tmp!("symlink-target")
    alias_root = Path.join(root, "data-alias")
    File.ln_s!(target, alias_root)
    database = Path.join(alias_root, "fixture.db")

    assert {:error, %{code: :private_directory_failed}} =
             FoundationGate.prepare(
               test_opts(database, fn -> :none end,
                 env: %{
                   "XDG_DATA_HOME" => alias_root,
                   "XDG_CONFIG_HOME" => root,
                   "XDG_STATE_HOME" => root,
                   "XDG_CACHE_HOME" => root,
                   "XDG_RUNTIME_DIR" => root
                 }
               )
             )

    refute File.exists?(Path.join(target, "swarm-code"))
  end

  test "product-owned directories are deduplicated and hardened parent before child" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    state_root = Path.join(root, "state-root")
    File.mkdir!(state_root)
    File.chmod!(state_root, 0o700)
    test = self()

    directory_ensure = fn path, uid ->
      send(test, {:ensured, path})
      test_directory_ensure(path, uid)
    end

    opts =
      test_opts(fixture, fn -> :none end,
        env: %{
          "XDG_DATA_HOME" => root,
          "XDG_CONFIG_HOME" => root,
          "XDG_STATE_HOME" => state_root,
          "XDG_CACHE_HOME" => root
        },
        directory_ensure: directory_ensure
      )

    assert {:ok, ready} = FoundationGate.prepare(opts)
    ensured = receive_ensured_messages([])

    state = Path.join(state_root, "swarm-code")
    runtime = Path.join(state, "run")
    assert Enum.find_index(ensured, &(&1 == state)) < Enum.find_index(ensured, &(&1 == runtime))
    assert ensured == Enum.uniq(ensured)

    assert Enum.sort(ensured) ==
             Enum.sort([
               root,
               Path.join(root, "swarm-code"),
               state,
               runtime,
               Path.join(root, "backups")
             ])

    GenServer.stop(ready.lease)
  end

  test "desktop refusal happens before lease or canonical database access" do
    root = private_tmp!("desktop-first")
    database = Path.join(root, "must-not-exist.db")
    detector = fn -> {:active, %{pid: 731, application: "SwarmCode"}} end

    assert {:error, %{code: :desktop_active}} =
             FoundationGate.prepare(test_opts(database, detector))

    refute File.exists?(database)
    refute File.exists?(Path.join(root, "instance_lease.db"))
    refute File.exists?(Path.join(root, "instance_owner.json"))
  end

  test "post-acquire desktop refusal releases the lease and waits for terminal cleanup" do
    fixture = fixture_database!(:current)
    test = self()
    counter = :counters.new(1, [])

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: :none,
        else: {:active, %{pid: 732, application: "SwarmCode"}}
    end

    cleanup_barrier = fn ->
      send(test, {:lease_cleanup_started, self()})

      receive do
        :finish_lease_cleanup -> :ok
      end
    end

    opts =
      test_opts(fixture, detector, lease_options: [cleanup_barrier: cleanup_barrier])

    task = Task.async(fn -> FoundationGate.prepare(opts) end)
    assert_receive {:lease_cleanup_started, lease}, 10_000
    lease_monitor = Process.monitor(lease)
    send(lease, :finish_lease_cleanup)

    assert {:error, %{code: :desktop_active} = error} = Task.await(task)
    refute error.message =~ "abnormal cleanup"
    refute error.action =~ "stale diagnostic owner record"
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :normal}
    assert_reacquirable!(opts)
  end

  @tag capture_log: true
  test "blocking lease termination cannot kill the prepare caller or mask its primary error" do
    fixture = fixture_database!(:current)
    parent = self()
    counter = :counters.new(1, [])
    task_supervisor = start_supervised!(Task.Supervisor)

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: :none,
        else: {:active, %{pid: 734, application: "SwarmCode"}}
    end

    cleanup_barrier = fn ->
      send(parent, {:blocking_cleanup_started, self()})

      receive do
        :never -> :ok
      end
    end

    opts = test_opts(fixture, detector, lease_options: [cleanup_barrier: cleanup_barrier])

    assert {:ok, caller} =
             Task.Supervisor.start_child(task_supervisor, fn ->
               result = FoundationGate.prepare(opts)
               send(parent, {:prepare_result, self(), result})

               receive do
                 :finish_prepare -> :ok
               end
             end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:blocking_cleanup_started, lease}, 10_000
    lease_monitor = Process.monitor(lease)

    assert_receive {:prepare_result, ^caller, {:error, %StartupError{} = error}}, 10_000
    assert error.code == :desktop_active
    assert error.message =~ "abnormal cleanup"
    assert error.message =~ "native settlement is unconfirmed"
    assert error.action =~ "stale diagnostic owner record"
    refute_received {:DOWN, ^caller_monitor, :process, ^caller, _reason}

    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 1_000
    send(caller, :finish_prepare)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
  end

  test "caller death during blocked lease cleanup still terminates the linked lease" do
    fixture = fixture_database!(:current)
    parent = self()
    counter = :counters.new(1, [])
    task_supervisor = start_supervised!(Task.Supervisor)

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: :none,
        else: {:active, %{pid: 736, application: "SwarmCode"}}
    end

    cleanup_barrier = fn ->
      send(parent, {:caller_death_cleanup_started, self()})

      receive do
        :never -> :ok
      end
    end

    opts = test_opts(fixture, detector, lease_options: [cleanup_barrier: cleanup_barrier])

    assert {:ok, caller} =
             Task.Supervisor.start_child(task_supervisor, fn ->
               _ = FoundationGate.prepare(opts)
               send(parent, {:unexpected_prepare_return, self()})
             end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:caller_death_cleanup_started, lease}, 10_000
    lease_monitor = Process.monitor(lease)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 1_000
    refute_received :unexpected_prepare_return
    refute File.exists?(Path.join(Path.dirname(fixture), "instance_owner.json"))
    assert_reacquirable!(opts)
  end

  test "unrelated linked exits received during lease cleanup retain their caller semantics" do
    fixture = fixture_database!(:current)
    parent = self()
    counter = :counters.new(1, [])
    task_supervisor = start_supervised!(Task.Supervisor)

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: :none,
        else: {:active, %{pid: 737, application: "SwarmCode"}}
    end

    cleanup_barrier = fn ->
      send(parent, {:unrelated_exit_cleanup_started, self()})

      receive do
        :finish_unrelated_exit_cleanup -> :ok
      end
    end

    opts = test_opts(fixture, detector, lease_options: [cleanup_barrier: cleanup_barrier])

    assert {:ok, caller} =
             Task.Supervisor.start_child(task_supervisor, fn ->
               sentinel =
                 spawn_link(fn ->
                   send(parent, {:unrelated_exit_link_ready, self()})

                   receive do
                     :die_unrelated -> exit(:unrelated_link_failure)
                   end
                 end)

               send(parent, {:unrelated_exit_caller_ready, self(), sentinel})

               result = FoundationGate.prepare(opts)
               send(parent, {:unexpected_unrelated_exit_result, self(), result})
             end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:unrelated_exit_caller_ready, ^caller, sentinel}, 10_000
    sentinel_monitor = Process.monitor(sentinel)
    assert_receive {:unrelated_exit_link_ready, ^sentinel}, 10_000
    assert_receive {:unrelated_exit_cleanup_started, lease}, 10_000
    lease_monitor = Process.monitor(lease)

    send(sentinel, :die_unrelated)
    assert_receive {:DOWN, ^sentinel_monitor, :process, ^sentinel, :unrelated_link_failure}, 1_000

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :unrelated_link_failure}, 1_000
    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, :killed}, 1_000
    refute_received {:unexpected_unrelated_exit_result, ^caller, _result}
    assert_reacquirable!(opts)
  end

  @tag capture_log: true
  test "raising lease termination callback returns the primary static error and terminal evidence" do
    fixture = fixture_database!(:current)
    parent = self()
    counter = :counters.new(1, [])
    task_supervisor = start_supervised!(Task.Supervisor)

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: :none,
        else: {:active, %{pid: 735, application: "SwarmCode"}}
    end

    cleanup_barrier = fn ->
      send(parent, {:raising_cleanup_started, self()})

      receive do
        :raise_cleanup -> raise "untrusted cleanup callback detail"
      end
    end

    opts = test_opts(fixture, detector, lease_options: [cleanup_barrier: cleanup_barrier])

    assert {:ok, caller} =
             Task.Supervisor.start_child(task_supervisor, fn ->
               result = FoundationGate.prepare(opts)
               send(parent, {:raising_prepare_result, self(), result})

               receive do
                 :finish_prepare -> :ok
               end
             end)

    caller_monitor = Process.monitor(caller)
    assert_receive {:raising_cleanup_started, lease}, 10_000
    lease_monitor = Process.monitor(lease)
    send(lease, :raise_cleanup)

    assert_receive {:raising_prepare_result, ^caller, {:error, %StartupError{} = error}}, 10_000
    assert error.code == :desktop_active
    assert error.message =~ "abnormal cleanup"
    assert error.message =~ "native settlement is unconfirmed"
    assert error.action =~ "stale diagnostic owner record"
    refute error.message =~ "untrusted cleanup callback detail"
    refute error.action =~ "untrusted cleanup callback detail"
    refute_received {:DOWN, ^caller_monitor, :process, ^caller, _reason}

    assert_receive {:DOWN, ^lease_monitor, :process, ^lease, lease_reason}, 1_000
    refute lease_reason == :normal
    send(caller, :finish_prepare)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
  end

  test "a malformed second detector result is normalized and releases the acquired lease" do
    fixture = fixture_database!(:current)
    counter = :counters.new(1, [])

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: :none,
        else: exit(:untrusted_second_detector_exit)
    end

    opts = test_opts(fixture, detector)

    assert {:error, error} = FoundationGate.prepare(opts)
    assert error.code == :macos_platform_helper_unavailable
    refute error.message =~ "untrusted"
    refute error.action =~ "untrusted"
    assert_reacquirable!(opts)
  end

  test "lease contention preserves the typed refusal and the live owner's lease" do
    fixture = fixture_database!(:current)
    opts = test_opts(fixture, fn -> :none end)
    assert {:ok, ready} = FoundationGate.prepare(opts)

    assert {:error, error} = FoundationGate.prepare(opts)
    assert error.code == :data_lease_held
    assert error.retryable
    assert :ok = CrossAppLease.assert_held(ready.lease)

    GenServer.stop(ready.lease)
  end

  test "existing and absent canonical databases receive distinct versioned fingerprints" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    test = self()
    existing_detector = observing_detector(root, test, :existing_fingerprint)

    assert {:ok, ready} = FoundationGate.prepare(test_opts(fixture, existing_detector))
    assert_receive {:existing_fingerprint, fingerprint}
    assert {:ok, ^fingerprint} = DatabaseFingerprint.for_path(fixture)
    assert String.starts_with?(fingerprint, "sqlite-file-v1:")
    GenServer.stop(ready.lease)

    absent_root = private_tmp!("absent-fingerprint")
    absent = Path.join(absent_root, "new.db")
    absent_detector = observing_detector(absent_root, test, :absent_fingerprint)

    assert {:error, %{code: :new_database_implementation_not_installed}} =
             FoundationGate.prepare(test_opts(absent, absent_detector))

    assert_receive {:absent_fingerprint, absent_fingerprint}
    assert String.starts_with?(absent_fingerprint, "sqlite-absent-v1:")
    refute absent_fingerprint == fingerprint
    refute File.exists?(absent)
    assert File.ls!(Path.join(absent_root, "backups")) == []
    assert_reacquirable!(test_opts(absent, fn -> :none end), absent_fingerprint)
  end

  test "an unsafe canonical database fails fingerprinting before lease acquisition" do
    root = private_tmp!("unsafe-database")
    database = Path.join(root, "database-as-directory")
    File.mkdir!(database)
    File.chmod!(database, 0o700)
    counter = :counters.new(1, [])

    detector = fn ->
      :counters.add(counter, 1, 1)
      :none
    end

    assert {:error, %{code: :database_fingerprint_failed}} =
             FoundationGate.prepare(test_opts(database, detector))

    assert :counters.get(counter, 1) == 1
    refute File.exists?(Path.join(root, "instance_lease.db"))
  end

  test "lease diagnostic contract is compile-time pinned and manifest loads after second detection" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    manifest_copy = Path.join(root, "manifest.json")
    File.write!(manifest_copy, "not-json")
    File.chmod!(manifest_copy, 0o600)
    test = self()
    counter = :counters.new(1, [])

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          :none

        2 ->
          owner = root |> Path.join("instance_owner.json") |> File.read!() |> Jason.decode!()
          send(test, {:lease_contract, owner})
          File.cp!(bundled_manifest_path(), manifest_copy)
          :none
      end
    end

    assert {:ok, ready} =
             FoundationGate.prepare(test_opts(fixture, detector, manifest_path: manifest_copy))

    assert_receive {:lease_contract, owner}
    assert owner["schema_epoch"] == 0
    assert owner["newest_migration"] == @newest_migration
    assert owner["manifest_sha256"] == @manifest_sha256
    GenServer.stop(ready.lease)
  end

  test "a database replacement after lease acquisition fails before manifest/schema access" do
    fixture = fixture_database!(:current)
    replacement = fixture_database!(:current)
    root = Path.dirname(fixture)
    parked = Path.join(root, "parked-original.db")
    counter = :counters.new(1, [])

    detector = fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 2 do
        File.rename!(fixture, parked)
        File.rename!(replacement, fixture)
      end

      :none
    end

    opts = test_opts(fixture, detector)
    assert {:error, %{code: :database_fingerprint_changed}} = FoundationGate.prepare(opts)
    refute File.exists?(Path.join(root, "instance_owner.json"))
    assert_reacquirable!(opts)
  end

  test "invalid bundled manifest fails closed after acquisition and releases the lease" do
    fixture = fixture_database!(:current)
    manifest_copy = Path.join(Path.dirname(fixture), "invalid-manifest.json")
    File.write!(manifest_copy, ~s({"manifest_version":1}))
    File.chmod!(manifest_copy, 0o600)
    counter = :counters.new(1, [])

    detector = fn ->
      :counters.add(counter, 1, 1)
      :none
    end

    opts = test_opts(fixture, detector, manifest_path: manifest_copy)

    assert {:error, %{code: :migration_manifest_invalid}} = FoundationGate.prepare(opts)
    assert :counters.get(counter, 1) == 2
    assert_reacquirable!(opts)
  end

  test "schema incompatibility is read-only, creates no backup, and releases the lease" do
    fixture = fixture_database!(:current)
    SchemaFixture.delete_migration!(fixture, @newest_migration)
    before = database_state(fixture)
    opts = test_opts(fixture, fn -> :none end)

    assert {:error, %{code: :schema_incompatible}} = FoundationGate.prepare(opts)
    assert database_state(fixture) == before
    assert File.ls!(Path.join(Path.dirname(fixture), "backups")) == []
    assert_reacquirable!(opts)
  end

  test "migration-required creates and retains one verified artifact, then refuses implementation" do
    fixture = fixture_database!({:prefix, 20_260_924_000_000})
    before = database_state(fixture)
    opts = test_opts(fixture, fn -> :none end)
    backup_dir = Path.join(Path.dirname(fixture), "backups")
    database_backup = Path.join(backup_dir, @backup_operation_id <> ".sqlite3")
    manifest_backup = Path.join(backup_dir, @backup_operation_id <> ".manifest.json")

    assert {:error, error} = FoundationGate.prepare(opts)
    assert error.code == :migration_implementation_not_installed
    assert error.action =~ @backup_operation_id <> ".sqlite3"
    assert error.action =~ @backup_operation_id <> ".manifest.json"
    assert File.exists?(database_backup)
    assert File.exists?(manifest_backup)
    assert permissions(database_backup) == 0o600
    assert permissions(manifest_backup) == 0o600
    assert database_state(fixture) == before
    assert_reacquirable!(opts)

    entries = File.ls!(backup_dir) |> Enum.sort()

    assert {:error, %{code: :migration_implementation_not_installed}} =
             FoundationGate.prepare(opts)

    assert File.ls!(backup_dir) |> Enum.sort() == entries
    assert database_state(fixture) == before
  end

  test "the legacy 43-migration prefix is backed up before refusing the ten appended migrations" do
    fixture = fixture_database!({:prefix, 20_260_926_000_000})

    SchemaFixture.insert_project!(
      fixture,
      "legacy-project",
      "Retained project",
      "/private/legacy"
    )

    before = database_state(fixture)
    manifest = SwarmCode.Daemon.Schema.MigrationManifest.load!()
    assert {:ok, decision} = SwarmCode.Daemon.Schema.Gate.check(fixture, manifest, @app_version)
    assert decision.status == :migration_required

    assert Enum.map(decision.pending, & &1.version) == [
             20_260_927_000_000,
             20_260_928_000_000,
             20_260_929_000_000,
             20_260_930_000_000,
             20_261_001_000_000,
             20_261_001_000_001,
             20_261_015_000_000,
             20_261_015_000_001,
             20_261_015_000_002,
             20_261_015_000_003
           ]

    opts = test_opts(fixture, fn -> :none end)

    assert {:error, %{code: :migration_implementation_not_installed}} =
             FoundationGate.prepare(opts)

    backup_dir = Path.join(Path.dirname(fixture), "backups")
    backup = Path.join(backup_dir, @backup_operation_id <> ".sqlite3")
    backup_manifest = File.read!(Path.join(backup_dir, @backup_operation_id <> ".manifest.json"))
    assert {:ok, decoded} = SwarmCode.Daemon.Backup.Manifest.decode(backup_manifest)
    assert length(decoded["migrations"]) == 43
    assert decoded["migrations"] == decision.applied
    assert decoded["independent_restore"]["migrations"] == decision.applied
    assert decoded["independent_restore"]["verified"] == true
    assert decoded["row_counts"] == SchemaFixture.row_counts(fixture)
    assert SchemaFixture.row_counts(backup) == SchemaFixture.row_counts(fixture)
    assert {:ok, restored_probe} = SwarmCode.Daemon.Schema.Probe.inspect(backup)
    assert restored_probe.quick_check == [["ok"]]
    assert restored_probe.foreign_key_violations == []
    assert restored_probe.migration_versions == decision.applied
    {:ok, conn} = Exqlite.Sqlite3.open(backup, mode: :readonly)

    try do
      assert SwarmCode.Daemon.Schema.SqliteQuery.rows(
               conn,
               "SELECT id, name, root_path FROM projects",
               [],
               max_rows: 1
             ) ==
               [["legacy-project", "Retained project", "/private/legacy"]]
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end

    assert database_state(fixture) == before
    refute Process.whereis(SwarmCode.Repo)
    assert_reacquirable!(opts)
  end

  test "backup failure preserves the source and leaves no artifact while releasing the lease" do
    fixture = fixture_database!({:prefix, 20_260_924_000_000})
    before = database_state(fixture)

    opts =
      test_opts(fixture, fn -> :none end, backup_options: [fault: :before_publish])

    assert {:error, %{code: :backup_failed}} = FoundationGate.prepare(opts)
    assert database_state(fixture) == before
    assert File.ls!(Path.join(Path.dirname(fixture), "backups")) == []
    assert_reacquirable!(opts)
  end

  test "production Linux detector is a no-op while injected macOS detection is honored" do
    linux_fixture = fixture_database!(:current)
    linux_opts = test_opts(linux_fixture, :default)
    assert {:ok, linux_ready} = FoundationGate.prepare(linux_opts)
    GenServer.stop(linux_ready.lease)

    mac_fixture = fixture_database!(:current)
    mac_root = Path.dirname(mac_fixture)
    prepare_macos_parents!(mac_root)

    mac_opts =
      test_opts(mac_fixture, fn -> {:active, %{pid: 900, application: "SwarmCode"}} end,
        platform: :macos,
        home: mac_root,
        env: %{"TMPDIR" => mac_root}
      )

    assert {:error, %{code: :desktop_active}} = FoundationGate.prepare(mac_opts)
    refute File.exists?(Path.join(mac_root, "instance_lease.db"))
  end

  test "macOS refuses before leasing when the signed detector helper is unavailable" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    prepare_macos_parents!(root)

    opts =
      test_opts(fixture, fn -> {:error, :macos_platform_helper_unavailable} end,
        platform: :macos,
        home: root,
        env: %{"TMPDIR" => root}
      )

    assert {:error, %{code: :macos_platform_helper_unavailable}} =
             FoundationGate.prepare(opts)

    refute File.exists?(Path.join(root, "instance_lease.db"))
  end

  test "macOS validates the existing product cache parent before its CLI child" do
    fixture = fixture_database!(:current)
    root = Path.dirname(fixture)
    prepare_macos_parents!(root)
    cache_parent = Path.join([root, "Library", "Caches", "SwarmCode"])
    File.mkdir!(cache_parent)
    File.chmod!(cache_parent, 0o755)

    opts =
      test_opts(fixture, fn -> :none end,
        platform: :macos,
        home: root,
        env: %{"TMPDIR" => root}
      )

    case FoundationGate.prepare(opts) do
      {:error, error} ->
        assert error.code == :private_directory_failed

      {:ok, ready} ->
        GenServer.stop(ready.lease)
        flunk("an existing mode-0755 product cache parent was not validated")
    end

    assert permissions(cache_parent) == 0o755
  end

  test "detector errors, exits, throws, and malformed metadata return one static helper error" do
    runtime_key = "foundation-runtime-key-#{System.unique_integer([:positive, :monotonic])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(runtime_key) end

    callbacks = [
      fn -> {:error, :helper_failed_with_untrusted_detail} end,
      fn -> {:error, :timeout} end,
      fn -> raise "untrusted detector exception" end,
      fn -> exit(:untrusted_detector_exit) end,
      fn -> throw(:untrusted_detector_throw) end,
      fn -> :malformed end,
      fn -> {:active, %{pid: 0, application: "SwarmCode"}} end,
      fn -> {:active, %{pid: 99, application: 12}} end,
      fn -> {:active, %{pid: 99, application: "SwarmCode", uid: 9_999_999}} end,
      fn -> {:active, %{runtime_key => true, pid: 99, application: "SwarmCode"}} end
    ]

    Enum.each(callbacks, fn callback ->
      root = private_tmp!("detector-failure")
      database = Path.join(root, "new.db")

      assert {:error, error} = FoundationGate.prepare(test_opts(database, callback))
      assert error.code == :macos_platform_helper_unavailable
      refute error.message =~ "untrusted"
      refute error.action =~ "untrusted"
      refute File.exists?(Path.join(root, "instance_lease.db"))
    end)

    assert_raise ArgumentError, fn -> String.to_existing_atom(runtime_key) end
  end

  test "identity callback failures are static and happen before private directory creation" do
    callbacks = [
      fn -> {:error, :untrusted_identity_detail} end,
      fn -> raise "untrusted identity exception" end,
      fn -> exit(:untrusted_identity_exit) end,
      fn -> throw(:untrusted_identity_throw) end,
      fn -> {:ok, :malformed} end
    ]

    Enum.each(callbacks, fn callback ->
      root = private_tmp!("identity-failure")
      database = Path.join(root, "new.db")
      opts = test_opts(database, fn -> :none end, identity: callback)

      assert {:error, error} = FoundationGate.prepare(opts)
      assert error.code == :process_identity_unavailable
      refute error.message =~ "untrusted"
      refute error.action =~ "untrusted"
      refute File.exists?(Path.join(root, "backups"))
      refute File.exists?(Path.join(root, "swarm-code"))
    end)
  end

  test "a malformed directory or clock callback becomes a static error and never leaks a lease" do
    fixture = fixture_database!(:current)

    assert {:error, directory_error} =
             FoundationGate.prepare(
               test_opts(fixture, fn -> :none end,
                 directory_ensure: fn _path, _uid -> :malformed end
               )
             )

    assert directory_error.code == :private_directory_failed

    migration_fixture = fixture_database!({:prefix, 20_260_924_000_000})

    opts =
      test_opts(migration_fixture, fn -> :none end,
        clock: fn -> raise "untrusted clock exception" end
      )

    assert {:error, clock_error} = FoundationGate.prepare(opts)
    assert clock_error.code == :backup_failed
    refute clock_error.message =~ "untrusted"
    refute clock_error.action =~ "untrusted"
    assert_reacquirable!(opts)
  end

  defp fixture_database!(lineage) do
    SchemaFixture.database!(lineage, SwarmCode.Daemon.Test.LeaseFixture.build_root())
  end

  defp test_opts(database, detector, overrides \\ []) do
    root = Path.dirname(database)

    defaults = [
      platform: :linux,
      mode: :test,
      home: root,
      env: %{
        "XDG_DATA_HOME" => root,
        "XDG_CONFIG_HOME" => root,
        "XDG_STATE_HOME" => root,
        "XDG_CACHE_HOME" => root,
        "XDG_RUNTIME_DIR" => root
      },
      database_path: database,
      app_version: @app_version,
      identity: fn -> {:ok, identity(root)} end,
      directory_ensure: &test_directory_ensure/2,
      clock: fn -> @now end,
      backup_operation_id: @backup_operation_id
    ]

    defaults =
      if detector == :default, do: defaults, else: [{:desktop_detector, detector} | defaults]

    Keyword.merge(defaults, overrides)
  end

  defp identity(path) do
    %ProcessIdentity{
      uid: File.lstat!(path).uid,
      pid: System.pid() |> String.to_integer(),
      process_start_id: "foundation-test-process",
      boot_id: "foundation-test-boot"
    }
  end

  defp observing_detector(root, test, tag) do
    counter = :counters.new(1, [])

    fn ->
      :ok = :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 2 do
        owner = root |> Path.join("instance_owner.json") |> File.read!() |> Jason.decode!()
        send(test, {tag, owner["database_fingerprint"]})
      end

      :none
    end
  end

  defp assert_reacquirable!(opts, fingerprint \\ nil) do
    database = Keyword.fetch!(opts, :database_path)
    root = Path.dirname(database)
    identity_callback = Keyword.fetch!(opts, :identity)
    {:ok, lease_identity} = identity_callback.()
    fingerprint = fingerprint || DatabaseFingerprint.for_path(database) |> elem(1)

    lease_opts = [
      paths: SwarmCode.Daemon.Test.LeaseFixture.paths(root, Path.join(root, "swarm-code")),
      identity: lease_identity,
      database_fingerprint: fingerprint,
      schema_contract: %{
        epoch: 0,
        newest_migration: @newest_migration,
        manifest_sha256: @manifest_sha256
      },
      app_version: @app_version
    ]

    assert {:ok, lease} = CrossAppLease.start_link(lease_opts)
    GenServer.stop(lease)
  end

  defp receive_directory_messages(paths) do
    receive do
      {:stage, :directory, path} -> receive_directory_messages([path | paths])
    after
      0 -> Enum.reverse(paths)
    end
  end

  defp receive_ensured_messages(paths) do
    receive do
      {:ensured, path} -> receive_ensured_messages([path | paths])
    after
      0 -> Enum.reverse(paths)
    end
  end

  defp database_state(database) do
    Map.new(["", "-wal", "-shm"], fn suffix ->
      path = database <> suffix

      value =
        case File.read(path) do
          {:ok, bytes} -> {:present, byte_size(bytes), :crypto.hash(:sha256, bytes)}
          {:error, :enoent} -> :absent
        end

      {suffix, value}
    end)
  end

  defp bundled_manifest_path do
    :swarm_code_daemon
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("schema/desktop-ccb1973.json")
  end

  defp private_tmp!(label) do
    path =
      Path.join(
        SwarmCode.Daemon.Test.LeaseFixture.build_root(),
        "swarm-code-foundation-#{label}-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp prepare_macos_parents!(root) do
    for path <- [
          Path.join([root, "Library", "Application Support"]),
          Path.join([root, "Library", "Logs"]),
          Path.join([root, "Library", "Caches"])
        ] do
      File.mkdir_p!(path)
    end
  end

  defp permissions(path), do: band(File.lstat!(path).mode, 0o7777)

  defp test_directory_ensure(path, uid) do
    case File.mkdir(path) do
      :ok -> File.chmod!(path, 0o700)
      {:error, :eexist} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "make directory", path: path
    end

    PrivateDirectory.ensure(path, uid)
  end
end
