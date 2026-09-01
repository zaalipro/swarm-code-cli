defmodule SwarmCode.Daemon.Schema.MigrationManifestTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Schema.MigrationManifest

  @first_version 20_260_820_000_001
  @last_version 20_260_926_000_000
  @migration_set_sha256 "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0"
  @final_schema_sha256 "cb75e8448370fa9ca8c1f25969e1b491b035046e87f8b92374f5a1c704304db3"

  test "loads the audited 43-entry desktop manifest as validated structs" do
    manifest = MigrationManifest.load!()

    assert manifest.manifest_version == 1
    assert manifest.contract == "desktop-dbb8804b"
    assert manifest.upstream_commit == "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"
    assert manifest.application_ids == [0]
    assert manifest.data_epoch == 0
    assert manifest.minimum_reader == "0.1.0-dev"
    assert manifest.minimum_writer == "0.1.0-dev"
    assert manifest.sqlite_minimum == "3.51.3"
    assert manifest.migration_set_sha256 == @migration_set_sha256
    assert manifest.legacy_handshake == "migration-prefix-plus-normalized-schema"
    assert length(manifest.migrations) == 43

    assert %MigrationManifest.Entry{
             version: @first_version,
             filename: "20260820000001_create_swarm_code_schema.exs",
             source_sha256: "7b85670338191af007a196d8b2bf4f88bde6511bddbfb9a5efc691a8c6606f44",
             additive_desktop_readable?: true
           } = hd(manifest.migrations)

    assert %MigrationManifest.Entry{
             version: @last_version,
             filename: "20260926000000_supersede_on_edit.exs",
             source_sha256: "9343537359fd75470d78bf4d72da4de5180ceb0e3b39d379e6c1348bc5fa4128",
             schema_sha256: @final_schema_sha256,
             additive_desktop_readable?: true
           } = List.last(manifest.migrations)
  end

  test "rejects extra top-level and migration keys instead of silently accepting them" do
    assert_invalid(fn decoded -> Map.put(decoded, "unexpected", true) end)

    assert_invalid(fn decoded ->
      update_in(decoded, ["migrations", Access.at(0)], &Map.put(&1, "unexpected", true))
    end)
  end

  test "rejects noncanonical digests, filenames, versions, and ordering" do
    assert_invalid(fn decoded ->
      Map.put(decoded, "migration_set_sha256", String.duplicate("A", 64))
    end)

    assert_invalid(fn decoded ->
      update_in(decoded, ["migrations", Access.at(0), "filename"], fn _ ->
        "20260820000002_create_swarm_code_schema.exs"
      end)
    end)

    assert_invalid(fn decoded ->
      update_in(decoded, ["migrations"], fn [first, second | rest] ->
        [second, first | rest]
      end)
    end)
  end

  test "rejects unsupported application IDs and malformed semantic versions" do
    assert_invalid(&Map.put(&1, "application_ids", [1]))
    assert_invalid(&Map.put(&1, "minimum_reader", "v0.1"))
    assert_invalid(&Map.put(&1, "sqlite_minimum", "3.51"))
  end

  test "rejects alternate canonical semantic versions for every audited minimum" do
    assert_invalid(&Map.put(&1, "minimum_reader", "0.2.0"))
    assert_invalid(&Map.put(&1, "minimum_writer", "0.0.9"))
    assert_invalid(&Map.put(&1, "sqlite_minimum", "3.50.0"))
  end

  test "malformed runtime keys do not create atoms" do
    key = "runtime-key-#{System.unique_integer([:positive, :monotonic])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert_invalid(&Map.put(&1, key, true))
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  defp assert_invalid(transform) do
    decoded = default_manifest_path() |> File.read!() |> Jason.decode!() |> transform.()
    path = temporary_manifest_path()
    File.write!(path, Jason.encode_to_iodata!(decoded))

    assert_raise ArgumentError, fn -> MigrationManifest.load!(path) end
  end

  defp default_manifest_path do
    :swarm_code_daemon
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("schema/desktop-dbb8804b.json")
  end

  defp temporary_manifest_path do
    directory =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-manifest-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    Path.join(directory, "manifest.json")
  end
end
