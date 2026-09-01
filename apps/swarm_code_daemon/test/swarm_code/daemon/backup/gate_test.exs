defmodule SwarmCode.Daemon.Backup.GateTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias SwarmCode.Daemon.Backup.{Artifact, Gate}
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

    artifacts =
      Enum.map(tasks, fn task ->
        assert {:ok, artifact} = Task.await(task, 10_000)
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

  test "a decision other than migration_required refuses without source or output mutation" do
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
    database = SchemaFixture.database!({:prefix, 20_260_923_000_000})

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

    decision = schema_decision!(database)
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
    database = SchemaFixture.database!({:prefix, 20_260_923_000_000})
    SchemaFixture.insert_project!(database, "project-1", "Project", "/private/project")
    database
  end

  defp schema_decision!(database) do
    assert {:ok, %{status: :migration_required} = decision} =
             SchemaGate.check(database, MigrationManifest.load!(), "0.1.0-dev")

    decision
  end

  defp start_lease!(directory, uid, fingerprint) do
    unique = System.unique_integer([:positive, :monotonic])

    opts = [
      lease_path: Path.join(directory, "instance_lease-#{unique}.db"),
      owner_path: Path.join(directory, "instance_owner-#{unique}.json"),
      identity: %ProcessIdentity{
        uid: uid,
        pid: System.pid() |> String.to_integer(),
        process_start_id: "backup-gate-test:#{unique}",
        boot_id: "backup-gate-test"
      },
      database_fingerprint: fingerprint,
      schema_contract: %{
        epoch: 0,
        newest_migration: 20_260_926_000_000,
        manifest_sha256: "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0"
      },
      socket_path: Path.join(directory, "daemon-#{unique}.sock"),
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

  defp permissions(path), do: band(File.lstat!(path).mode, 0o7777)
end
