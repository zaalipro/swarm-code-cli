defmodule SwarmCode.Daemon.Schema.ManifestGenerator do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :swarm_code_daemon,
    adapter: Ecto.Adapters.SQLite3

  alias SwarmCode.Daemon.Files.AtomicReplace

  @pinned_commit "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"
  @migration_count 43
  @migration_set_sha256 "408afb8e6eb422c8df50fe65536a08f853475c162d584db45b4af708274fd1d0"
  @final_schema_sha256 "cb75e8448370fa9ca8c1f25969e1b491b035046e87f8b92374f5a1c704304db3"
  @first_source_sha256 "7b85670338191af007a196d8b2bf4f88bde6511bddbfb9a5efc691a8c6606f44"
  @last_source_sha256 "9343537359fd75470d78bf4d72da4de5180ceb0e3b39d379e6c1348bc5fa4128"
  @snapshot_versions [20_260_923_000_000, 20_260_924_000_000, 20_260_926_000_000]

  @spec run!([String.t()]) :: :ok
  def run!(argv) do
    {:ok, _started} = Application.ensure_all_started(:ecto_sqlite3)
    opts = parse_args!(argv)
    verify_source!(opts.upstream, opts.commit)
    migrations = read_migrations!(opts.upstream, opts.commit)
    verify_migration_sources!(migrations)

    temporary_directory =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-schema-manifest-#{random_suffix()}"
      )

    File.mkdir!(temporary_directory)

    try do
      File.chmod!(temporary_directory, 0o700)
      {entries, snapshots} = migrate_and_inspect!(temporary_directory, migrations)
      verify_generated_lineage!(entries)
      write_outputs!(opts.output, opts.fixtures_dir, entries, snapshots, opts.upstream)
    after
      File.rm_rf!(temporary_directory)
    end
  end

  defp parse_args!(argv) do
    argv =
      case argv do
        ["--" | arguments] -> arguments
        arguments -> arguments
      end

    {parsed, positional, invalid} =
      OptionParser.parse(argv,
        strict: [upstream: :string, commit: :string, output: :string, fixtures_dir: :string]
      )

    required = [:upstream, :commit, :output, :fixtures_dir]

    if positional != [] or invalid != [] or length(parsed) != length(required) or
         Enum.sort(Keyword.keys(parsed)) != Enum.sort(required) do
      raise ArgumentError,
            "expected exactly --upstream PATH --commit COMMIT --output PATH --fixtures-dir PATH"
    end

    opts = Map.new(parsed)

    if opts.commit != @pinned_commit do
      raise ArgumentError, "unsupported upstream commit"
    end

    if Enum.any?(required, &(not is_binary(Map.fetch!(opts, &1)) or Map.fetch!(opts, &1) == "")) do
      raise ArgumentError, "manifest generator paths must not be empty"
    end

    opts
  end

  defp verify_source!(upstream, commit) do
    unless File.dir?(upstream) do
      raise ArgumentError, "upstream must be an existing Git worktree"
    end

    case git(upstream, ["status", "--porcelain", "--untracked-files=all"]) do
      {"", 0} -> :ok
      {_dirty, 0} -> raise ArgumentError, "upstream worktree must be clean"
      {_output, _status} -> raise ArgumentError, "unable to inspect upstream worktree"
    end

    case git(upstream, ["cat-file", "-e", "#{commit}^{commit}"]) do
      {"", 0} -> :ok
      {_output, _status} -> raise ArgumentError, "pinned upstream commit is unavailable"
    end
  end

  defp read_migrations!(upstream, commit) do
    {tree, 0} =
      git!(upstream, [
        "ls-tree",
        "-r",
        "--name-only",
        commit,
        "--",
        "priv/repo/migrations"
      ])

    migrations =
      tree
      |> String.split("\n", trim: true)
      |> Enum.filter(&Regex.match?(~r{/\d[^/]*\.exs\z}, &1))
      |> Enum.map(fn path ->
        filename = Path.basename(path)

        case Regex.run(~r/\A(\d{14})_[a-z0-9_]+\.exs\z/, filename, capture: :all_but_first) do
          [version] ->
            {source, 0} = git!(upstream, ["show", "#{commit}:#{path}"])

            %{
              version: String.to_integer(version),
              filename: filename,
              source: source,
              source_sha256: sha256(source)
            }

          _other ->
            raise ArgumentError, "invalid migration filename in pinned tree"
        end
      end)
      |> Enum.sort_by(& &1.version)

    if length(migrations) != @migration_count do
      raise ArgumentError, "expected exactly #{@migration_count} pinned migrations"
    end

    migrations
  end

  defp verify_migration_sources!(migrations) do
    versions = Enum.map(migrations, & &1.version)

    unless versions == Enum.uniq(versions) do
      raise ArgumentError, "migration versions must be unique"
    end

    first = hd(migrations)
    last = List.last(migrations)

    unless first.version == 20_260_820_000_001 and
             first.filename == "20260820000001_create_swarm_code_schema.exs" and
             first.source_sha256 == @first_source_sha256 do
      raise ArgumentError, "pinned first migration sentinel does not match"
    end

    unless last.version == 20_260_926_000_000 and
             last.filename == "20260926000000_supersede_on_edit.exs" and
             last.source_sha256 == @last_source_sha256 do
      raise ArgumentError, "pinned last migration sentinel does not match"
    end

    migration_set =
      migrations
      |> Enum.map(fn migration ->
        [
          Integer.to_string(migration.version),
          0,
          migration.filename,
          0,
          migration.source_sha256,
          ?\n
        ]
      end)
      |> IO.iodata_to_binary()
      |> sha256()

    unless migration_set == @migration_set_sha256 do
      raise ArgumentError, "pinned migration-set digest does not match"
    end
  end

  defp migrate_and_inspect!(temporary_directory, migrations) do
    database = Path.join(temporary_directory, "fixture.db")
    migrations_directory = Path.join(temporary_directory, "migrations")
    File.mkdir!(migrations_directory)

    {:ok, repo} =
      start_link(
        database: database,
        pool_size: 1,
        journal_mode: :delete,
        foreign_keys: :on,
        log: false
      )

    try do
      Enum.map_reduce(migrations, %{}, fn migration, snapshots ->
        migration_path = Path.join(migrations_directory, migration.filename)
        File.write!(migration_path, migration.source, [:binary, :exclusive])
        migration_module = compile_single_migration!(migration_path)

        :ok = Ecto.Migrator.up(__MODULE__, migration.version, migration_module, log: false)

        entry = %{
          version: migration.version,
          filename: migration.filename,
          source_sha256: migration.source_sha256,
          schema_sha256: normalized_schema_sha256!()
        }

        snapshots =
          if migration.version in @snapshot_versions do
            Map.put(snapshots, migration.version, schema_fixture_sql!())
          else
            snapshots
          end

        {entry, snapshots}
      end)
    after
      GenServer.stop(repo)
    end
  end

  defp compile_single_migration!(path) do
    modules = Code.compile_file(path) |> Enum.map(&elem(&1, 0))

    case modules do
      [module] -> module
      _other -> raise ArgumentError, "each pinned migration must define exactly one module"
    end
  end

  defp normalized_schema_sha256! do
    rows =
      query_rows!("""
      SELECT type, name, tbl_name, coalesce(sql, '')
      FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name
      """)

    schema_iodata =
      Enum.flat_map(rows, fn row ->
        Enum.map(row, fn value ->
          bytes = to_string(value)
          [Integer.to_string(byte_size(bytes)), ?:, bytes, ?\n]
        end)
      end)

    schema_iodata
    |> IO.iodata_to_binary()
    |> sha256()
  end

  defp schema_fixture_sql! do
    ddl_rows =
      query_rows!("""
      SELECT sql
      FROM sqlite_schema
      WHERE name NOT LIKE 'sqlite_%' AND sql IS NOT NULL
      ORDER BY
        CASE type
          WHEN 'table' THEN 0
          WHEN 'index' THEN 1
          WHEN 'trigger' THEN 2
          WHEN 'view' THEN 3
          ELSE 4
        END,
        name
      """)

    versions =
      query_rows!("SELECT version FROM schema_migrations ORDER BY version")
      |> Enum.map(fn [version] -> version end)

    ddl =
      Enum.map(ddl_rows, fn [sql] ->
        [String.trim_trailing(sql, ";"), ";\n"]
      end)

    inserts =
      Enum.map(versions, fn version ->
        [
          "INSERT INTO schema_migrations(version, inserted_at) VALUES (",
          Integer.to_string(version),
          ", '1970-01-01T00:00:00.000000');\n"
        ]
      end)

    [ddl, inserts] |> IO.iodata_to_binary()
  end

  defp query_rows!(sql) do
    __MODULE__
    |> Ecto.Adapters.SQL.query!(sql, [], log: false)
    |> Map.fetch!(:rows)
  end

  defp verify_generated_lineage!(entries) do
    unless length(entries) == @migration_count and
             List.last(entries).schema_sha256 == @final_schema_sha256 do
      raise ArgumentError, "generated final normalized schema digest does not match"
    end
  end

  defp write_outputs!(output, fixtures_dir, entries, snapshots, upstream) do
    File.mkdir_p!(Path.dirname(output))
    File.mkdir_p!(fixtures_dir)

    outputs = [
      {output, manifest_json(entries)},
      {Path.join(fixtures_dir, "desktop-20260923000000.sql"),
       Map.fetch!(snapshots, 20_260_923_000_000)},
      {Path.join(fixtures_dir, "desktop-20260924000000.sql"),
       Map.fetch!(snapshots, 20_260_924_000_000)},
      {Path.join(fixtures_dir, "desktop-current.sql"), Map.fetch!(snapshots, 20_260_926_000_000)}
    ]

    Enum.each(outputs, fn {_path, contents} ->
      if contents =~ upstream do
        raise ArgumentError, "generated metadata contains an absolute upstream path"
      end
    end)

    Enum.each(outputs, fn {path, contents} ->
      case AtomicReplace.write(path, contents, mode: 0o644) do
        :ok -> :ok
        {:error, reason} -> raise File.Error, reason: inspect(reason), action: "write", path: path
      end
    end)
  end

  defp manifest_json(entries) do
    migrations =
      entries
      |> Enum.map(&entry_json/1)
      |> Enum.intersperse(",\n")

    [
      "{\n",
      "  \"manifest_version\": 1,\n",
      "  \"contract\": \"desktop-dbb8804b\",\n",
      "  \"upstream_commit\": \"#{@pinned_commit}\",\n",
      "  \"application_ids\": [0],\n",
      "  \"data_epoch\": 0,\n",
      "  \"minimum_reader\": \"0.1.0-dev\",\n",
      "  \"minimum_writer\": \"0.1.0-dev\",\n",
      "  \"sqlite_minimum\": \"3.51.3\",\n",
      "  \"migration_set_sha256\": \"#{@migration_set_sha256}\",\n",
      "  \"legacy_handshake\": \"migration-prefix-plus-normalized-schema\",\n",
      "  \"migrations\": [\n",
      migrations,
      "\n  ]\n",
      "}\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp entry_json(entry) do
    [
      "    {\n",
      "      \"version\": ",
      Integer.to_string(entry.version),
      ",\n",
      "      \"filename\": ",
      Jason.encode_to_iodata!(entry.filename),
      ",\n",
      "      \"source_sha256\": \"#{entry.source_sha256}\",\n",
      "      \"schema_sha256\": \"#{entry.schema_sha256}\",\n",
      "      \"additive_desktop_readable\": true\n",
      "    }"
    ]
  end

  defp git!(upstream, args) do
    case git(upstream, args) do
      {output, 0} -> {output, 0}
      {_output, _status} -> raise ArgumentError, "pinned Git object could not be read"
    end
  end

  defp git(upstream, args) do
    System.cmd("git", ["-C", upstream | args],
      stderr_to_stdout: true,
      env: [{"LC_ALL", "C"}]
    )
  end

  defp sha256(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  defp random_suffix do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end

:ok = SwarmCode.Daemon.Schema.ManifestGenerator.run!(System.argv())
