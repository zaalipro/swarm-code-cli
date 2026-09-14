defmodule SwarmCode.Daemon.Schema.GateTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Schema.{Gate, MigrationManifest, Probe}

  # Migrations the pinned contract appends after the former desktop-fb1b4ff tail.
  @appended_suffix [
    20_260_930_000_000,
    20_261_001_000_000,
    20_261_001_000_001,
    20_261_015_000_000,
    20_261_015_000_001,
    20_261_015_000_002,
    20_261_015_000_003
  ]

  setup do
    manifest = MigrationManifest.load!()
    %{manifest: manifest, current: SchemaFixture.database!(:current)}
  end

  test "the audited desktop lineage is ready without mutation", %{
    manifest: manifest,
    current: database
  } do
    before = sha256_file(database)

    assert {:ok, decision} = Gate.check(database, manifest, "0.1.0-dev")
    assert decision.status == :ready
    assert List.last(decision.applied) == 20_261_015_000_003
    assert decision.pending == []
    assert sha256_file(database) == before
  end

  test "a supported exact prefix requests only its suffix", %{manifest: manifest} do
    database = SchemaFixture.database!({:prefix, 20_260_923_000_000})
    before = sha256_file(database)

    assert {:ok, %{status: :migration_required, pending: pending}} =
             Gate.check(database, manifest, "0.1.0-dev")

    assert Enum.map(pending, & &1.version) == [
             20_260_924_000_000,
             20_260_925_000_000,
             20_260_926_000_000,
             20_260_927_000_000,
             20_260_928_000_000,
             20_260_929_000_000 | @appended_suffix
           ]

    assert sha256_file(database) == before
  end

  for {version, pending_versions} <- [
        {20_260_926_000_000,
         [20_260_927_000_000, 20_260_928_000_000, 20_260_929_000_000 | @appended_suffix]},
        {20_260_927_000_000, [20_260_928_000_000, 20_260_929_000_000 | @appended_suffix]},
        {20_260_928_000_000, [20_260_929_000_000 | @appended_suffix]},
        {20_260_929_000_000, @appended_suffix}
      ] do
    test "the exact #{version} prefix requests its current suffix", %{manifest: manifest} do
      database = SchemaFixture.database!({:prefix, unquote(version)})
      before = source_bytes(database)

      assert {:ok, %{status: :migration_required, pending: pending}} =
               Gate.check(database, manifest, "0.1.0-dev")

      assert Enum.map(pending, & &1.version) == unquote(pending_versions)
      assert source_bytes(database) == before
    end
  end

  test "the explicit final prefix is the current schema", %{manifest: manifest} do
    database = SchemaFixture.database!({:prefix, 20_261_015_000_003})

    assert {:ok, %{status: :ready, applied: applied}} =
             Gate.check(database, manifest, "0.1.0-dev")

    assert length(applied) == 53
  end

  test "a wrong current column shape refuses with source and WAL sidecars unchanged", %{
    manifest: manifest
  } do
    database = SchemaFixture.database!(:current)

    SchemaFixture.exec!(
      database,
      "ALTER TABLE providers DROP COLUMN fallbacks; ALTER TABLE providers ADD COLUMN fallbacks TEXT DEFAULT 'true' NOT NULL"
    )

    _writer = SchemaFixture.open_uncheckpointed_wal!(database)
    before = source_bytes(database)
    assert {:ok, _} = File.stat(database <> "-wal")
    assert {:error, %{code: :schema_incompatible}} = Gate.check(database, manifest, "0.1.0-dev")
    assert source_bytes(database) == before
  end

  test "unknown newer migration refuses without mutation", %{
    manifest: manifest,
    current: database
  } do
    SchemaFixture.insert_migration!(database, 20_990_101_000_000)
    _writer = SchemaFixture.open_uncheckpointed_wal!(database)
    before = source_bytes(database)

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check(database, manifest, "0.1.0-dev")

    assert source_bytes(database) == before
  end

  test "known versions with a gap and a normalized-schema mismatch refuse", %{
    manifest: manifest
  } do
    gap = SchemaFixture.database!({:prefix, 20_260_924_000_000})
    SchemaFixture.delete_migration!(gap, 20_260_923_000_000)
    gap_before = sha256_file(gap)

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check(gap, manifest, "0.1.0-dev")

    assert sha256_file(gap) == gap_before

    drift = SchemaFixture.database!(:current)
    SchemaFixture.exec!(drift, "CREATE TABLE injected(value TEXT)")
    drift_before = sha256_file(drift)

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check(drift, manifest, "0.1.0-dev")

    assert sha256_file(drift) == drift_before
  end

  test "an absent path is a new database and is not created", %{manifest: manifest} do
    directory = temporary_directory!()
    database = Path.join(directory, "absent.db")

    assert {:ok, %{status: :new_database, applied: [], pending: pending}} =
             Gate.check(database, manifest, "0.1.0-dev")

    assert length(pending) == 53
    refute File.exists?(database)
  end

  test "zero-byte and non-SQLite existing files refuse unchanged", %{manifest: manifest} do
    directory = temporary_directory!()

    for {filename, contents} <- [{"zero.db", <<>>}, {"garbage.db", "not sqlite"}] do
      database = Path.join(directory, filename)
      File.write!(database, contents)
      before = sha256_file(database)

      assert {:error, %{code: :schema_incompatible}} =
               Gate.check(database, manifest, "0.1.0-dev")

      assert sha256_file(database) == before
    end
  end

  test "an unsupported application ID refuses unchanged", %{
    manifest: manifest,
    current: database
  } do
    SchemaFixture.exec!(database, "PRAGMA application_id=1398227282")
    before = sha256_file(database)

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check(database, manifest, "0.1.0-dev")

    assert sha256_file(database) == before
  end

  test "the probe returns the exact read-only handshake metadata", %{current: database} do
    before = sha256_file(database)

    assert {:ok, probe} = Probe.inspect(database)
    assert probe.application_id == 0
    assert hd(probe.migration_versions) == 20_260_820_000_001
    assert List.last(probe.migration_versions) == 20_261_015_000_003

    assert probe.schema_sha256 ==
             "cd6ee5ce99c4adc8587993eb9b4cf4758e7e4e6c31bc28cc64b3df8395777b82"

    assert probe.quick_check == [["ok"]]
    assert probe.foreign_key_violations == []
    assert {:ok, %Version{}} = Version.parse(probe.sqlite_version)
    assert is_binary(probe.sqlite_source_id)
    assert sha256_file(database) == before
  end

  test "the probe rejects on the 54th migration row without mutation", %{current: database} do
    SchemaFixture.insert_migration!(database, 20_990_101_000_000)
    _writer = SchemaFixture.open_uncheckpointed_wal!(database)
    before = source_bytes(database)

    assert {:error, %{code: :schema_incompatible}} = Probe.inspect(database)
    assert source_bytes(database) == before
  end

  test "a fresh live WAL admits current schema with original bindings and exact source bytes", %{
    manifest: manifest,
    current: database
  } do
    _writer = SchemaFixture.open_uncheckpointed_wal!(database)
    before = source_bytes(database)
    main = File.lstat!(database)
    wal = File.lstat!(database <> "-wal")

    assert {:ok, %{probe: probe, binding: binding}} = Probe.inspect_bound(database)
    assert length(probe.migration_versions) == 53
    assert binding.path == database
    assert elem(binding.identity, 3) == main.inode
    assert elem(binding.sidecars["-wal"], 3) == wal.inode
    assert {:ok, %{status: :ready}} = Gate.check(database, manifest, "0.1.0-dev")
    assert source_bytes(database) == before

    assert Enum.sort(File.ls!(Path.dirname(database))) ==
             ["fixture.db", "fixture.db-shm", "fixture.db-wal"]
  end

  test "a complete WAL without SHM admits current schema without creating a source SHM", %{
    manifest: manifest,
    current: database
  } do
    # The fixture writer is idle throughout these copies. No source SHM is removed.
    _writer = SchemaFixture.open_uncheckpointed_wal!(database)
    directory = temporary_directory!()
    File.chmod!(directory, 0o700)
    copied = Path.join(directory, "copied.db")

    for suffix <- ["", "-wal"] do
      File.cp!(database <> suffix, copied <> suffix)
      File.chmod!(copied <> suffix, 0o600)
    end

    before = source_bytes(copied)
    assert {:ok, %{status: :ready}} = Gate.check(copied, manifest, "0.1.0-dev")
    assert source_bytes(copied) == before
    assert Enum.sort(File.ls!(directory)) == ["copied.db", "copied.db-wal"]
  end

  test "a source replaced before copying cannot yield an admitted snapshot", %{current: database} do
    replacement = SchemaFixture.database!(:current)
    parked = database <> ".parked"

    hook = fn :before_sqlite_open, ^database ->
      File.rename!(database, parked)
      File.rename!(replacement, database)
      :ok
    end

    assert {:error, %{code: :schema_incompatible}} =
             Probe.inspect_bound(database, before_open: hook)

    assert File.exists?(parked)
    assert Enum.sort(File.ls!(Path.dirname(database))) == ["fixture.db", "fixture.db.parked"]
  end

  test "probe resolves symlink dot-dot physically and keeps the original source binding", %{
    current: database
  } do
    root = Path.dirname(database)
    nested = Path.join(root, "nested")
    child = Path.join(nested, "child")
    File.mkdir!(nested)
    File.mkdir!(child)
    File.chmod!(nested, 0o700)
    File.chmod!(child, 0o700)
    actual = Path.join(nested, "fixture.db")
    File.cp!(database, actual)
    File.chmod!(actual, 0o600)
    SchemaFixture.exec!(actual, "PRAGMA application_id=123")
    File.ln_s!(child, Path.join(root, "link"))
    input = Path.join(root, "link") <> "/../fixture.db"
    assert Path.expand(input) == database
    before = source_bytes(actual)

    assert {:ok, %{probe: probe, binding: binding}} = Probe.inspect_bound(input)
    assert probe.application_id == 123
    assert binding.path == input
    assert elem(binding.identity, 3) == File.lstat!(actual).inode
    assert source_bytes(actual) == before
  end

  test "the probe rejects more than 512 normalized schema rows without mutation", %{
    current: database
  } do
    statements =
      for number <- 1..513 do
        "CREATE TABLE injected_#{number}(value TEXT);"
      end

    SchemaFixture.exec!(database, IO.iodata_to_binary(statements))
    before = sha256_file(database)

    assert {:error, %{code: :schema_incompatible}} = Probe.inspect(database)
    assert sha256_file(database) == before
  end

  @tag timeout: 30_000
  test "the probe rejects more than 4194304 normalized schema bytes without mutation", %{
    current: database
  } do
    payload = String.duplicate("x", 4_194_304)
    SchemaFixture.exec!(database, "CREATE VIEW oversized AS SELECT '#{payload}' AS value")
    before = sha256_file(database)

    assert {:error, %{code: :schema_incompatible}} = Probe.inspect(database)
    assert sha256_file(database) == before
  end

  test "the probe records only whether a foreign-key violation exists", %{current: database} do
    SchemaFixture.exec!(
      database,
      """
      CREATE TABLE injected_parent(id INTEGER PRIMARY KEY);
      CREATE TABLE injected_child(
        id INTEGER PRIMARY KEY,
        parent_id INTEGER REFERENCES injected_parent(id)
      );
      INSERT INTO injected_child(id, parent_id) VALUES (1, 10), (2, 20);
      """
    )

    assert {:ok, probe} = Probe.inspect(database)
    assert probe.foreign_key_violations == [[1]]
  end

  test "ready admission refuses a world-readable database and sidecar", %{manifest: manifest} do
    database = SchemaFixture.database!(:current)
    File.chmod!(database, 0o644)

    assert {:error, %{code: :schema_incompatible}} = Gate.check(database, manifest, "0.1.0-dev")
    assert Bitwise.band(File.lstat!(database).mode, 0o7777) == 0o644
  end

  test "post-probe replacement cannot produce a ready decision", %{manifest: manifest} do
    database = SchemaFixture.database!(:current)
    replacement = SchemaFixture.database!(:current)
    parked = database <> ".parked"

    hook = fn :after_probe, ^database ->
      File.rename!(database, parked)
      File.rename!(replacement, database)
      :ok
    end

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check_bound(database, manifest, "0.1.0-dev", probe_hook: hook)

    assert File.exists?(parked)
    assert File.exists?(database)
  end

  test "a sidecar appearing during the probe cannot enter a ready handoff", %{manifest: manifest} do
    database = SchemaFixture.database!(:current)

    hook = fn :after_probe, path ->
      File.write!(path <> "-wal", "late sidecar", [:exclusive])
      File.chmod!(path <> "-wal", 0o600)
      :ok
    end

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check_bound(database, manifest, "0.1.0-dev", probe_hook: hook)
  end

  defp temporary_directory! do
    directory =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-schema-gate-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp source_bytes(database) do
    Map.new(["", "-wal", "-shm"], fn suffix ->
      {suffix,
       case File.read(database <> suffix) do
         {:ok, bytes} -> {:present, byte_size(bytes), :crypto.hash(:sha256, bytes)}
         {:error, :enoent} -> :absent
       end}
    end)
  end

  defp sha256_file(path) do
    path
    |> File.stream!([], 64 * 1_024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
