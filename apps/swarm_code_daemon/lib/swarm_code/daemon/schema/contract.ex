defmodule SwarmCode.Daemon.Schema.Contract do
  @moduledoc "Immutable identities of the audited desktop schema lineages."

  @legacy %{
    commit: "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
    name: "desktop-dbb8804b",
    migration_count: 43,
    migration_set_sha256: "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0",
    final_schema_sha256: "cb75e8448370fa9ca8c1f25969e1b491b035046e87f8b92374f5a1c704304db3",
    lineage_sha256: "2339aca6efb5527447be628cda89934787ef7127179d600aabcd714b9089c756",
    last_version: 20_260_926_000_000,
    last_filename: "20260926000000_supersede_on_edit.exs",
    last_source_sha256: "9343537359fd75470d78bf4d72da4de5180ceb0e3b39d379e6c1348bc5fa4128",
    snapshot_versions: [20_260_923_000_000, 20_260_924_000_000, 20_260_926_000_000]
  }
  @current %{
    commit: "fb1b4ff82354ac8ff2e82d4f6516121fd55ff212",
    name: "desktop-fb1b4ff",
    migration_count: 46,
    migration_set_sha256: "f04a55a27d1fee6a3192c6ff277993d4ab5a8f6414896e2be87dc3a41f48b75f",
    final_schema_sha256: "0f4b2b71ccd619b82a355062cfa405fc64b6cf982d6d2917631c57d688e833ea",
    lineage_sha256: "9369f60399bd6c15e38180eaf628ebb31c381b34806c37cf92617d7d4bed5d43",
    last_version: 20_260_929_000_000,
    last_filename: "20260929000000_bench_layout.exs",
    last_source_sha256: "d2b8980ec14149a54a005d2cf91c6761897e209680acf6b215171be20828eba2",
    snapshot_versions: [
      20_260_923_000_000,
      20_260_924_000_000,
      20_260_926_000_000,
      20_260_927_000_000,
      20_260_928_000_000,
      20_260_929_000_000
    ]
  }

  @spec current() :: map()
  def current, do: @current

  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch("dbb8804b3d7293178e571fa7afdf6bd47d06a51c"), do: {:ok, @legacy}
  def fetch("fb1b4ff82354ac8ff2e82d4f6516121fd55ff212"), do: {:ok, @current}
  def fetch(_), do: :error

  @spec maximum_migrations() :: pos_integer()
  def maximum_migrations, do: @current.migration_count

  @doc false
  @spec lineage_sha256([map()]) :: binary()
  def lineage_sha256(entries) do
    entries
    |> Enum.map(fn entry ->
      # Both consumers validate the closed true readability flag before this
      # digest: the generator's audited output and MigrationManifest.Entry.
      [
        Integer.to_string(entry.version),
        entry.filename,
        entry.source_sha256,
        entry.schema_sha256,
        "true"
      ]
      |> Enum.map(fn field -> [Integer.to_string(byte_size(field)), ?:, field, ?\n] end)
    end)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
