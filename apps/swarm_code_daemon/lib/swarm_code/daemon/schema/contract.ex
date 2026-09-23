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
  @previous %{
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
  @ccb1973 %{
    commit: "ccb19732c7225a6bc88556f8f743bab7bda41a5b",
    name: "desktop-ccb1973",
    migration_count: 53,
    migration_set_sha256: "16c5bb6d88c007fad7042c6f13afa65455a8a6157e2e86c25d68748d7c984e82",
    final_schema_sha256: "cd6ee5ce99c4adc8587993eb9b4cf4758e7e4e6c31bc28cc64b3df8395777b82",
    lineage_sha256: "007e492e7f3fa431b5da83071d30ccf2db5f9bf536dbda97246fac4454cace8b",
    last_version: 20_261_015_000_003,
    last_filename: "20261015000003_sub_agent_timeout.exs",
    last_source_sha256: "df5bacfee3402e35dcc7c6f1b3a4c944f9ff4359c1920be865b00fe02beb653b",
    snapshot_versions: [
      20_260_923_000_000,
      20_260_924_000_000,
      20_260_926_000_000,
      20_260_927_000_000,
      20_260_928_000_000,
      20_260_929_000_000,
      20_261_015_000_003
    ]
  }
  # Desktop pass 69. The four migrations after ccb1973 are additive (three
  # defaulted `settings` columns and the `messages_fts` FTS5 index with its
  # triggers), so an older desktop keeps working on a database the CLI moved
  # forward: they are the only versions the CLI may run itself
  # (`forward_compatible`, see `Schema.Gate.admit_migration/2`).
  @current %{
    commit: "6dd8d82ef29f9a6608b942259e1801846bb87ed9",
    name: "desktop-6dd8d82",
    migration_count: 57,
    migration_set_sha256: "4c0a8ec7fa4ca33aba4ca17ee300b98e1be008e165e7ff18f69d05943137e23f",
    final_schema_sha256: "a0145e85d9d401c8f95bf724f91d5930694ab6adb487335c7a25857b7a63cc87",
    lineage_sha256: "ffdb70fb5b5d0a9140450bc330cc1ad368a596798300800754eda5c856cc1298",
    last_version: 20_261_017_000_004,
    last_filename: "20261017000004_isolation_backend.exs",
    last_source_sha256: "0051949533fe1318fe94b08f557b4db4b526641ff947fe117f4237e714c8fd16",
    snapshot_versions: [
      20_260_923_000_000,
      20_260_924_000_000,
      20_260_926_000_000,
      20_260_927_000_000,
      20_260_928_000_000,
      20_260_929_000_000,
      20_261_015_000_003,
      20_261_015_000_004,
      20_261_016_000_001,
      20_261_016_000_002,
      20_261_017_000_004
    ],
    forward_compatible: [
      20_261_015_000_004,
      20_261_016_000_001,
      20_261_016_000_002,
      20_261_017_000_004
    ]
  }

  @spec current() :: map()
  def current, do: @current

  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch("dbb8804b3d7293178e571fa7afdf6bd47d06a51c"), do: {:ok, @legacy}
  def fetch("fb1b4ff82354ac8ff2e82d4f6516121fd55ff212"), do: {:ok, @previous}
  def fetch("ccb19732c7225a6bc88556f8f743bab7bda41a5b"), do: {:ok, @ccb1973}
  def fetch("6dd8d82ef29f9a6608b942259e1801846bb87ed9"), do: {:ok, @current}
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
