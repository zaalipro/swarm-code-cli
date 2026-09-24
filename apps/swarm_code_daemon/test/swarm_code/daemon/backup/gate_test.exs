defmodule SwarmCode.Daemon.Backup.GateTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  import Bitwise

  alias SwarmCode.Daemon.Backup.{Artifact, Gate, Manifest}
  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.Platform.{DatabaseFingerprint, ProcessIdentity}
  alias SwarmCode.Daemon.Schema.{MigrationManifest, Probe}
  alias SwarmCode.Daemon.Schema.Gate, as: SchemaGate

  @operation_id "c608e2b2-441d-45fc-ae80-42199f63ddff"
  @verified_at ~U[2026-09-01 12:00:00Z]
  @manifest_keys ~w(
    application
    application_id
    backup
    foreign_key_violations
    independent_restore
    manifest_version
    migrations
    operation_id
    quick_check
    row_counts
    rowid_proofs
    schema_sha256
    source
    sqlite_source_id
    sqlite_version
    verified_at
  )
  @independent_restore_keys ~w(
    application_id
    backup_sha256
    foreign_key_violations
    migrations
    quick_check
    row_counts
    rowid_proofs
    schema_sha256
    sqlite_source_id
    sqlite_version
    verified
  )

  test "verified artifact is closed, complete, private, and independently restorable" do
    fixture = migration_fixture!()
    before = source_state(fixture.db)

    assert {:ok, artifact} = create(fixture)
    assert artifact.__struct__ == Artifact
    assert artifact.operation_id == @operation_id
    assert artifact.verified_at == "2026-09-01T12:00:00Z"
    assert permissions(artifact.database) == 0o600
    assert permissions(artifact.manifest) == 0o600
    assert source_state(fixture.db) == before

    manifest = decode_manifest!(artifact.manifest)
    assert Enum.sort(Map.keys(manifest)) == Enum.sort(@manifest_keys)
    assert manifest["manifest_version"] == 1
    assert manifest["operation_id"] == @operation_id
    assert manifest["verified_at"] == "2026-09-01T12:00:00Z"
    assert manifest["application"] == %{"name" => "swarm_code_daemon", "version" => "0.1.0-dev"}
    assert manifest["quick_check"] == "ok"
    assert manifest["foreign_key_violations"] == []
    assert manifest["row_counts"] == SchemaFixture.row_counts(fixture.db)
    assert manifest["migrations"] == fixture.decision.probe.migration_versions
    assert manifest["schema_sha256"] == fixture.decision.probe.schema_sha256
    assert manifest["application_id"] == fixture.decision.probe.application_id
    assert manifest["sqlite_version"] == fixture.decision.probe.sqlite_version
    assert manifest["sqlite_source_id"] == fixture.decision.probe.sqlite_source_id

    assert manifest["rowid_proofs"]["projects"] == %{
             "count" => 2,
             "first_rowid_sha256" => rowid_sha256(1),
             "last_rowid_sha256" => rowid_sha256(2)
           }

    source = manifest["source"]
    assert Enum.sort(Map.keys(source)) == ~w(fingerprint main shm wal)
    assert source["fingerprint"] == fixture.fingerprint
    assert source["main"] == file_manifest_entry(fixture.db)
    assert source["wal"] == nil
    assert source["shm"] == nil

    assert manifest["backup"] == file_manifest_entry(artifact.database)
    assert manifest["backup"]["name"] == @operation_id <> ".sqlite3"
    assert artifact.source_sha256 == source["main"]["sha256"]
    assert artifact.backup_sha256 == manifest["backup"]["sha256"]

    restore = manifest["independent_restore"]
    assert Enum.sort(Map.keys(restore)) == Enum.sort(@independent_restore_keys)
    assert restore["verified"] == true
    assert restore["backup_sha256"] == manifest["backup"]["sha256"]

    for key <- ~w(
          application_id foreign_key_violations migrations quick_check row_counts rowid_proofs
          schema_sha256 sqlite_source_id sqlite_version
        ) do
      assert restore[key] == manifest[key]
    end

    refute bounded_read!(artifact.manifest, 4_194_304) =~ fixture.secret
    assert {:ok, backup_probe} = Probe.inspect(artifact.database)
    assert backup_probe.schema_sha256 == fixture.decision.probe.schema_sha256

    assert File.ls!(fixture.backup_dir) |> Enum.sort() ==
             [Path.basename(artifact.database), Path.basename(artifact.manifest)] |> Enum.sort()
  end

  test "a genuine current ready decision backs up all 57 migrations and newly persisted values" do
    fixture = migration_fixture!(lineage: :current)
    assert fixture.decision.status == :ready
    assert fixture.decision.pending == []

    SchemaFixture.exec!(fixture.db, """
    PRAGMA foreign_keys=ON;
    INSERT INTO providers(id, name, base_url, fallbacks, inserted_at, updated_at)
    VALUES ('provider-off', 'Provider off', 'https://example.invalid', 0, '2026-09-06', '2026-09-06'),
           ('provider-on', 'Provider on', 'https://example.invalid', 1, '2026-09-06', '2026-09-06');
    INSERT INTO conversations(id, project_id, inserted_at, updated_at)
    VALUES ('conversation-1', 'project-1', '2026-09-06', '2026-09-06');
    INSERT INTO runs(id, conversation_id, kind, started_at, inserted_at, updated_at)
    VALUES ('run-1', 'conversation-1', 'swarm', '2026-09-06', '2026-09-06', '2026-09-06');
    INSERT INTO nodes(id, run_id, kind, cache_read, cache_write, inserted_at, updated_at)
    VALUES ('node-1', 'run-1', 'agent', 12345, 678, '2026-09-06', '2026-09-06');
    INSERT INTO settings(id, bench_layout, inserted_at, updated_at)
    VALUES ('settings-1', 'scorecard', '2026-09-06', '2026-09-06');
    """)

    before = source_state(fixture.db)

    expected_values = %{
      providers: [["provider-off", 0], ["provider-on", 1]],
      nodes: [[12345, 678]],
      settings: [["scorecard"]]
    }

    assert current_values(fixture.db) == expected_values
    assert {:ok, artifact} = create(fixture)
    assert source_state(fixture.db) == before
    assert {:ok, manifest} = Manifest.decode(bounded_read!(artifact.manifest, 4_194_304))
    assert length(manifest["migrations"]) == 57
    assert manifest["migrations"] == fixture.decision.applied
    assert manifest["independent_restore"]["migrations"] == fixture.decision.applied
    assert manifest["independent_restore"]["verified"] == true

    for verification <- [manifest, manifest["independent_restore"]] do
      assert verification["quick_check"] == "ok"
      assert verification["foreign_key_violations"] == []
      assert verification["row_counts"] == SchemaFixture.row_counts(fixture.db)
    end

    restored = Path.join(Path.dirname(fixture.db), "independent-current-restore.db")
    copy_private!(artifact.database, restored)
    assert {:ok, probe} = Probe.inspect(restored)
    assert length(probe.migration_versions) == 57
    assert probe.quick_check == [["ok"]]
    assert probe.foreign_key_violations == []
    assert probe.schema_sha256 == fixture.decision.probe.schema_sha256
    assert current_values(restored) == expected_values
    assert current_values(artifact.database) == expected_values
    assert source_state(fixture.db) == before

    overflow = manifest["migrations"] ++ [20_990_101_000_000]

    invalid =
      manifest
      |> Map.put("migrations", overflow)
      |> put_in(["independent_restore", "migrations"], overflow)

    assert {:error, _} = Manifest.decode(Jason.encode!(invalid))
  end

  defp current_values(database) do
    {:ok, conn} = Exqlite.Sqlite3.open(database, mode: :readonly)

    try do
      Map.new(
        [
          providers: "SELECT id, fallbacks FROM providers ORDER BY id",
          nodes: "SELECT cache_read, cache_write FROM nodes ORDER BY id",
          settings: "SELECT bench_layout FROM settings ORDER BY id"
        ],
        fn {key, query} ->
          {key, SwarmCode.Daemon.Schema.SqliteQuery.rows(conn, query, [], max_rows: 2)}
        end
      )
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  test "VACUUM INTO includes committed WAL rows without changing main, WAL, or SHM" do
    fixture = migration_fixture!(wal: true)
    before = source_state(fixture.db)
    assert before["wal"] != nil
    assert before["shm"] != nil

    assert {:ok, artifact} = create(fixture)
    assert source_state(fixture.db) == before

    manifest = decode_manifest!(artifact.manifest)
    assert manifest["source"]["main"] == file_manifest_entry(fixture.db)
    assert manifest["source"]["wal"]["sha256"] == before["wal"].sha256
    assert manifest["source"]["shm"]["sha256"] == before["shm"].sha256
    assert manifest["row_counts"]["projects"] == 2
    assert SchemaFixture.row_counts(artifact.database)["projects"] == 2
  end

  test "fresh unprobed WAL is backed up through copied main and WAL with exact source bytes" do
    fixture = migration_fixture!(lineage: :current)
    _writer = SchemaFixture.open_uncheckpointed_wal!(fixture.db)
    before = source_state(fixture.db)
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        pinned = source_pin_path!(fixture.backup_dir)

        [workspace] =
          File.ls!(Path.dirname(fixture.db))
          |> Enum.filter(&String.starts_with?(&1, ".swarm-snapshot-"))

        supplied = Path.join([Path.dirname(fixture.db), workspace, "snapshot.db"])

        send(
          test,
          {:private_source_copy, same_object?(fixture.db, pinned),
           same_object?(fixture.db <> "-wal", pinned <> "-wal"), same_object?(supplied, pinned),
           same_object?(supplied <> "-wal", pinned <> "-wal")}
        )

        :ok

      _point, _context ->
        :ok
    end

    result = create(fixture, test_hook: hook)
    assert source_state(fixture.db) == before
    assert_receive {:private_source_copy, false, false, false, false}
    assert {:ok, artifact} = result
    assert {:ok, manifest} = Manifest.decode(bounded_read!(artifact.manifest, 4_194_304))
    assert manifest["source"]["main"]["sha256"] == before["main"].sha256
    assert manifest["source"]["wal"]["sha256"] == before["wal"].sha256
    assert manifest["source"]["shm"]["sha256"] == before["shm"].sha256
    assert manifest["row_counts"]["projects"] == 4
    assert manifest["independent_restore"]["row_counts"]["projects"] == 4
    restored = Path.join(Path.dirname(fixture.db), "fresh-wal-restore.db")
    copy_private!(artifact.database, restored)
    {:ok, conn} = Exqlite.Sqlite3.open(restored, mode: :readonly)

    try do
      assert SwarmCode.Daemon.Schema.SqliteQuery.rows(
               conn,
               "SELECT id, name FROM projects ORDER BY id",
               [],
               max_rows: 4
             ) == [
               ["project-1", fixture.secret],
               ["project-2", "Second project"],
               ["wal-project-1", "WAL project 1"],
               ["wal-project-2", "WAL project 2"]
             ]
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end

    assert source_state(fixture.db) == before

    refute Enum.any?(
             File.ls!(Path.dirname(fixture.db)),
             &String.starts_with?(&1, ".swarm-snapshot-")
           )
  end

  test "every user table is counted even when its name begins with sqlite" do
    fixture = migration_fixture!()

    SchemaFixture.exec!(
      fixture.db,
      """
      CREATE TABLE "sqliteX_user_table" ("value" TEXT);
      INSERT INTO "sqliteX_user_table"("value") VALUES ('never manifest this value');
      """
    )

    assert {:ok, probe} = Probe.inspect(fixture.db)
    fixture = %{fixture | decision: %{fixture.decision | probe: probe}}

    assert {:ok, artifact} = create(fixture)
    manifest = decode_manifest!(artifact.manifest)
    assert manifest["row_counts"]["sqliteX_user_table"] == 1
    assert manifest["rowid_proofs"]["sqliteX_user_table"]["count"] == 1
    refute bounded_read!(artifact.manifest, 4_194_304) =~ "never manifest this value"
  end

  test "representative proofs use a real rowid alias rather than a shadowing user column" do
    fixture = migration_fixture!()

    SchemaFixture.exec!(
      fixture.db,
      """
      CREATE TABLE "rowid_shadow" ("ROWID" TEXT);
      INSERT INTO "rowid_shadow"("ROWID") VALUES ('secret-shadow-value');
      """
    )

    assert {:ok, probe} = Probe.inspect(fixture.db)
    fixture = %{fixture | decision: %{fixture.decision | probe: probe}}

    assert {:ok, artifact} = create(fixture)
    manifest = decode_manifest!(artifact.manifest)

    assert manifest["rowid_proofs"]["rowid_shadow"] == %{
             "count" => 1,
             "first_rowid_sha256" => rowid_sha256(1),
             "last_rowid_sha256" => rowid_sha256(1)
           }

    refute bounded_read!(artifact.manifest, 4_194_304) =~ "secret-shadow-value"
  end

  for point <- [:after_snapshot, :after_manifest, :after_restore_copy, :before_publish] do
    test "failure at #{point} leaves every source file unchanged and no output, including dot files" do
      fixture = migration_fixture!()
      before = source_state(fixture.db)

      assert {:error, %{code: :backup_failed}} =
               create(fixture, fault: unquote(point))

      assert source_state(fixture.db) == before
      assert File.ls!(fixture.backup_dir) == []
    end
  end

  test "create_new returns the verified artifact when finish_ownership fails" do
    fixture = migration_fixture!()
    before = source_state(fixture.db)

    log =
      capture_log(fn ->
        assert {:ok, artifact} = create(fixture, fault: :finish_ownership)
        send(self(), {:artifact, artifact})
      end)

    assert_received {:artifact, artifact}
    assert artifact.__struct__ == Artifact
    assert log =~ "verified artifact kept despite cleanup failure"
    assert log =~ ":finish_ownership"
    # The source database is untouched and the committed pair stands.
    assert source_state(fixture.db) == before
    assert File.exists?(artifact.database)
    assert File.exists?(artifact.manifest)
  end

  test "revalidate_existing returns the verified artifact when finish_ownership fails" do
    fixture = migration_fixture!()
    assert {:ok, first} = create(fixture)
    before = source_state(fixture.db)

    log =
      capture_log(fn ->
        assert {:ok, second} = create(fixture, fault: :finish_ownership)
        send(self(), {:artifact, second})
      end)

    assert_received {:artifact, artifact}
    assert artifact == first
    assert log =~ "verified artifact kept despite cleanup failure"
    assert log =~ ":finish_ownership"
    assert source_state(fixture.db) == before
  end

  test "operation failure combined with finish_ownership failure is still cleanup_pending" do
    fixture = migration_fixture!()
    before = source_state(fixture.db)

    # Fail the operation LATE (after the artifact is fully staged but before
    # publish) while the ownership cleanup also fails: no false success.
    hook = fn
      :before_staging_database_sync, _context -> {:error, :injected_late_operation_failure}
      _point, _context -> :ok
    end

    log =
      capture_log(fn ->
        result = create(fixture, fault: :finish_ownership, test_hook: hook)
        send(self(), {:result, result})
      end)

    assert_received {:result, {:error, %{code: :cleanup_pending}}}
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
    assert log == "" or is_binary(log)
  end

  test "an identical duplicate operation is fully revalidated and returns the original artifact" do
    fixture = migration_fixture!()
    assert {:ok, first} = create(fixture)
    before = source_state(fixture.db)
    entries = File.ls!(fixture.backup_dir) |> Enum.sort()

    assert {:ok, second} =
             create(fixture, now: fn -> ~U[2030-01-01 00:00:00Z] end)

    assert second == first
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) |> Enum.sort() == entries
  end

  @tag timeout: 60_000
  test "concurrent duplicate callers converge on one fully verified committed artifact" do
    fixture = migration_fixture!()
    task_supervisor = start_supervised!(Task.Supervisor)
    test_process = self()

    tasks =
      for _number <- 1..4 do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(test_process, {:backup_caller_ready, self()})

          receive do
            :create_backup -> create(fixture)
          end
        end)
      end

    callers =
      for _number <- 1..4 do
        assert_receive {:backup_caller_ready, caller}
        caller
      end

    Enum.each(callers, &send(&1, :create_backup))

    # :global lock contention uses randomized backoff of up to eight seconds per retry.
    # Bound the whole test with ExUnit; a per-caller deadline races valid serialized work.
    artifacts =
      Enum.map(tasks, fn task ->
        assert {:ok, artifact} = Task.await(task, :infinity)
        artifact
      end)

    assert Enum.uniq(artifacts) |> length() == 1

    assert File.ls!(fixture.backup_dir) |> Enum.sort() ==
             [@operation_id <> ".manifest.json", @operation_id <> ".sqlite3"]
  end

  test "a duplicate with a corrupted backup fails closed and retains the committed pair" do
    fixture = migration_fixture!()
    assert {:ok, artifact} = create(fixture)
    File.write!(artifact.database, "not a SQLite backup")
    File.chmod!(artifact.database, 0o600)
    corrupted = bounded_read!(artifact.database, 1_024)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert bounded_read!(artifact.database, 1_024) == corrupted
    assert File.exists?(artifact.manifest)

    assert File.ls!(fixture.backup_dir) |> Enum.sort() ==
             [Path.basename(artifact.database), Path.basename(artifact.manifest)] |> Enum.sort()
  end

  test "a duplicate with changed source digests fails closed and retains the committed pair" do
    fixture = migration_fixture!()
    assert {:ok, artifact} = create(fixture)

    SchemaFixture.insert_project!(
      fixture.db,
      "later-project",
      "Later project",
      "/private/later-project"
    )

    changed_source = source_state(fixture.db)
    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert source_state(fixture.db) == changed_source
    assert File.exists?(artifact.database)
    assert File.exists?(artifact.manifest)
  end

  test "a manifest count mismatch is rejected even when its duplicated proof agrees" do
    fixture = migration_fixture!()
    assert {:ok, artifact} = create(fixture)
    manifest = decode_manifest!(artifact.manifest)
    wrong_counts = Map.put(manifest["row_counts"], "projects", 999)

    tampered =
      manifest
      |> Map.put("row_counts", wrong_counts)
      |> put_in(["independent_restore", "row_counts"], wrong_counts)

    write_private!(artifact.manifest, [Jason.encode_to_iodata!(tampered), "\n"])
    tampered_bytes = bounded_read!(artifact.manifest, 4_194_304)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert bounded_read!(artifact.manifest, 4_194_304) == tampered_bytes
    assert File.exists?(artifact.database)
  end

  test "a dead or non-owning lease refuses before source inspection or directory creation" do
    database = prepared_database!()
    decision = schema_decision!(database)
    uid = File.lstat!(Path.dirname(database)).uid
    backup_dir = Path.join(Path.dirname(database), "not-created")
    dead = start_supervised!({Agent, fn -> %{} end})
    monitor = Process.monitor(dead)
    assert :ok = stop_supervised(Agent)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :shutdown}
    before = source_state(database)

    assert {:error, %{code: :backup_failed}} =
             Gate.create(database, backup_dir, @operation_id, dead, decision,
               uid: uid,
               now: fn -> @verified_at end
             )

    assert source_state(database) == before
    refute File.exists?(backup_dir)
  end

  test "an inconsistent ready decision with pending migrations refuses without mutation" do
    fixture = migration_fixture!()
    before = source_state(fixture.db)

    assert {:error, %{code: :backup_failed}} =
             Gate.create(
               fixture.db,
               fixture.backup_dir,
               @operation_id,
               fixture.lease,
               %{fixture.decision | status: :ready},
               uid: fixture.uid,
               now: fn -> @verified_at end
             )

    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
  end

  test "a ready decision with an applied list different from its probe refuses unchanged" do
    fixture = migration_fixture!(lineage: :current)
    before = source_state(fixture.db)

    inconsistent = %{
      fixture
      | decision: %{fixture.decision | applied: tl(fixture.decision.applied)}
    }

    assert {:error, %{code: :backup_failed}} = create(inconsistent)
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
  end

  test "the source path must match the versioned filesystem identity held by the lease" do
    fixture =
      migration_fixture!(lease_fingerprint: "sqlite-file-v1:" <> String.duplicate("0", 64))

    before = source_state(fixture.db)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
  end

  test "the versioned fingerprint canonicalizes a symlinked parent directory" do
    database = prepared_database!()
    parent = Path.dirname(database)
    alias_path = Path.join(Path.dirname(parent), "database-parent-alias-#{random_suffix()}")
    File.ln_s!(parent, alias_path)
    on_exit(fn -> File.rm(alias_path) end)
    aliased_database = Path.join(alias_path, Path.basename(database))

    assert {:ok, fingerprint} = DatabaseFingerprint.for_path(database)
    assert {:ok, ^fingerprint} = DatabaseFingerprint.for_path(aliased_database)
  end

  test "one physical source resolution binds lease metadata probe and VACUUM across symlink dot-dot" do
    root = private_directory!("source-resolution")
    other = Path.join(root, "other")
    child = Path.join(other, "child")
    File.mkdir!(other)
    File.chmod!(other, 0o700)
    File.mkdir!(child)
    File.chmod!(child, 0o700)

    claimed = Path.join(root, "db.sqlite")
    actual = Path.join(other, "db.sqlite")
    copy_private!(prepared_database!(), claimed)
    actual_fixture = prepared_database!()
    SchemaFixture.insert_project!(actual_fixture, "actual-2", "Actual two", "/actual/two")
    copy_private!(actual_fixture, actual)

    link = Path.join(root, "link")
    File.ln_s!(child, link)
    source = link <> "/../db.sqlite"
    assert Path.expand(source) == claimed
    refute sha256_file(claimed) == sha256_file(actual)

    decision = schema_decision!(source)
    uid = File.lstat!(root).uid
    backup_dir = private_child!(root, "backups")
    fingerprint = database_fingerprint(source)
    lease = start_lease!(root, uid, fingerprint)

    fixture = %{
      db: source,
      lease: lease,
      decision: decision,
      backup_dir: backup_dir,
      uid: uid,
      fingerprint: fingerprint,
      secret: "not-present"
    }

    assert {:ok, artifact} = create(fixture)
    manifest = decode_manifest!(artifact.manifest)
    assert manifest["source"]["main"] == file_manifest_entry(actual)
    assert artifact.source_sha256 == sha256_file(actual)
    assert manifest["row_counts"]["projects"] == 2
    assert SchemaFixture.row_counts(artifact.database)["projects"] == 2
  end

  test "snapshot stays pinned when the verified source pathname is swapped then restored" do
    fixture = migration_fixture!()
    original_state = source_state(fixture.db)
    directory = Path.dirname(fixture.db)
    parked_original = Path.join(directory, "parked-original.sqlite3")
    incoming = Path.join(directory, "incoming.sqlite3")
    parked_incoming = Path.join(directory, "parked-incoming.sqlite3")

    replacement = prepared_database!()
    SchemaFixture.insert_project!(replacement, "incoming-2", "Incoming two", "/incoming/two")
    SchemaFixture.insert_project!(replacement, "incoming-3", "Incoming three", "/incoming/three")
    copy_private!(replacement, incoming)
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        File.rename!(fixture.db, parked_original)
        File.rename!(incoming, fixture.db)
        send(test, :source_path_swapped)
        :ok

      :before_restore_create, _context ->
        File.rename!(fixture.db, parked_incoming)
        File.rename!(parked_original, fixture.db)
        send(test, :source_path_restored)
        :ok

      _point, _context ->
        :ok
    end

    assert {:ok, artifact} = create(fixture, test_hook: hook)
    assert_receive :source_path_swapped
    assert_receive :source_path_restored
    assert source_state(fixture.db) == original_state
    assert SchemaFixture.row_counts(fixture.db)["projects"] == 2
    assert SchemaFixture.row_counts(artifact.database)["projects"] == 2

    refute Enum.any?(File.ls!(directory), &String.contains?(&1, ".source-pin."))
  end

  test "source pin aliases live only in the held backup directory" do
    fixture = migration_fixture!(wal: true)
    source_directory = Path.dirname(fixture.db)
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        source_pins =
          source_directory
          |> File.ls!()
          |> Enum.filter(&String.contains?(&1, ".source-pin"))

        backup_pins =
          fixture.backup_dir
          |> File.ls!()
          |> Enum.filter(&String.contains?(&1, ".source-pin"))

        send(test, {:source_pin_locations, source_pins, backup_pins})
        :ok

      _point, _context ->
        :ok
    end

    assert {:ok, _artifact} = create(fixture, test_hook: hook)
    assert_receive {:source_pin_locations, [], backup_pins}
    assert Enum.any?(backup_pins, &String.ends_with?(&1, ".source-pin.sqlite3"))
    assert Enum.any?(backup_pins, &String.ends_with?(&1, ".source-pin.sqlite3-wal"))
    assert Enum.any?(backup_pins, &String.ends_with?(&1, ".source-pin.sqlite3-shm"))
    refute Enum.any?(File.ls!(fixture.backup_dir), &String.contains?(&1, ".source-pin"))
  end

  test "snapshot keeps the verified pin inode open when its alias is swapped then restored" do
    fixture = migration_fixture!()
    source_directory = Path.dirname(fixture.db)
    incoming = Path.join(source_directory, "incoming-pin.sqlite3")
    parked_pin = Path.join(source_directory, "parked-source-pin.sqlite3")

    replacement = prepared_database!()
    SchemaFixture.insert_project!(replacement, "incoming-2", "Incoming two", "/incoming/two")
    SchemaFixture.insert_project!(replacement, "incoming-3", "Incoming three", "/incoming/three")
    copy_private!(replacement, incoming)
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        pinned = source_pin_path!(fixture.backup_dir)
        File.rename!(pinned, parked_pin)
        File.rename!(incoming, pinned)
        send(test, {:source_pin_swapped, pinned})
        :ok

      :before_restore_create, _context ->
        receive do
          {:restore_source_pin, pinned} ->
            File.rename!(pinned, incoming)
            File.rename!(parked_pin, pinned)
        end

        send(test, :source_pin_restored)
        :ok

      _point, _context ->
        :ok
    end

    task_supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn -> create(fixture, test_hook: hook) end)

    assert_receive {:source_pin_swapped, pinned}, 30_000
    send(task.pid, {:restore_source_pin, pinned})

    assert {:ok, artifact} = Task.await(task, 30_000)
    assert_receive :source_pin_restored, 30_000
    assert SchemaFixture.row_counts(fixture.db)["projects"] == 2
    assert SchemaFixture.row_counts(artifact.database)["projects"] == 2
    refute Enum.any?(File.ls!(fixture.backup_dir), &String.contains?(&1, ".source-pin."))
  end

  test "the held pin connection keeps the verified WAL set when every alias is replaced" do
    fixture = migration_fixture!(wal: true)
    source_directory = Path.dirname(fixture.db)
    before = source_state(fixture.db)
    replacement = prepared_database!()
    _replacement_writer = SchemaFixture.open_uncheckpointed_wal!(replacement)
    assert SchemaFixture.row_counts(replacement)["projects"] == 3
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        pinned = source_pin_path!(fixture.backup_dir)
        send(test, {:wal_pin_ready, pinned})

        receive do
          {:continue_wal_snapshot, ^pinned} -> :ok
        end

      :before_restore_create, _context ->
        send(test, :restore_wal_pin_set)

        receive do
          :continue_wal_restore -> :ok
        end

      _point, _context ->
        :ok
    end

    task_supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn -> create(fixture, test_hook: hook) end)

    assert_receive {:wal_pin_ready, pinned}, 30_000

    parked =
      for suffix <- ["", "-wal", "-shm"] do
        alias_path = pinned <> suffix
        parked_path = Path.join(source_directory, "parked-pin#{suffix}")
        File.rename!(alias_path, parked_path)
        File.ln!(replacement <> suffix, alias_path)
        {alias_path, parked_path}
      end

    send(task.pid, {:continue_wal_snapshot, pinned})
    assert_receive :restore_wal_pin_set, 30_000

    Enum.each(parked, fn {alias_path, parked_path} ->
      File.rm!(alias_path)
      File.rename!(parked_path, alias_path)
    end)

    send(task.pid, :continue_wal_restore)

    assert {:ok, artifact} = Task.await(task, 30_000)
    assert source_state(fixture.db) == before
    assert SchemaFixture.row_counts(artifact.database)["projects"] == 2
    refute Enum.any?(File.ls!(fixture.backup_dir), &String.contains?(&1, ".source-pin."))
  end

  test "the versioned fingerprint canonicalizes case and Unicode normalization aliases" do
    database = prepared_database!()
    canonical = Path.join(Path.dirname(database), "Caf\u00E9.DB")
    File.rename!(database, canonical)
    alias_path = Path.join(Path.dirname(database), "cafe\u0301.db")

    canonical_stat = File.lstat!(canonical)

    case File.lstat(alias_path) do
      {:ok, alias_stat} ->
        assert {alias_stat.major_device, alias_stat.minor_device, alias_stat.inode} ==
                 {canonical_stat.major_device, canonical_stat.minor_device, canonical_stat.inode}

        assert {:ok, fingerprint} = DatabaseFingerprint.for_path(canonical)
        assert {:ok, ^fingerprint} = DatabaseFingerprint.for_path(alias_path)

      {:error, :enoent} ->
        :ok
    end
  end

  test "database no-clobber publication preserves an object substituted after absence check" do
    fixture = migration_fixture!()
    final_database = Path.join(fixture.backup_dir, @operation_id <> ".sqlite3")
    test = self()

    hook = fn
      :after_database_absence_check, _context ->
        write_private!(final_database, "database-race-sentinel")
        send(test, :database_race_substituted)
        :ok

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :database_race_substituted
    assert bounded_read!(final_database, 1_024) == "database-race-sentinel"
    assert File.ls!(fixture.backup_dir) == [Path.basename(final_database)]
  end

  test "manifest no-clobber commit preserves a substituted marker and the published database" do
    fixture = migration_fixture!()
    final_database = Path.join(fixture.backup_dir, @operation_id <> ".sqlite3")
    final_manifest = Path.join(fixture.backup_dir, @operation_id <> ".manifest.json")
    test = self()

    hook = fn
      :after_manifest_absence_check, _context ->
        write_private!(final_manifest, "manifest-race-sentinel")
        send(test, :manifest_race_substituted)
        :ok

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :manifest_race_substituted
    assert bounded_read!(final_manifest, 1_024) == "manifest-race-sentinel"
    assert {:ok, _probe} = Probe.inspect(final_database)

    assert File.ls!(fixture.backup_dir) |> Enum.sort() ==
             [Path.basename(final_database), Path.basename(final_manifest)] |> Enum.sort()
  end

  test "failure immediately after the database hard link removes both registered aliases" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :after_database_link, _context ->
        send(test, :database_link_created)
        {:error, :injected_after_database_link_failure}

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :database_link_created
    assert File.ls!(fixture.backup_dir) == []
  end

  test "requester death after the manifest commit link retains only a recoverable committed pair" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :after_manifest_link, _context ->
        send(test, :manifest_commit_link_created)

        receive do
          :continue_manifest_commit -> :ok
        end

      _point, _context ->
        :ok
    end

    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> create(fixture, test_hook: hook) end)

    # pass70 Q23: a backup under a loaded full suite took longer than 5 s to
    # reach its hook once; the hook waits are 30 s, which costs a passing run
    # nothing.
    assert_receive :manifest_commit_link_created, 30_000
    assert Task.shutdown(task, :brutal_kill) == nil

    final_names = ["#{@operation_id}.manifest.json", "#{@operation_id}.sqlite3"]
    await_directory_names!(fixture.backup_dir, final_names, 10_000)
    assert File.ls!(fixture.backup_dir) |> Enum.sort() == Enum.sort(final_names)
    assert {:ok, artifact} = create(fixture)
    assert Path.basename(artifact.database) == "#{@operation_id}.sqlite3"
  end

  test "a retained post-commit directory-sync failure is durably recovered by duplicate admission" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :before_final_directory_sync, _context ->
        send(test, :final_directory_sync_reached)
        {:error, :injected_directory_sync_failure}

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :final_directory_sync_reached

    assert File.ls!(fixture.backup_dir) |> Enum.sort() ==
             [@operation_id <> ".manifest.json", @operation_id <> ".sqlite3"]

    assert {:ok, artifact} = create(fixture)
    assert File.exists?(artifact.database)
    assert File.exists?(artifact.manifest)
  end

  for point <- [
        :before_duplicate_database_sync,
        :before_duplicate_manifest_sync,
        :before_duplicate_directory_sync
      ] do
    test "duplicate durability failure at #{point} refuses while retaining the committed pair" do
      fixture = migration_fixture!()
      assert {:ok, artifact} = create(fixture)
      before_database = file_state(artifact.database)
      before_manifest = file_state(artifact.manifest)
      test = self()

      hook = fn
        unquote(point), _context ->
          send(test, {:duplicate_sync_reached, unquote(point)})
          {:error, :injected_duplicate_sync_failure}

        _other, _context ->
          :ok
      end

      assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
      assert_receive {:duplicate_sync_reached, unquote(point)}
      assert file_state(artifact.database) == before_database
      assert file_state(artifact.manifest) == before_manifest

      assert File.ls!(fixture.backup_dir) |> Enum.sort() ==
               [Path.basename(artifact.database), Path.basename(artifact.manifest)] |> Enum.sort()
    end
  end

  test "a retargeted backup parent alias cannot redirect anchored writes" do
    fixture = migration_fixture!()
    root = private_directory!("backup-parent-retarget")
    parent_a = private_child!(root, "parent-a")
    parent_b = private_child!(root, "parent-b")
    backups_a = private_child!(parent_a, "backups")
    backups_b = private_child!(parent_b, "backups")
    parent_alias = Path.join(root, "parent-alias")
    File.ln_s!(parent_a, parent_alias)
    fixture = %{fixture | backup_dir: Path.join(parent_alias, "backups")}
    test = self()

    hook = fn
      :after_backup_directory_open, _context ->
        File.rm!(parent_alias)
        File.ln_s!(parent_b, parent_alias)
        send(test, :backup_parent_retargeted)
        :ok

      _point, _context ->
        :ok
    end

    assert {:ok, artifact} = create(fixture, test_hook: hook)
    assert_receive :backup_parent_retargeted
    assert same_object?(Path.dirname(artifact.database), backups_a)
    assert File.ls!(backups_b) == []

    assert File.ls!(backups_a) |> Enum.sort() ==
             [@operation_id <> ".manifest.json", @operation_id <> ".sqlite3"]
  end

  test "a renamed and replaced anchored backup directory refuses before snapshot creation" do
    fixture = migration_fixture!()
    moved = fixture.backup_dir <> "-moved"
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        File.rename!(fixture.backup_dir, moved)
        File.mkdir!(fixture.backup_dir)
        File.chmod!(fixture.backup_dir, 0o700)
        send(test, :backup_directory_replaced)
        :ok

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :backup_directory_replaced
    assert File.ls!(fixture.backup_dir) == []
    assert File.ls!(moved) == []
  end

  @tag timeout: 60_000
  test "cleanup remains relative to the held directory after it is renamed mid-VACUUM" do
    fixture = migration_fixture!()

    SchemaFixture.exec!(
      fixture.db,
      """
      CREATE TABLE bulk_payload(id INTEGER PRIMARY KEY, payload BLOB);
      WITH RECURSIVE numbers(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM numbers WHERE value < 16000
      )
      INSERT INTO bulk_payload(id, payload)
      SELECT value, randomblob(4096) FROM numbers;
      """
    )

    assert {:ok, probe} = Probe.inspect(fixture.db)
    fixture = %{fixture | decision: %{fixture.decision | probe: probe}}
    moved = fixture.backup_dir <> "-moved"
    watcher_supervisor = start_supervised!(Task.Supervisor)
    test = self()

    watcher =
      Task.Supervisor.async_nolink(watcher_supervisor, fn ->
        wait_for_vacuum_journal!(fixture.backup_dir, 10_000)
        File.rename!(fixture.backup_dir, moved)
        File.mkdir!(fixture.backup_dir)
        File.chmod!(fixture.backup_dir, 0o700)
        send(test, :backup_directory_renamed_mid_vacuum)
        :ok
      end)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert :ok = Task.await(watcher, 15_000)
    assert_receive :backup_directory_renamed_mid_vacuum
    assert File.ls!(fixture.backup_dir) == []
    assert File.ls!(moved) == []
  end

  @tag timeout: 60_000
  test "requester death cancels VACUUM and removes the main file and generated journal" do
    fixture = migration_fixture!()

    SchemaFixture.exec!(
      fixture.db,
      """
      CREATE TABLE requester_death_payload(id INTEGER PRIMARY KEY, payload BLOB);
      WITH RECURSIVE numbers(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM numbers WHERE value < 16000
      )
      INSERT INTO requester_death_payload(id, payload)
      SELECT value, randomblob(4096) FROM numbers;
      """
    )

    assert {:ok, probe} = Probe.inspect(fixture.db)
    fixture = %{fixture | decision: %{fixture.decision | probe: probe}}
    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> create(fixture) end)

    wait_for_vacuum_journal!(fixture.backup_dir, 10_000)
    assert Task.shutdown(task, :brutal_kill) == nil
    await_directory_empty!(fixture.backup_dir, 10_000)
    assert File.ls!(fixture.backup_dir) == []
    await_no_snapshots!(Path.dirname(fixture.db), 10_000)
  end

  @tag timeout: 60_000
  test "a non-writable mode introduced mid-VACUUM is repaired before relative cleanup" do
    fixture = migration_fixture!()

    SchemaFixture.exec!(
      fixture.db,
      """
      CREATE TABLE mode_payload(id INTEGER PRIMARY KEY, payload BLOB);
      WITH RECURSIVE numbers(value) AS (
        SELECT 1
        UNION ALL
        SELECT value + 1 FROM numbers WHERE value < 16000
      )
      INSERT INTO mode_payload(id, payload)
      SELECT value, randomblob(4096) FROM numbers;
      """
    )

    assert {:ok, probe} = Probe.inspect(fixture.db)
    fixture = %{fixture | decision: %{fixture.decision | probe: probe}}
    supervisor = start_supervised!(Task.Supervisor)
    test = self()

    watcher =
      Task.Supervisor.async_nolink(supervisor, fn ->
        wait_for_vacuum_journal!(fixture.backup_dir, 10_000)
        File.chmod!(fixture.backup_dir, 0o500)
        send(test, :backup_directory_mode_changed_mid_vacuum)
      end)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert Task.await(watcher, 15_000) == :backup_directory_mode_changed_mid_vacuum
    assert_receive :backup_directory_mode_changed_mid_vacuum
    assert permissions(fixture.backup_dir) == 0o700
    assert File.ls!(fixture.backup_dir) == []
  end

  test "cleanup remains relative after the held directory is renamed mid-restore copy" do
    fixture = migration_fixture!()
    moved = fixture.backup_dir <> "-moved"
    test = self()

    hook = fn
      :after_restore_files_open, _context ->
        File.rename!(fixture.backup_dir, moved)
        File.mkdir!(fixture.backup_dir)
        File.chmod!(fixture.backup_dir, 0o700)
        send(test, :backup_directory_renamed_mid_restore)
        :ok

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :backup_directory_renamed_mid_restore
    assert File.ls!(fixture.backup_dir) == []
    assert File.ls!(moved) == []
  end

  test "requester death with restore descriptors open removes the exact partial copy" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :after_restore_files_open, _context ->
        send(test, :restore_files_open)

        receive do
          :continue_restore_copy -> :ok
        end

      _point, _context ->
        :ok
    end

    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> create(fixture, test_hook: hook) end)

    assert_receive :restore_files_open, 30_000
    assert Task.shutdown(task, :brutal_kill) == nil
    await_directory_empty!(fixture.backup_dir, 10_000)
    assert File.ls!(fixture.backup_dir) == []
  end

  test "cleanup remains relative after the held directory is renamed mid-manifest write" do
    fixture = migration_fixture!()
    moved = fixture.backup_dir <> "-moved"
    test = self()

    hook = fn
      :after_manifest_temp_sync, _context ->
        File.rename!(fixture.backup_dir, moved)
        File.mkdir!(fixture.backup_dir)
        File.chmod!(fixture.backup_dir, 0o700)
        send(test, :backup_directory_renamed_mid_manifest)
        :ok

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :backup_directory_renamed_mid_manifest
    assert File.ls!(fixture.backup_dir) == []
    assert File.ls!(moved) == []
  end

  test "requester death after manifest temp sync removes every registered alias" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :after_manifest_temp_sync, _context ->
        send(test, :manifest_temp_synced)

        receive do
          :continue_manifest_write -> :ok
        end

      _point, _context ->
        :ok
    end

    supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> create(fixture, test_hook: hook) end)

    assert_receive :manifest_temp_synced, 30_000
    assert Task.shutdown(task, :brutal_kill) == nil
    await_directory_empty!(fixture.backup_dir, 10_000)
    assert File.ls!(fixture.backup_dir) == []
  end

  test "identity-clean cleanup repairs a non-writable held-directory mode" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :before_database_publication, _context ->
        File.chmod!(fixture.backup_dir, 0o500)
        send(test, :backup_directory_mode_substituted)
        :ok

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :backup_directory_mode_substituted
    assert permissions(fixture.backup_dir) == 0o700
    assert File.ls!(fixture.backup_dir) == []
  end

  test "source-directory mode changes cannot retarget backup-directory source pins" do
    fixture = migration_fixture!()
    source_directory = Path.dirname(fixture.db)
    test = self()

    hook = fn
      :before_snapshot_create, _context ->
        File.chmod!(source_directory, 0o755)
        send(test, :source_directory_mode_substituted)
        :ok

      _point, _context ->
        :ok
    end

    assert {:ok, _artifact} = create(fixture, test_hook: hook)
    assert_receive :source_directory_mode_substituted
    assert permissions(source_directory) == 0o755
    refute Enum.any?(File.ls!(source_directory), &String.contains?(&1, ".source-pin."))
    refute Enum.any?(File.ls!(fixture.backup_dir), &String.contains?(&1, ".source-pin."))
  end

  test "a source pin linked before validation failure is identity-cleaned" do
    fixture = migration_fixture!()
    source_directory = Path.dirname(fixture.db)
    before = source_state(fixture.db)
    test = self()

    hook = fn
      :after_source_main_pin_link, _context ->
        send(test, :source_main_pin_linked)
        {:error, :injected_pin_validation_failure}

      _point, _context ->
        :ok
    end

    assert {:error, %{code: :backup_failed}} = create(fixture, test_hook: hook)
    assert_receive :source_main_pin_linked
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
    refute Enum.any?(File.ls!(source_directory), &String.contains?(&1, ".source-pin."))
    refute Enum.any?(File.ls!(fixture.backup_dir), &String.contains?(&1, ".source-pin."))
  end

  test "an abrupt broker death cleans identities already acknowledged by the parent" do
    fixture = migration_fixture!()
    test = self()

    hook = fn
      :after_snapshot, %{anchor: anchor} ->
        {_output, 0} =
          System.cmd("/bin/kill", ["-KILL", Integer.to_string(anchor.helper.os_pid)],
            stderr_to_stdout: true
          )

        send(test, :backup_broker_killed)
        :ok

      _point, _context ->
        :ok
    end

    result = create(fixture, test_hook: hook)
    assert_receive :backup_broker_killed, 30_000
    assert {:error, %{code: code}} = result
    assert code in [:backup_failed, :cleanup_pending]
    assert File.ls!(fixture.backup_dir) == []
    await_no_snapshots!(Path.dirname(fixture.db), 10_000)
  end

  test "a corrupt source refuses unchanged without a partial artifact" do
    fixture = migration_fixture!()
    File.write!(fixture.db, "corrupt source")
    File.chmod!(fixture.db, 0o600)
    before = source_state(fixture.db)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
  end

  test "an unsafe backup directory permission fails closed" do
    fixture = migration_fixture!()
    File.chmod!(fixture.backup_dir, 0o755)
    before = source_state(fixture.db)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert permissions(fixture.backup_dir) == 0o755
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
  end

  test "a foreign-key failure refuses before publishing a snapshot" do
    fixture = migration_fixture!()
    SchemaFixture.insert_foreign_key_violation!(fixture.db)
    before = source_state(fixture.db)

    assert {:error, %{code: :backup_failed}} = create(fixture)
    assert source_state(fixture.db) == before
    assert File.ls!(fixture.backup_dir) == []
  end

  test "ambiguous database-only and manifest-only final paths are never overwritten or deleted" do
    for half <- [:database, :manifest] do
      fixture = migration_fixture!()

      filename =
        if half == :database,
          do: @operation_id <> ".sqlite3",
          else: @operation_id <> ".manifest.json"

      partial = Path.join(fixture.backup_dir, filename)
      write_private!(partial, "previous invocation")
      before = source_state(fixture.db)

      assert {:error, %{code: :backup_failed}} = create(fixture)
      assert bounded_read!(partial, 1_024) == "previous invocation"
      assert source_state(fixture.db) == before
      assert File.ls!(fixture.backup_dir) == [filename]
    end
  end

  test "operation IDs are canonical UUIDs and test faults are a closed set" do
    fixture = migration_fixture!()

    for operation_id <- ["", "C608E2B2-441D-45FC-AE80-42199F63DDFF", "../artifact"] do
      assert {:error, %{code: :backup_failed}} =
               Gate.create(
                 fixture.db,
                 fixture.backup_dir,
                 operation_id,
                 fixture.lease,
                 fixture.decision,
                 uid: fixture.uid
               )
    end

    assert_raise ArgumentError, ~r/unsupported backup fault/, fn ->
      create(fixture, fault: :untrusted_runtime_atom)
    end

    assert File.ls!(fixture.backup_dir) == []
  end

  defp migration_fixture!(opts \\ []) do
    database =
      SchemaFixture.database!(
        Keyword.get(opts, :lineage, {:prefix, 20_260_923_000_000}),
        SwarmCode.Daemon.Test.LeaseFixture.build_root()
      )

    if Keyword.get(opts, :wal, false) do
      _writer = SchemaFixture.open_uncheckpointed_wal!(database)
    else
      SchemaFixture.insert_project!(
        database,
        "project-1",
        "private-token-that-must-not-be-in-the-manifest",
        "/private/project-1"
      )

      SchemaFixture.insert_project!(database, "project-2", "Second project", "/private/project-2")
    end

    assert {:ok, decision} = SchemaGate.check(database, MigrationManifest.load!(), "0.1.0-dev")

    assert decision.status ==
             if(Keyword.get(opts, :lineage) == :current, do: :ready, else: :migration_required)

    directory = Path.dirname(database)
    uid = File.lstat!(directory).uid
    backup_dir = Path.join(directory, "backups")
    File.mkdir!(backup_dir)
    File.chmod!(backup_dir, 0o700)
    fingerprint = database_fingerprint(database)

    lease =
      start_lease!(
        directory,
        uid,
        Keyword.get(opts, :lease_fingerprint, fingerprint)
      )

    %{
      db: database,
      lease: lease,
      decision: decision,
      backup_dir: backup_dir,
      uid: uid,
      fingerprint: fingerprint,
      secret: "private-token-that-must-not-be-in-the-manifest"
    }
  end

  defp prepared_database! do
    database =
      SchemaFixture.database!(
        {:prefix, 20_260_923_000_000},
        SwarmCode.Daemon.Test.LeaseFixture.build_root()
      )

    SchemaFixture.insert_project!(database, "project-1", "Project", "/private/project")
    database
  end

  defp schema_decision!(database) do
    assert {:ok, %{status: :migration_required} = decision} =
             SchemaGate.check(database, MigrationManifest.load!(), "0.1.0-dev")

    decision
  end

  defp start_lease!(_directory, uid, fingerprint) do
    unique = System.unique_integer([:positive, :monotonic])

    lease_root =
      Path.join(
        SwarmCode.Daemon.Test.LeaseFixture.build_root(),
        "backup-lease-#{unique}"
      )

    runtime = Path.join(lease_root, "runtime")
    File.mkdir_p!(runtime)
    File.chmod!(lease_root, 0o700)
    File.chmod!(runtime, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(lease_root) end)

    opts = [
      paths: SwarmCode.Daemon.Test.LeaseFixture.paths(lease_root, runtime),
      identity: %ProcessIdentity{
        uid: uid,
        pid: System.pid() |> String.to_integer(),
        process_start_id: "backup-gate-test:#{unique}",
        boot_id: "backup-gate-test"
      },
      database_fingerprint: fingerprint,
      schema_contract: %{
        epoch: 0,
        newest_migration: 20_260_929_000_000,
        manifest_sha256: "f04a55a27d1fee6a3192c6ff277993d4ab5a8f6414896e2be87dc3a41f48b75f"
      },
      app_version: "0.1.0-dev"
    ]

    child =
      opts
      |> CrossAppLease.child_spec()
      |> Map.put(:id, {CrossAppLease, unique})
      |> Map.put(:significant, false)

    start_supervised!(child)
  end

  defp create(fixture, opts \\ []) do
    defaults = [uid: fixture.uid, now: fn -> @verified_at end]

    Gate.create(
      fixture.db,
      fixture.backup_dir,
      @operation_id,
      fixture.lease,
      fixture.decision,
      Keyword.merge(defaults, opts)
    )
  end

  defp database_fingerprint(path) do
    {:ok, fingerprint} = DatabaseFingerprint.for_path(path)
    fingerprint
  end

  defp source_pin_path!(directory) do
    pins =
      directory
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".source-pin.sqlite3"))

    assert [pin] = pins
    Path.join(directory, pin)
  end

  defp random_suffix,
    do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp source_state(database) do
    %{
      "main" => file_state(database),
      "wal" => optional_file_state(database <> "-wal"),
      "shm" => optional_file_state(database <> "-shm")
    }
  end

  defp optional_file_state(path) do
    case File.lstat(path) do
      {:ok, _stat} -> file_state(path)
      {:error, :enoent} -> nil
    end
  end

  defp file_state(path) do
    stat = File.lstat!(path)

    %{
      type: stat.type,
      inode: stat.inode,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      size: stat.size,
      mode: band(stat.mode, 0o7777),
      uid: stat.uid,
      sha256: sha256_file(path)
    }
  end

  defp file_manifest_entry(path) do
    stat = File.lstat!(path)

    %{
      "name" => Path.basename(path),
      "size" => stat.size,
      "sha256" => sha256_file(path)
    }
  end

  defp sha256_file(path) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      hash_io(io, :crypto.hash_init(:sha256))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    after
      :ok = File.close(io)
    end
  end

  defp hash_io(io, context) do
    case IO.binread(io, 1024 * 1024) do
      :eof -> context
      bytes when is_binary(bytes) -> hash_io(io, :crypto.hash_update(context, bytes))
    end
  end

  defp sha256_iodata(iodata) do
    :crypto.hash(:sha256, iodata)
    |> Base.encode16(case: :lower)
  end

  defp rowid_sha256(rowid), do: sha256_iodata(["sqlite-rowid-v1\n", Integer.to_string(rowid)])

  defp decode_manifest!(path) do
    path
    |> bounded_read!(4_194_304)
    |> Jason.decode!()
  end

  defp bounded_read!(path, maximum_bytes) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      case IO.binread(io, maximum_bytes + 1) do
        bytes when is_binary(bytes) and byte_size(bytes) <= maximum_bytes -> bytes
        _other -> flunk("file exceeded the test read bound")
      end
    after
      :ok = File.close(io)
    end
  end

  defp write_private!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  defp copy_private!(source, destination) do
    File.cp!(source, destination)
    File.chmod!(destination, 0o600)
  end

  defp private_directory!(label) do
    directory = Path.join(System.tmp_dir!(), "swarm-code-#{label}-#{random_suffix()}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp private_child!(parent, name) do
    child = Path.join(parent, name)
    File.mkdir!(child)
    File.chmod!(child, 0o700)
    child
  end

  defp same_object?(left, right) do
    left_stat = File.lstat!(left)
    right_stat = File.lstat!(right)

    {left_stat.major_device, left_stat.minor_device, left_stat.inode} ==
      {right_stat.major_device, right_stat.minor_device, right_stat.inode}
  end

  defp wait_for_vacuum_journal!(directory, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_vacuum_journal!(directory, deadline)
  end

  defp do_wait_for_vacuum_journal!(directory, deadline) do
    journal_exists? =
      directory
      |> File.ls!()
      |> Enum.any?(fn name ->
        path = Path.join(directory, name)

        String.starts_with?(name, ".#{@operation_id}.") and
          String.ends_with?(name, ".sqlite3-journal") and
          match?({:ok, %File.Stat{type: :regular, size: size}} when size > 0, File.lstat(path))
      end)

    cond do
      journal_exists? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for the VACUUM journal entry")

      true ->
        :erlang.yield()
        do_wait_for_vacuum_journal!(directory, deadline)
    end
  end

  defp await_no_snapshots!(directory, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_no_snapshots!(directory, deadline)
  end

  defp do_await_no_snapshots!(directory, deadline) do
    cond do
      not Enum.any?(File.ls!(directory), &String.starts_with?(&1, ".swarm-snapshot-")) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("snapshot owner did not finish cleanup")

      true ->
        receive do
        after
          1 -> do_await_no_snapshots!(directory, deadline)
        end
    end
  end

  defp await_directory_empty!(directory, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_directory_empty!(directory, deadline)
  end

  defp await_directory_names!(directory, expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_directory_names!(directory, Enum.sort(expected), deadline)
  end

  defp do_await_directory_names!(directory, expected, deadline) do
    cond do
      Enum.sort(File.ls!(directory)) == expected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for the recoverable committed pair")

      true ->
        receive do
        after
          1 -> do_await_directory_names!(directory, expected, deadline)
        end
    end
  end

  defp do_await_directory_empty!(directory, deadline) do
    cond do
      File.ls!(directory) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for the held backup directory to be cleaned")

      true ->
        receive do
        after
          1 -> do_await_directory_empty!(directory, deadline)
        end
    end
  end

  defp permissions(path), do: band(File.lstat!(path).mode, 0o7777)
end
