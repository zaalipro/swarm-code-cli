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
    validate_output_paths!(opts)
    upstream_identity = directory_identity!(opts.upstream)
    initial_porcelain = verify_source!(opts.upstream, opts.commit)

    try do
      migrations = read_migrations!(opts.upstream, opts.commit)
      verify_migration_sources!(migrations)

      temporary_directory =
        Path.join(
          System.tmp_dir!(),
          "swarm-code-schema-manifest-#{random_suffix()}"
        )

      reject_upstream_destination!(temporary_directory, opts.upstream)
      File.mkdir!(temporary_directory)

      try do
        File.chmod!(temporary_directory, 0o700)
        {entries, snapshots} = migrate_and_inspect!(temporary_directory, migrations)
        verify_generated_lineage!(entries)
        write_outputs!(opts.output, opts.fixtures_dir, entries, snapshots, opts.upstream)
      after
        File.rm_rf!(temporary_directory)
      end
    after
      verify_upstream_identity!(opts.upstream, upstream_identity)
      validate_output_paths!(opts)
      verify_porcelain_unchanged!(opts.upstream, initial_porcelain)
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

  defp validate_output_paths!(opts) do
    reject_upstream_destination!(opts.output, opts.upstream)
    reject_upstream_destination!(opts.fixtures_dir, opts.upstream)
    validate_output_path_syntax!(opts.output)
    validate_output_path_syntax!(opts.fixtures_dir)
  end

  defp validate_output_path_syntax!(path) do
    if Enum.any?(Path.split(path), &(&1 in [".", ".."])) do
      raise ArgumentError, "generator output paths must not contain dot or canceled components"
    end
  end

  defp reject_upstream_destination!(destination, upstream) do
    upstream_identity = directory_identity!(upstream)
    existing_ancestor = destination_existing_base!(Path.absname(destination))

    if ancestor_identity?(existing_ancestor, upstream_identity, MapSet.new()) do
      raise ArgumentError, "generator outputs must resolve outside upstream worktree"
    end
  end

  defp directory_identity!(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        filesystem_identity(stat)

      {:ok, _stat} ->
        raise ArgumentError, "generator path is not a directory"

      {:error, reason} ->
        raise ArgumentError, "generator path cannot be resolved: #{inspect(reason)}"
    end
  end

  defp destination_existing_base!(path) do
    case Path.split(path) do
      [root | components] -> resolve_destination_components!(root, components, 0)
      [] -> raise ArgumentError, "generator destination path must not be empty"
    end
  end

  defp resolve_destination_components!(existing, [], _missing_depth), do: existing

  defp resolve_destination_components!(existing, ["." | remaining], missing_depth) do
    resolve_destination_components!(existing, remaining, missing_depth)
  end

  defp resolve_destination_components!(existing, [".." | remaining], missing_depth)
       when missing_depth > 0 do
    resolve_destination_components!(existing, remaining, missing_depth - 1)
  end

  defp resolve_destination_components!(existing, [".." | remaining], 0) do
    resolve_destination_components!(Path.join(existing, ".."), remaining, 0)
  end

  defp resolve_destination_components!(existing, [_component | remaining], missing_depth)
       when missing_depth > 0 do
    resolve_destination_components!(existing, remaining, missing_depth + 1)
  end

  defp resolve_destination_components!(existing, [component | remaining], 0) do
    candidate = Path.join(existing, component)

    case File.stat(candidate) do
      {:ok, %File.Stat{type: :directory}} ->
        resolve_destination_components!(candidate, remaining, 0)

      {:ok, _stat} when remaining == [] ->
        existing

      {:ok, _stat} ->
        raise ArgumentError, "generator path traverses a non-directory component"

      {:error, :enoent} ->
        resolve_destination_components!(existing, remaining, 1)

      {:error, reason} ->
        raise ArgumentError, "generator path cannot be resolved: #{inspect(reason)}"
    end
  end

  defp ancestor_identity?(directory, upstream_identity, seen) do
    current_identity = directory_identity!(directory)

    cond do
      current_identity == upstream_identity ->
        true

      MapSet.member?(seen, current_identity) ->
        raise ArgumentError, "generator directory ancestry contains a filesystem loop"

      true ->
        parent = Path.join(directory, "..")
        parent_identity = directory_identity!(parent)

        if parent_identity == current_identity do
          false
        else
          ancestor_identity?(parent, upstream_identity, MapSet.put(seen, current_identity))
        end
    end
  end

  defp verify_upstream_identity!(upstream, expected_identity) do
    unless directory_identity!(upstream) == expected_identity do
      raise ArgumentError, "upstream worktree identity changed during generation"
    end
  end

  defp filesystem_identity(stat) do
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp verify_source!(upstream, commit) do
    unless File.dir?(upstream) do
      raise ArgumentError, "upstream must be an existing Git worktree"
    end

    porcelain =
      case git(upstream, ["status", "--porcelain", "--untracked-files=all"]) do
        {"", 0} -> ""
        {_dirty, 0} -> raise ArgumentError, "upstream worktree must be clean"
        {_output, _status} -> raise ArgumentError, "unable to inspect upstream worktree"
      end

    case git(upstream, ["cat-file", "-e", "#{commit}^{commit}"]) do
      {"", 0} -> porcelain
      {_output, _status} -> raise ArgumentError, "pinned upstream commit is unavailable"
    end
  end

  defp verify_porcelain_unchanged!(upstream, initial_porcelain) do
    case git(upstream, ["status", "--porcelain", "--untracked-files=all"]) do
      {^initial_porcelain, 0} -> :ok
      {_output, 0} -> raise ArgumentError, "upstream worktree changed during generation"
      {_output, _status} -> raise ArgumentError, "unable to recheck upstream worktree"
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

    Enum.each(outputs, fn {path, _contents} -> validate_output_destination!(path, upstream) end)

    original_cwd = File.cwd!()
    staging = make_output_staging_directory!(upstream)
    published_key = {__MODULE__, :generator_published}
    Process.put(published_key, [])
    created_dirs_key = {__MODULE__, :generator_created_dirs}
    Process.put(created_dirs_key, %{})

    try do
      staged = stage_outputs!(staging, outputs)

      Enum.each(staged, fn staged_output ->
        published = publish_staged_output!(staged_output, upstream)
        Process.put(published_key, [published | Process.get(published_key)])
      end)

      :ok
    rescue
      error ->
        cleanup_published_outputs(Process.get(published_key, []), upstream)
        cleanup_created_output_directories(Process.get(created_dirs_key, %{}))
        reraise(error, __STACKTRACE__)
    after
      _ = :file.set_cwd(String.to_charlist(original_cwd))
      cleanup_output_staging!(staging)
      Process.delete(published_key)
      Process.delete(created_dirs_key)
    end
  end

  # Output generation is deliberately staged in a fresh private directory and
  # published only while the destination parent is the process cwd.  A cwd is
  # an inode binding: renaming/replacing the pathname after it is acquired
  # cannot redirect the relative AtomicReplace operation into another tree.
  defp make_output_staging_directory!(upstream) do
    staging = Path.join(System.tmp_dir!(), "swarm-code-schema-output-#{random_suffix()}")
    reject_upstream_destination!(staging, upstream)

    case File.mkdir(staging) do
      :ok ->
        with :ok <- File.chmod(staging, 0o700),
             {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(staging),
             true <- Bitwise.band(mode, 0o7777) == 0o700,
             _identity <- directory_identity!(staging) do
          staging
        else
          _other ->
            cleanup_output_staging!(staging)
            raise ArgumentError, "generator staging directory hardening failed"
        end

      {:error, :eexist} ->
        raise ArgumentError, "generator staging directory already exists"

      {:error, reason} ->
        raise File.Error, reason: reason, action: "mkdir", path: staging
    end
  end

  defp stage_outputs!(staging, outputs) do
    Enum.map(outputs, fn {path, contents} ->
      basename = "#{length(Path.split(path))}-#{Path.basename(path)}"
      staged_path = Path.join(staging, basename)
      bytes = IO.iodata_to_binary(contents)

      if byte_size(bytes) > 1_048_576,
        do: raise(ArgumentError, "generated output exceeds the bounded staging size")

      case File.open(staged_path, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          result =
            try do
              with :ok <- File.chmod(staged_path, 0o600),
                   :ok <- IO.binwrite(io, bytes),
                   :ok <- :file.sync(io) do
                :ok
              end
            after
              _ = File.close(io)
            end

          case result do
            :ok -> {path, bytes, staged_path}
            {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
          end

        {:error, reason} ->
          raise File.Error, reason: reason, action: "write", path: path
      end
    end)
  end

  defp publish_staged_output!({path, bytes, _staged_path}, upstream) do
    validate_output_destination!(path, upstream)
    parent = Path.dirname(Path.expand(path))
    basename = Path.basename(path)
    anchor = ensure_output_parent!(parent, upstream)
    upstream_identity = directory_identity!(upstream)
    previous = previous_output!(basename)

    try do
      case AtomicReplace.write(basename, bytes, mode: 0o644) do
        :ok ->
          identity = output_file_identity!(basename)
          ensure_output_anchor!(anchor, upstream)
          verify_upstream_identity!(upstream, upstream_identity)
          validate_output_destination!(path, upstream)
          %{cwd: anchor.cwd, identity: identity, basename: basename, previous: previous}

        {:error, reason} ->
          raise File.Error, reason: inspect(reason), action: "write", path: path
      end
    rescue
      error ->
        # If this invocation created a new leaf, remove only that exact inode;
        # an existing leaf is restored from its bounded preimage instead.
        cleanup_one_output(anchor, basename, previous, upstream)
        reraise(error, __STACKTRACE__)
    end
  end

  defp previous_output!(basename) do
    case File.lstat(basename) do
      {:error, :enoent} ->
        nil

      {:ok, %File.Stat{type: :regular, mode: mode} = stat} ->
        case File.read(basename) do
          {:ok, bytes} when byte_size(bytes) <= 1_048_576 ->
            %{identity: filesystem_identity(stat), bytes: bytes, mode: Bitwise.band(mode, 0o7777)}

          _other ->
            raise ArgumentError, "existing generator output is too large to preserve safely"
        end

      {:ok, _other} ->
        raise ArgumentError, "generator output destination is not a regular file"
    end
  end

  defp ensure_output_parent!(parent, upstream) do
    absolute = Path.expand(parent)
    validate_output_path_syntax!(absolute)

    case Path.split(absolute) do
      [root | components] ->
        case :file.set_cwd(String.to_charlist(root)) do
          :ok ->
            ensure_output_components!(components, upstream)

          {:error, reason} ->
            raise ArgumentError, "generator output parent cannot be opened: #{inspect(reason)}"
        end

      _other ->
        raise ArgumentError, "generator output parent path must be absolute"
    end
  end

  defp ensure_output_components!(components, upstream),
    do: ensure_output_components!(components, upstream, 0)

  defp ensure_output_components!([], upstream, _attempts) do
    anchor = %{cwd: File.cwd!(), identity: cwd_identity!()}
    ensure_output_anchor!(anchor, upstream)
    anchor
  end

  defp ensure_output_components!([component | rest], upstream, attempts)
       when attempts <= 3 do
    case File.lstat(component) do
      {:ok, %File.Stat{type: :directory}} ->
        set_output_child_cwd!(component, upstream)
        ensure_output_components!(rest, upstream, 0)

      {:ok, %File.Stat{type: :symlink}} ->
        # A symlink is admitted only after following it to a directory and
        # binding the resulting cwd identity.  If it is swapped later, the
        # already-held cwd remains on the original inode and the post-write
        # anchor check fails closed.
        case File.stat(component) do
          {:ok, %File.Stat{type: :directory}} ->
            set_output_child_cwd!(component, upstream)
            ensure_output_components!(rest, upstream, 0)

          _other ->
            raise ArgumentError, "generator output parent contains a non-directory symlink"
        end

      {:error, :enoent} ->
        case File.mkdir(component) do
          :ok ->
            # Enter the newly-created inode before hardening it; chmod on the
            # held cwd cannot follow a pathname substituted by another actor.
            set_output_child_cwd!(component, upstream)

            case File.chmod(".", 0o700) do
              :ok ->
                case File.lstat(".") do
                  {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}}
                  when Bitwise.band(mode, 0o7777) == 0o700 ->
                    current_uid = File.lstat!(".").uid

                    if uid != current_uid,
                      do: raise(ArgumentError, "generator output directory owner changed")

                    record_created_output_directory!()
                    ensure_output_components!(rest, upstream, 0)

                  _other ->
                    raise ArgumentError, "generator output directory identity changed"
                end

              {:error, reason} ->
                raise ArgumentError,
                      "generator output directory hardening failed: #{inspect(reason)}"
            end

          {:error, :eexist} ->
            ensure_output_components!([component | rest], upstream, attempts + 1)

          {:error, reason} ->
            raise ArgumentError, "generator output directory creation failed: #{inspect(reason)}"
        end

      {:ok, _other} ->
        raise ArgumentError, "generator output parent traverses a non-directory"

      {:error, reason} ->
        raise ArgumentError, "generator output parent cannot be inspected: #{inspect(reason)}"
    end
  end

  defp ensure_output_components!(_components, _upstream, _attempts),
    do: raise(ArgumentError, "generator output directory changed repeatedly")

  defp set_output_child_cwd!(component, upstream) do
    before =
      case File.lstat(component) do
        {:ok, %File.Stat{type: :symlink}} -> File.stat!(component)
        {:ok, stat} -> stat
        _other -> raise ArgumentError, "generator output parent disappeared"
      end

    case :file.set_cwd(String.to_charlist(component)) do
      :ok ->
        after_stat = File.lstat!(".")

        if filesystem_identity(before) != filesystem_identity(after_stat),
          do: raise(ArgumentError, "generator output parent identity changed")

        ensure_output_anchor!(%{cwd: File.cwd!(), identity: cwd_identity!()}, upstream)

      {:error, reason} ->
        raise ArgumentError, "generator output parent cannot be entered: #{inspect(reason)}"
    end
  end

  defp ensure_output_anchor!(%{cwd: cwd, identity: identity}, upstream) do
    current = cwd_identity!()

    if current != identity,
      do: raise(ArgumentError, "generator output parent identity changed")

    reject_upstream_destination!(cwd, upstream)
    :ok
  end

  defp cwd_identity! do
    case File.lstat(".") do
      {:ok, %File.Stat{type: :directory} = stat} -> filesystem_identity(stat)
      _other -> raise ArgumentError, "generator output cwd is not a directory"
    end
  end

  defp output_file_identity!(basename) do
    case File.lstat(basename) do
      {:ok, %File.Stat{type: :regular} = stat} -> filesystem_identity(stat)
      _other -> raise ArgumentError, "generator output identity could not be verified"
    end
  end

  defp validate_output_destination!(path, upstream) do
    validate_output_path_syntax!(path)
    reject_upstream_destination!(path, upstream)
    :ok
  end

  defp cleanup_published_outputs(outputs, upstream) do
    Enum.each(outputs, fn %{cwd: cwd, basename: basename, identity: identity, previous: previous} ->
      cleanup_one_output(%{cwd: cwd, identity: identity}, basename, previous, upstream)
    end)
  end

  defp cleanup_one_output(%{cwd: cwd, identity: expected_identity}, basename, previous, _upstream) do
    case :file.set_cwd(String.to_charlist(cwd)) do
      :ok ->
        current =
          case File.lstat(basename) do
            {:ok, %File.Stat{type: :regular} = stat} -> filesystem_identity(stat)
            _other -> nil
          end

        if is_nil(expected_identity) or current == expected_identity do
          case previous do
            nil ->
              _ = File.rm(basename)

            %{bytes: bytes, mode: mode} ->
              _ = AtomicReplace.write(basename, bytes, mode: mode)
          end
        end

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_output_staging!(staging) do
    case File.lstat(staging) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(staging) do
          {:ok, names} -> Enum.each(names, fn name -> _ = File.rm(Path.join(staging, name)) end)
          _other -> :ok
        end

        _ = File.rmdir(staging)

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp record_created_output_directory! do
    key = {__MODULE__, :generator_created_dirs}
    path = File.cwd!()
    identity = cwd_identity!()
    Process.put(key, Map.put(Process.get(key, %{}), path, identity))
  end

  defp cleanup_created_output_directories(directories) when is_map(directories) do
    directories
    |> Enum.sort_by(fn {path, _identity} -> -length(Path.split(path)) end)
    |> Enum.each(fn {path, expected} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          if filesystem_identity(stat) == expected and File.ls!(path) == [],
            do: File.rmdir(path)

        _other ->
          :ok
      end
    end)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_created_output_directories(_directories), do: :ok

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
