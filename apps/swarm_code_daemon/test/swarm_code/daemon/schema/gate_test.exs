defmodule SwarmCode.Daemon.Schema.GateTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Schema.{Gate, MigrationManifest, Probe}

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
    assert List.last(decision.applied) == 20_260_926_000_000
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
             20_260_926_000_000
           ]

    assert sha256_file(database) == before
  end

  test "unknown newer migration refuses without mutation", %{
    manifest: manifest,
    current: database
  } do
    SchemaFixture.insert_migration!(database, 20_990_101_000_000)
    before = sha256_file(database)

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check(database, manifest, "0.1.0-dev")

    assert sha256_file(database) == before
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

    assert length(pending) == 43
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
    assert List.last(probe.migration_versions) == 20_260_926_000_000

    assert probe.schema_sha256 ==
             "cb75e8448370fa9ca8c1f25969e1b491b035046e87f8b92374f5a1c704304db3"

    assert probe.quick_check == [["ok"]]
    assert probe.foreign_key_violations == []
    assert {:ok, %Version{}} = Version.parse(probe.sqlite_version)
    assert is_binary(probe.sqlite_source_id)
    assert sha256_file(database) == before
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

  defp sha256_file(path) do
    path
    |> File.stream!([], 64 * 1_024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
