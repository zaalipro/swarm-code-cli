defmodule SwarmCode.Daemon.Backup.Gate do
  @moduledoc false

  import Bitwise

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Backup.{Artifact, Manifest}
  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord
  alias SwarmCode.Daemon.Files.AtomicReplace
  alias SwarmCode.Daemon.Platform.{DatabaseFingerprint, PhysicalPath, PrivateDirectory}
  alias SwarmCode.Daemon.Schema.{Gate.Decision, Probe, SqliteQuery}
  alias SwarmCode.Daemon.StartupError

  @private_file_mode 0o600
  @busy_timeout 5_000
  @chunk_bytes 1_024 * 1_024
  @maximum_tables 512
  @maximum_table_name_bytes 1_024
  @test_build Mix.env() == :test
  @allowed_options if(@test_build,
                     do: [:fault, :now, :test_hook, :uid],
                     else: [:fault, :now, :uid]
                   )

  @spec create(Path.t(), Path.t(), String.t(), GenServer.server(), Decision.t(), keyword()) ::
          {:ok, Artifact.t()} | {:error, StartupError.t()}
  def create(source_path, backup_dir, operation_id, lease, decision, opts \\ [])

  def create(source_path, backup_dir, operation_id, lease, decision, opts)
      when is_list(opts) do
    fault = validate_fault_option!(opts)
    test_hook = validate_test_hook_option!(opts)

    safe_create(fn ->
      with :ok <- validate_options(opts),
           {:ok, uid} <- trusted_uid(opts),
           :ok <- validate_arguments(source_path, backup_dir, operation_id, decision),
           {:ok, owner} <- assert_live_lease(lease),
           :ok <- PrivateDirectory.ensure(backup_dir, uid),
           {:ok, anchor} <- open_backup_directory(backup_dir, uid) do
        try do
          with :ok <-
                 invoke_test_hook(test_hook, :after_backup_directory_open, %{anchor: anchor}),
               :ok <- validate_backup_directory(anchor),
               {:ok, resolved_source} <- DatabaseFingerprint.resolve(source_path),
               :ok <- equal(resolved_source.fingerprint, owner.database_fingerprint),
               {:ok, source} <-
                 source_metadata(resolved_source.path, uid, resolved_source.fingerprint),
               {:ok, source_probe} <- Probe.inspect(resolved_source.path),
               :ok <- equal(source_probe, decision.probe) do
            paths = paths(anchor.path, operation_id)

            :global.trans(
              {{__MODULE__, anchor.identity, operation_id}, self()},
              fn ->
                with :ok <- validate_backup_directory(anchor),
                     :ok <- lease_still_held(lease, resolved_source.fingerprint),
                     :ok <-
                       source_unchanged(
                         resolved_source.path,
                         source,
                         resolved_source.fingerprint,
                         uid
                       ) do
                  case artifact_state(paths, uid) do
                    :absent ->
                      create_new(
                        resolved_source.path,
                        source,
                        resolved_source.fingerprint,
                        uid,
                        decision,
                        paths,
                        opts,
                        fault,
                        lease,
                        anchor,
                        test_hook
                      )

                    :committed ->
                      revalidate_existing(
                        resolved_source.path,
                        source,
                        resolved_source.fingerprint,
                        uid,
                        decision,
                        paths,
                        lease,
                        anchor,
                        test_hook
                      )

                    {:error, _reason} = error ->
                      error
                  end
                end
              end,
              [node()]
            )
          end
        after
          close_backup_directory(anchor)
        end
      end
    end)
  end

  def create(_source_path, _backup_dir, _operation_id, _lease, _decision, _opts),
    do: {:error, backup_failed()}

  defp safe_create(function) do
    try do
      case function.() do
        {:ok, %Artifact{}} = success -> success
        _other -> {:error, backup_failed()}
      end
    rescue
      _error -> {:error, backup_failed()}
    catch
      _kind, _reason -> {:error, backup_failed()}
    end
  end

  defp validate_fault_option!(opts) do
    case Keyword.fetch(opts, :fault) do
      :error ->
        nil

      {:ok, fault} ->
        validate_configured_fault!(fault)
    end
  end

  if @test_build do
    defp validate_configured_fault!(fault)
         when fault in [:after_snapshot, :after_manifest, :after_restore_copy, :before_publish],
         do: fault

    defp validate_configured_fault!(fault),
      do: raise(ArgumentError, "unsupported backup fault: #{inspect(fault)}")
  else
    defp validate_configured_fault!(_fault),
      do: raise(ArgumentError, "backup fault injection is unavailable in this build")
  end

  if @test_build do
    defp validate_test_hook_option!(opts) do
      case Keyword.get(opts, :test_hook) do
        nil -> nil
        hook when is_function(hook, 2) -> hook
        _other -> raise ArgumentError, "backup test hook must have arity two"
      end
    end

    defp invoke_test_hook(nil, _point, _context), do: :ok

    defp invoke_test_hook(hook, point, context) do
      case hook.(point, context) do
        :ok -> :ok
        {:error, _reason} = error -> error
        _other -> {:error, :invalid_test_hook_result}
      end
    end
  else
    defp validate_test_hook_option!(opts) do
      if Keyword.has_key?(opts, :test_hook),
        do: raise(ArgumentError, "backup test hooks are unavailable in this build"),
        else: nil
    end

    defp invoke_test_hook(_hook, _point, _context), do: :ok
  end

  defp validate_options(opts) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
         Enum.all?(keys, &(&1 in @allowed_options)) do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp trusted_uid(opts) do
    case Keyword.fetch(opts, :uid) do
      {:ok, uid} when is_integer(uid) and uid >= 0 -> {:ok, uid}
      _other -> {:error, :invalid_uid}
    end
  end

  defp validate_arguments(
         source_path,
         backup_dir,
         operation_id,
         %Decision{status: :migration_required, probe: %Probe{}, app_version: app_version}
       )
       when is_binary(source_path) and is_binary(backup_dir) and is_binary(operation_id) and
              is_binary(app_version) do
    with {:ok, ^operation_id} <- Ecto.UUID.cast(operation_id),
         {:ok, parsed_version} <- Version.parse(app_version),
         true <- to_string(parsed_version) == app_version do
      :ok
    else
      _other -> {:error, :invalid_arguments}
    end
  end

  defp validate_arguments(_source_path, _backup_dir, _operation_id, _decision),
    do: {:error, :invalid_arguments}

  defp assert_live_lease(lease) do
    with :ok <- CrossAppLease.assert_held(lease),
         %OwnerRecord{} = owner <- CrossAppLease.owner(lease) do
      {:ok, owner}
    else
      _other -> {:error, :lease_not_held}
    end
  end

  defp lease_still_held(lease, fingerprint) do
    with {:ok, owner} <- assert_live_lease(lease),
         :ok <- equal(owner.database_fingerprint, fingerprint) do
      :ok
    end
  end

  defp paths(backup_dir, operation_id) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    %{
      directory: backup_dir,
      final_database: Path.join(backup_dir, operation_id <> ".sqlite3"),
      final_manifest: Path.join(backup_dir, operation_id <> ".manifest.json"),
      staging_database: Path.join(backup_dir, ".#{operation_id}.#{suffix}.sqlite3"),
      staging_manifest: Path.join(backup_dir, ".#{operation_id}.#{suffix}.manifest.json"),
      restore: Path.join(backup_dir, ".#{operation_id}.#{suffix}.restore.sqlite3")
    }
  end

  defp artifact_state(paths, uid) do
    case {private_regular_state(paths.final_database, uid),
          private_regular_state(paths.final_manifest, uid)} do
      {:absent, :absent} -> :absent
      {{:ok, _database}, {:ok, _manifest}} -> :committed
      _other -> {:error, :ambiguous_artifact}
    end
  end

  defp private_regular_state(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = stat}
      when band(mode, 0o7777) == @private_file_mode ->
        {:ok, stat}

      {:error, :enoent} ->
        :absent

      _other ->
        {:error, :unsafe_artifact}
    end
  end

  defp open_backup_directory(path, uid) do
    with {:ok, %{path: resolved_path, stat: stat}} <- PhysicalPath.resolve_directory(path),
         :ok <- private_directory_stat(stat, uid),
         {:ok, handle} <- :file.open(String.to_charlist(resolved_path), [:read, :raw, :directory]) do
      anchor = %{
        path: resolved_path,
        uid: uid,
        identity: directory_identity(stat),
        handle: handle
      }

      case validate_backup_directory(anchor) do
        :ok ->
          {:ok, anchor}

        {:error, _reason} = error ->
          _ = :file.close(handle)
          error
      end
    end
  end

  defp close_backup_directory(anchor) do
    _ = :file.close(anchor.handle)
    :ok
  end

  defp validate_backup_directory(anchor) do
    with {:ok, path_stat} <- File.lstat(anchor.path),
         :ok <- private_directory_stat(path_stat, anchor.uid),
         :ok <- equal(directory_identity(path_stat), anchor.identity),
         {:ok, handle_identity} <- directory_handle_identity(anchor.handle),
         :ok <- equal(handle_identity, anchor.identity) do
      :ok
    else
      _other -> {:error, :backup_directory_changed}
    end
  end

  defp private_directory_stat(%File.Stat{type: :directory, uid: uid, mode: mode}, uid)
       when band(mode, 0o7777) == 0o700,
       do: :ok

  defp private_directory_stat(_stat, _uid), do: {:error, :unsafe_backup_directory}

  defp directory_handle_identity(handle) do
    case :file.read_file_info(handle) do
      {:ok,
       {:file_info, _size, :directory, _access, _atime, _mtime, _ctime, mode, _links, major,
        minor, inode, uid, _gid}}
      when band(mode, 0o7777) == 0o700 ->
        {:ok, {:directory, major, minor, inode, uid}}

      _other ->
        {:error, :unsafe_backup_directory_handle}
    end
  end

  defp directory_identity(stat),
    do: {:directory, stat.major_device, stat.minor_device, stat.inode, stat.uid}

  defp directory_operation(anchor, test_hook, point, function) do
    with :ok <- validate_backup_directory(anchor),
         :ok <- invoke_test_hook(test_hook, point, %{anchor: anchor}),
         :ok <- validate_backup_directory(anchor) do
      result = function.()
      validation = validate_backup_directory(anchor)

      case {result, validation} do
        {:ok, :ok} -> :ok
        {{:ok, _value} = success, :ok} -> success
        {{:error, _reason} = error, _validation} -> error
        {_result, {:error, _reason} = error} -> error
        {other, :ok} -> {:error, {:invalid_directory_operation_result, other}}
      end
    end
  end

  defp create_new(
         source_path,
         source,
         fingerprint,
         uid,
         decision,
         paths,
         opts,
         fault,
         lease,
         anchor,
         test_hook
       ) do
    ownership = begin_ownership()

    try do
      try do
        with {:ok, snapshot_identity} <-
               directory_operation(anchor, test_hook, :before_snapshot_create, fn ->
                 vacuum_snapshot(source_path, paths.staging_database, uid, ownership)
               end),
             :ok <- inject_fault(fault, :after_snapshot),
             {:ok, snapshot_verification} <-
               verify_database(paths.staging_database, decision.probe),
             {:ok, backup} <-
               private_file_entry(
                 paths.staging_database,
                 uid,
                 Path.basename(paths.final_database)
               ),
             {:ok, independent_restore} <-
               independent_restore(
                 paths.staging_database,
                 paths.restore,
                 uid,
                 snapshot_verification,
                 backup["sha256"],
                 fault,
                 ownership,
                 anchor,
                 test_hook
               ),
             {:ok, verified_at} <- verified_at(opts),
             manifest <-
               Manifest.build(
                 operation_id: Path.basename(paths.final_database, ".sqlite3"),
                 app_version: decision.app_version,
                 verified_at: verified_at,
                 source: source.manifest,
                 backup: backup,
                 verification: snapshot_verification,
                 independent_restore: independent_restore
               ),
             {:ok, manifest_iodata} <- Manifest.encode(manifest),
             {:ok, manifest_identity} <-
               directory_operation(anchor, test_hook, :before_manifest_create, fn ->
                 write_staging_manifest(
                   paths.staging_manifest,
                   manifest_iodata,
                   uid,
                   ownership,
                   anchor
                 )
               end),
             :ok <- inject_fault(fault, :after_manifest),
             :ok <-
               sync_file_anchored(
                 paths.staging_database,
                 anchor,
                 test_hook,
                 :before_staging_database_sync,
                 snapshot_identity
               ),
             :ok <-
               sync_file_anchored(
                 paths.staging_manifest,
                 anchor,
                 test_hook,
                 :before_staging_manifest_sync,
                 manifest_identity
               ),
             :ok <-
               sync_directory_anchored(anchor, test_hook, :before_staging_directory_sync),
             {:ok, backup_before_publish} <-
               private_file_entry(
                 paths.staging_database,
                 uid,
                 Path.basename(paths.final_database)
               ),
             :ok <- equal(backup_before_publish, backup),
             {:ok, manifest_before_publish, manifest_file_before_publish} <-
               read_stable_manifest(paths.staging_manifest, uid),
             :ok <- equal(manifest_before_publish, manifest),
             :ok <- equal(manifest_file_before_publish, manifest_identity),
             :ok <- lease_still_held(lease, fingerprint),
             :ok <- source_unchanged(source_path, source, fingerprint, uid),
             :ok <- inject_fault(fault, :before_publish),
             :ok <-
               publish(
                 paths,
                 uid,
                 snapshot_identity,
                 manifest_identity,
                 ownership,
                 anchor,
                 test_hook
               ),
             :ok <- validate_published(paths, uid),
             :ok <- validate_backup_directory(anchor) do
          {:ok,
           artifact(
             paths,
             manifest,
             source.manifest["main"]["sha256"],
             backup["sha256"]
           )}
        end
      rescue
        _error -> {:error, :backup_creation_failed}
      catch
        _kind, _reason -> {:error, :backup_creation_failed}
      end
    after
      finish_ownership(ownership, paths, uid, anchor, test_hook)
    end
  end

  defp revalidate_existing(
         source_path,
         source,
         fingerprint,
         uid,
         decision,
         paths,
         lease,
         anchor,
         test_hook
       ) do
    ownership = begin_ownership()

    try do
      with {:ok, manifest, manifest_file} <-
             read_stable_manifest(paths.final_manifest, uid),
           :ok <- validate_existing_manifest(manifest, source, decision, paths),
           {:ok, backup} <-
             private_file_entry(paths.final_database, uid, Path.basename(paths.final_database)),
           :ok <- equal(backup, manifest["backup"]),
           {:ok, verification} <- verify_database(paths.final_database, decision.probe),
           :ok <- verification_matches_manifest(verification, manifest),
           {:ok, independent} <-
             independent_restore(
               paths.final_database,
               paths.restore,
               uid,
               verification,
               backup["sha256"],
               nil,
               ownership,
               anchor,
               test_hook
             ),
           :ok <- equal(independent, manifest["independent_restore"]),
           {:ok, backup_after} <-
             private_file_entry(paths.final_database, uid, Path.basename(paths.final_database)),
           :ok <- equal(backup_after, backup),
           {:ok, manifest_after, manifest_file_after} <-
             read_stable_manifest(paths.final_manifest, uid),
           :ok <- equal(manifest_after, manifest),
           :ok <- equal(manifest_file_after, manifest_file),
           :ok <- lease_still_held(lease, fingerprint),
           :ok <- source_unchanged(source_path, source, fingerprint, uid),
           :ok <- durable_duplicate(paths, uid, anchor, test_hook),
           :ok <- validate_backup_directory(anchor) do
        {:ok,
         artifact(
           paths,
           manifest,
           source.manifest["main"]["sha256"],
           backup["sha256"]
         )}
      end
    after
      finish_ownership(ownership, paths, uid, anchor, test_hook)
    end
  end

  defp read_stable_manifest(path, uid) do
    with {:ok, before} <- private_file_identity(path, uid),
         {:ok, manifest} <- Manifest.read(path),
         {:ok, after_read} <- private_file_identity(path, uid),
         :ok <- equal(after_read, before) do
      {:ok, manifest, after_read}
    end
  end

  defp validate_existing_manifest(manifest, source, decision, paths) do
    with :ok <- equal(manifest["operation_id"], Path.basename(paths.final_database, ".sqlite3")),
         :ok <- equal(manifest["application"]["version"], decision.app_version),
         :ok <- equal(manifest["source"], source.manifest),
         :ok <- equal(manifest["backup"]["name"], Path.basename(paths.final_database)),
         :ok <- probe_matches_manifest(decision.probe, manifest),
         :ok <- independent_matches_manifest(manifest) do
      :ok
    end
  end

  defp probe_matches_manifest(probe, manifest) do
    expected = %{
      "application_id" => probe.application_id,
      "schema_sha256" => probe.schema_sha256,
      "sqlite_version" => probe.sqlite_version,
      "sqlite_source_id" => probe.sqlite_source_id,
      "migrations" => probe.migration_versions,
      "quick_check" => "ok",
      "foreign_key_violations" => []
    }

    if Enum.all?(expected, fn {key, value} -> manifest[key] == value end),
      do: :ok,
      else: {:error, :manifest_probe_mismatch}
  end

  defp verification_matches_manifest(verification, manifest) do
    if Enum.all?(verification, fn {key, value} -> manifest[key] == value end),
      do: :ok,
      else: {:error, :manifest_verification_mismatch}
  end

  defp independent_matches_manifest(manifest) do
    restore = manifest["independent_restore"]

    expected =
      manifest
      |> Map.take(verification_keys())
      |> Map.put("verified", true)
      |> Map.put("backup_sha256", manifest["backup"]["sha256"])

    equal(restore, expected)
  end

  defp artifact(paths, manifest, source_sha256, backup_sha256) do
    %Artifact{
      database: paths.final_database,
      manifest: paths.final_manifest,
      operation_id: manifest["operation_id"],
      source_sha256: source_sha256,
      backup_sha256: backup_sha256,
      verified_at: manifest["verified_at"]
    }
  end

  defp vacuum_snapshot(source_path, staging_database, uid, ownership) do
    with {:error, :enoent} <- File.lstat(staging_database),
         {:ok, conn} <- Sqlite3.open(source_path, mode: :readonly) do
      try do
        with :ok <- Sqlite3.set_busy_timeout(conn, @busy_timeout),
             :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON"),
             {:ok, statement} <- Sqlite3.prepare(conn, "VACUUM main INTO ?") do
          step_result =
            try do
              with :ok <- Sqlite3.bind(statement, [staging_database]) do
                Sqlite3.step(conn, statement)
              end
            after
              _ = Sqlite3.release(conn, statement)
            end

          case File.lstat(staging_database) do
            {:ok, _stat} ->
              with {:ok, identity} <- secure_new_file(staging_database, uid, ownership),
                   :done <- step_result do
                {:ok, identity}
              else
                _other -> {:error, :snapshot_failed}
              end

            {:error, :enoent} ->
              {:error, :snapshot_failed}

            _other ->
              {:error, :snapshot_failed}
          end
        end
      after
        _ = Sqlite3.close(conn)
      end
    else
      _other -> {:error, :snapshot_failed}
    end
  end

  defp secure_new_file(path, uid, ownership) do
    with {:ok, %File.Stat{type: :regular, uid: ^uid} = before} <- File.lstat(path),
         :ok <- register_owned(ownership, path, before),
         :ok <- File.chmod(path, @private_file_mode),
         {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = after_chmod} <-
           File.lstat(path),
         true <- same_filesystem_object?(before, after_chmod),
         true <- band(mode, 0o7777) == @private_file_mode do
      {:ok, file_identity(after_chmod)}
    else
      _other -> {:error, :unsafe_created_file}
    end
  end

  defp write_staging_manifest(path, contents, uid, ownership, anchor) do
    sync_directory = fn _directory ->
      with :ok <- validate_backup_directory(anchor),
           :ok <- :file.sync(anchor.handle),
           :ok <- validate_backup_directory(anchor) do
        :ok
      end
    end

    case AtomicReplace.write(path, contents,
           mode: @private_file_mode,
           replace: false,
           sync_directory: sync_directory
         ) do
      :ok ->
        own_existing_private_file(ownership, path, uid)

      {:error, {:post_publication, _reason}} = error ->
        _ = own_existing_private_file(ownership, path, uid)
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_database(path, expected_probe) do
    with {:ok, probe} <- Probe.inspect(path),
         :ok <- equal(probe, expected_probe),
         {:ok, checks} <- database_checks(path) do
      {:ok,
       %{
         "application_id" => probe.application_id,
         "schema_sha256" => probe.schema_sha256,
         "sqlite_version" => probe.sqlite_version,
         "sqlite_source_id" => probe.sqlite_source_id,
         "migrations" => probe.migration_versions,
         "row_counts" => checks.row_counts,
         "quick_check" => "ok",
         "foreign_key_violations" => [],
         "rowid_proofs" => checks.rowid_proofs
       }}
    end
  end

  defp database_checks(path) do
    with {:ok, conn} <- Sqlite3.open(path, mode: :readonly) do
      try do
        with :ok <- Sqlite3.set_busy_timeout(conn, @busy_timeout),
             :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=ON"),
             :ok <- Sqlite3.execute(conn, "PRAGMA query_only=ON"),
             [[1]] <- SqliteQuery.rows(conn, "PRAGMA foreign_keys", [], max_rows: 1),
             [[1]] <- SqliteQuery.rows(conn, "PRAGMA query_only", [], max_rows: 1),
             [["ok"]] <- SqliteQuery.rows(conn, "PRAGMA quick_check(1)", [], max_rows: 1),
             [] <-
               SqliteQuery.rows(conn, "SELECT 1 FROM pragma_foreign_key_check LIMIT 1", [],
                 max_rows: 1
               ),
             {:ok, tables} <- table_names(conn),
             {:ok, row_counts, rowid_proofs} <- counts_and_proofs(conn, tables) do
          {:ok, %{row_counts: row_counts, rowid_proofs: rowid_proofs}}
        else
          _other -> {:error, :database_verification_failed}
        end
      after
        _ = Sqlite3.close(conn)
      end
    end
  end

  defp table_names(conn) do
    rows =
      SqliteQuery.rows(
        conn,
        """
        SELECT CASE
                 WHEN length(CAST(name AS BLOB)) BETWEEN 1 AND ? THEN name
               END
        FROM sqlite_schema
        WHERE type = 'table' AND name NOT GLOB 'sqlite_*'
        ORDER BY name
        LIMIT 513
        """,
        [@maximum_table_name_bytes],
        max_rows: @maximum_tables
      )

    case Enum.reduce_while(rows, [], fn
           [name], names when is_binary(name) -> {:cont, [name | names]}
           _row, _names -> {:halt, :error}
         end) do
      :error -> {:error, :invalid_table_name}
      [] -> {:error, :no_tables}
      names -> {:ok, Enum.reverse(names)}
    end
  end

  defp counts_and_proofs(conn, tables) do
    Enum.reduce_while(tables, {:ok, %{}, %{}}, fn table, {:ok, counts, proofs} ->
      identifier = quote_identifier(table)

      with [[count]] when is_integer(count) and count >= 0 <-
             SqliteQuery.rows(conn, "SELECT count(*) FROM #{identifier}", [], max_rows: 1),
           {:ok, proof} <- rowid_proof(conn, table, identifier, count) do
        {:cont,
         {:ok, Map.put(counts, table, count),
          Map.put(proofs, table, Map.put(proof, "count", count))}}
      else
        _other -> {:halt, {:error, :table_verification_failed}}
      end
    end)
  end

  defp rowid_proof(_conn, _table, _identifier, 0) do
    {:ok, %{"first_rowid_sha256" => nil, "last_rowid_sha256" => nil}}
  end

  defp rowid_proof(conn, table, identifier, count) when count > 0 do
    with {:ok, rowid_alias} <- unshadowed_rowid_alias(conn, table),
         [[first]] when is_integer(first) <-
           SqliteQuery.rows(
             conn,
             "SELECT #{rowid_alias} FROM #{identifier} ORDER BY #{rowid_alias} LIMIT 1",
             [],
             max_rows: 1
           ),
         [[last]] when is_integer(last) <-
           SqliteQuery.rows(
             conn,
             "SELECT #{rowid_alias} FROM #{identifier} ORDER BY #{rowid_alias} DESC LIMIT 1",
             [],
             max_rows: 1
           ) do
      {:ok,
       %{
         "first_rowid_sha256" => rowid_sha256(first),
         "last_rowid_sha256" => rowid_sha256(last)
       }}
    else
      _other -> {:error, :rowid_proof_failed}
    end
  end

  defp unshadowed_rowid_alias(conn, table) do
    shadowed =
      SqliteQuery.rows(
        conn,
        """
        SELECT lower(name)
        FROM pragma_table_xinfo(?)
        WHERE lower(name) IN ('rowid', '_rowid_', 'oid')
        ORDER BY lower(name)
        LIMIT 4
        """,
        [table],
        max_rows: 3
      )
      |> Enum.reduce_while(MapSet.new(), fn
        [name], names when name in ["rowid", "_rowid_", "oid"] ->
          {:cont, MapSet.put(names, name)}

        _row, _names ->
          {:halt, :error}
      end)

    case shadowed do
      %MapSet{} = names ->
        case Enum.find(["rowid", "_rowid_", "oid"], &(not MapSet.member?(names, &1))) do
          nil -> {:error, :all_rowid_aliases_shadowed}
          alias_name -> {:ok, alias_name}
        end

      :error ->
        {:error, :invalid_table_metadata}
    end
  end

  defp quote_identifier(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")

  defp rowid_sha256(rowid) do
    :crypto.hash(:sha256, ["sqlite-rowid-v1\n", Integer.to_string(rowid)])
    |> Base.encode16(case: :lower)
  end

  defp independent_restore(
         source_database,
         restore_path,
         uid,
         expected_verification,
         expected_sha256,
         fault,
         ownership,
         anchor,
         test_hook
       ) do
    with {:ok, _identity} <-
           directory_operation(anchor, test_hook, :before_restore_create, fn ->
             copy_cold_database(source_database, restore_path, uid, ownership)
           end),
         :ok <- inject_fault(fault, :after_restore_copy),
         {:ok, restore_entry} <-
           private_file_entry(restore_path, uid, Path.basename(restore_path)),
         :ok <- equal(restore_entry["sha256"], expected_sha256),
         {:ok, restore_verification} <-
           verify_database(restore_path, verification_probe(expected_verification)),
         :ok <- equal(restore_verification, expected_verification),
         :ok <-
           directory_operation(anchor, test_hook, :before_restore_cleanup, fn ->
             remove_registered(ownership, restore_path)
           end) do
      {:ok,
       expected_verification
       |> Map.put("verified", true)
       |> Map.put("backup_sha256", expected_sha256)}
    end
  end

  defp verification_probe(verification) do
    %Probe{
      application_id: verification["application_id"],
      migration_versions: verification["migrations"],
      schema_sha256: verification["schema_sha256"],
      sqlite_version: verification["sqlite_version"],
      sqlite_source_id: verification["sqlite_source_id"],
      quick_check: [[verification["quick_check"]]],
      foreign_key_violations: verification["foreign_key_violations"]
    }
  end

  defp copy_cold_database(source, destination, uid, ownership) do
    with {:error, :enoent} <- File.lstat(destination),
         {:ok, input} <- File.open(source, [:read, :binary]) do
      try do
        case File.open(destination, [:write, :binary, :exclusive]) do
          {:ok, output} ->
            try do
              with {:ok, identity} <- secure_new_file(destination, uid, ownership),
                   :ok <- copy_chunks(input, output),
                   :ok <- :file.sync(output) do
                {:ok, identity}
              end
            after
              _ = File.close(output)
            end

          {:error, _reason} = error ->
            error
        end
      after
        _ = File.close(input)
      end
    else
      _other -> {:error, :restore_copy_failed}
    end
  end

  defp copy_chunks(input, output) do
    case IO.binread(input, @chunk_bytes) do
      :eof ->
        :ok

      bytes when is_binary(bytes) ->
        case IO.binwrite(output, bytes) do
          :ok -> copy_chunks(input, output)
          {:error, _reason} -> {:error, :restore_copy_failed}
        end

      {:error, _reason} ->
        {:error, :restore_copy_failed}
    end
  end

  defp source_metadata(source_path, uid, fingerprint) do
    with :ok <- DatabaseFingerprint.verify_resolved(source_path, fingerprint),
         {:ok, main} <- stable_file(source_path, uid, Path.basename(source_path)),
         {:ok, wal} <- optional_stable_file(source_path <> "-wal", uid),
         {:ok, shm} <- optional_stable_file(source_path <> "-shm", uid),
         :ok <- DatabaseFingerprint.verify_resolved(source_path, fingerprint) do
      {:ok,
       %{
         identities: %{
           "main" => main.identity,
           "wal" => optional_identity(wal),
           "shm" => optional_identity(shm)
         },
         manifest: %{
           "fingerprint" => fingerprint,
           "main" => main.entry,
           "wal" => optional_entry(wal),
           "shm" => optional_entry(shm)
         }
       }}
    end
  end

  defp source_unchanged(source_path, source, fingerprint, uid) do
    with {:ok, current} <- source_metadata(source_path, uid, fingerprint),
         :ok <- equal(current, source) do
      :ok
    end
  end

  defp optional_stable_file(path, uid) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, _stat} -> stable_file(path, uid, Path.basename(path))
      {:error, reason} -> {:error, {:source_sidecar_lstat_failed, reason}}
    end
  end

  defp stable_file(path, uid, published_name) do
    with {:ok, stat_before} <- private_source_stat(path, uid),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      result =
        try do
          with {:ok, handle_identity} <- handle_identity(io),
               :ok <- equal(handle_identity, file_identity(stat_before)),
               {:ok, sha256} <- hash_chunks(io, :crypto.hash_init(:sha256)),
               {:ok, stat_after} <- private_source_stat(path, uid),
               :ok <- equal(file_identity(stat_after), file_identity(stat_before)) do
            {:ok,
             %{
               identity: file_identity(stat_after),
               entry: %{
                 "name" => published_name,
                 "size" => stat_after.size,
                 "sha256" => sha256
               }
             }}
          end
        after
          _ = File.close(io)
        end

      result
    end
  end

  defp private_source_stat(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = stat}
      when band(mode, 0o7777) == @private_file_mode ->
        {:ok, stat}

      _other ->
        {:error, :unsafe_source_file}
    end
  end

  defp private_file_entry(path, uid, published_name) do
    with {:ok, file} <- stable_file(path, uid, published_name) do
      {:ok, file.entry}
    end
  end

  defp private_file_identity(path, uid) do
    with {:ok, stat} <- private_source_stat(path, uid) do
      {:ok, file_identity(stat)}
    end
  end

  defp begin_ownership do
    ownership = make_ref()
    Process.put(ownership, %{committed?: false, files: %{}})
    ownership
  end

  defp register_owned(ownership, path, %File.Stat{} = stat) do
    identity = object_identity(stat)
    state = Process.get(ownership)

    case Map.fetch(state.files, path) do
      :error ->
        Process.put(ownership, put_in(state, [:files, path], identity))
        :ok

      {:ok, ^identity} ->
        :ok

      {:ok, _other} ->
        {:error, :ownership_conflict}
    end
  end

  defp own_existing_private_file(ownership, path, uid) do
    with {:ok, stat} <- private_source_stat(path, uid),
         :ok <- register_owned(ownership, path, stat) do
      {:ok, file_identity(stat)}
    end
  end

  defp remove_registered(ownership, path) do
    state = Process.get(ownership)

    case Map.fetch(state.files, path) do
      {:ok, identity} ->
        with :ok <- remove_if_object_identity(path, identity) do
          Process.put(
            ownership,
            update_in(state.files, fn files -> Map.delete(files, path) end)
          )

          :ok
        end

      :error ->
        {:error, :file_not_owned}
    end
  end

  defp register_link(ownership, from, to, expected_file_identity, uid) do
    state = Process.get(ownership)

    with {:ok, expected_object_identity} <- Map.fetch(state.files, from),
         false <- Map.has_key?(state.files, to),
         {:ok, %File.Stat{type: :regular, uid: ^uid} = stat} <- File.lstat(to),
         :ok <- equal(object_identity(stat), expected_object_identity),
         :ok <- equal(file_identity(stat), expected_file_identity) do
      Process.put(
        ownership,
        %{state | files: Map.put(state.files, to, expected_object_identity)}
      )

      :ok
    else
      _other -> {:error, :ownership_conflict}
    end
  end

  defp publish_link(
         paths,
         ownership,
         from,
         to,
         expected_file_identity,
         uid,
         anchor,
         test_hook,
         before_point,
         after_absence_point
       ) do
    with :ok <- validate_backup_directory(anchor),
         :ok <- invoke_test_hook(test_hook, before_point, %{anchor: anchor, paths: paths}),
         :ok <- validate_backup_directory(anchor),
         :absent <- private_regular_state(to, uid),
         :ok <-
           invoke_test_hook(test_hook, after_absence_point, %{anchor: anchor, paths: paths}),
         :ok <- validate_backup_directory(anchor),
         :ok <- File.ln(from, to),
         :ok <- register_link(ownership, from, to, expected_file_identity, uid),
         :ok <- validate_backup_directory(anchor),
         :ok <- remove_registered(ownership, from),
         :ok <- verify_identity(to, expected_file_identity, uid),
         :ok <- validate_backup_directory(anchor) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp mark_committed(ownership) do
    state = Process.get(ownership)
    Process.put(ownership, %{state | committed?: true})
    :ok
  end

  defp finish_ownership(ownership, paths, _uid, anchor, test_hook) do
    try do
      _ = invoke_test_hook(test_hook, :before_cleanup, %{anchor: anchor, paths: paths})

      with :ok <- validate_backup_directory(anchor) do
        state = Process.get(ownership)
        commit_marker? = File.lstat(paths.final_manifest) != {:error, :enoent}
        preserve_final? = state.committed? or commit_marker?

        cleanup_files =
          Enum.reject(state.files, fn {path, _identity} ->
            preserve_final? and path in [paths.final_database, paths.final_manifest]
          end)

        Enum.each(cleanup_files, fn {path, identity} ->
          with :ok <- validate_backup_directory(anchor),
               :ok <- remove_if_object_identity(path, identity),
               :ok <- validate_backup_directory(anchor) do
            :ok
          else
            _other -> :ok
          end
        end)

        if cleanup_files != [] do
          _ = sync_directory_anchored(anchor, nil, :before_cleanup_directory_sync)
        end
      end
    catch
      _kind, _reason -> :ok
    after
      Process.delete(ownership)
    end

    :ok
  end

  defp sync_directory_anchored(anchor, test_hook, point) do
    directory_operation(anchor, test_hook, point, fn -> :file.sync(anchor.handle) end)
  end

  defp sync_file_anchored(path, anchor, test_hook, point, expected_identity) do
    directory_operation(anchor, test_hook, point, fn -> sync_file(path, expected_identity) end)
  end

  defp durable_duplicate(paths, uid, anchor, test_hook) do
    with {:ok, database_identity} <- private_file_identity(paths.final_database, uid),
         {:ok, manifest_identity} <- private_file_identity(paths.final_manifest, uid),
         :ok <-
           sync_file_anchored(
             paths.final_database,
             anchor,
             test_hook,
             :before_duplicate_database_sync,
             database_identity
           ),
         :ok <- verify_identity(paths.final_database, database_identity, uid),
         :ok <-
           sync_file_anchored(
             paths.final_manifest,
             anchor,
             test_hook,
             :before_duplicate_manifest_sync,
             manifest_identity
           ),
         :ok <- verify_identity(paths.final_manifest, manifest_identity, uid),
         :ok <-
           sync_directory_anchored(anchor, test_hook, :before_duplicate_directory_sync),
         :ok <- validate_backup_directory(anchor) do
      :ok
    end
  end

  defp remove_if_object_identity(path, expected_identity) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if object_identity(stat) == expected_identity do
          case File.rm(path) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :file_identity_changed}
        end

      {:error, :enoent} ->
        :ok

      _other ->
        {:error, :file_identity_changed}
    end
  end

  defp handle_identity(io) do
    case :file.read_file_info(io) do
      {:ok,
       {:file_info, size, :regular, _access, _atime, _mtime, _ctime, mode, _links, major, minor,
        inode, uid, _gid}} ->
        {:ok, {:regular, major, minor, inode, uid, mode, size}}

      _other ->
        {:error, :unsafe_open_file}
    end
  end

  defp hash_chunks(io, context) do
    case IO.binread(io, @chunk_bytes) do
      :eof ->
        digest =
          context
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, digest}

      bytes when is_binary(bytes) ->
        hash_chunks(io, :crypto.hash_update(context, bytes))

      {:error, _reason} ->
        {:error, :file_hash_failed}
    end
  end

  defp optional_entry(nil), do: nil
  defp optional_entry(file), do: file.entry
  defp optional_identity(nil), do: nil
  defp optional_identity(file), do: file.identity

  defp verified_at(opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    if is_function(now, 0) do
      case now.() do
        %DateTime{utc_offset: 0, std_offset: 0} = datetime ->
          encoded = DateTime.to_iso8601(datetime)

          case DateTime.from_iso8601(encoded) do
            {:ok, ^datetime, 0} -> {:ok, encoded}
            {:ok, _parsed, 0} -> {:ok, encoded}
            _other -> {:error, :invalid_timestamp}
          end

        _other ->
          {:error, :invalid_timestamp}
      end
    else
      {:error, :invalid_clock}
    end
  end

  defp publish(
         paths,
         uid,
         database_identity,
         manifest_identity,
         ownership,
         anchor,
         test_hook
       ) do
    with :ok <- verify_identity(paths.staging_database, database_identity, uid),
         :ok <- verify_identity(paths.staging_manifest, manifest_identity, uid),
         :ok <-
           publish_link(
             paths,
             ownership,
             paths.staging_database,
             paths.final_database,
             database_identity,
             uid,
             anchor,
             test_hook,
             :before_database_publication,
             :after_database_absence_check
           ),
         :ok <-
           publish_link(
             paths,
             ownership,
             paths.staging_manifest,
             paths.final_manifest,
             manifest_identity,
             uid,
             anchor,
             test_hook,
             :before_manifest_publication,
             :after_manifest_absence_check
           ),
         :ok <- mark_committed(ownership),
         :ok <- sync_directory_anchored(anchor, test_hook, :before_final_directory_sync) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp validate_published(paths, uid) do
    with {:ok, _stat} <- private_regular_state(paths.final_database, uid),
         {:ok, _stat} <- private_regular_state(paths.final_manifest, uid),
         {:error, :enoent} <- File.lstat(paths.staging_database),
         {:error, :enoent} <- File.lstat(paths.staging_manifest),
         {:error, :enoent} <- File.lstat(paths.restore) do
      :ok
    else
      _other -> {:error, :published_artifact_invalid}
    end
  end

  defp verify_identity(path, expected, uid) do
    case private_file_identity(path, uid) do
      {:ok, ^expected} -> :ok
      _other -> {:error, :file_identity_changed}
    end
  end

  defp sync_file(path, expected_identity) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, actual_identity} <- handle_identity(io),
               :ok <- optional_identity_match(actual_identity, expected_identity) do
            :file.sync(io)
          end
        after
          _ = :file.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp optional_identity_match(_actual, nil), do: :ok
  defp optional_identity_match(identity, identity), do: :ok
  defp optional_identity_match(_actual, _expected), do: {:error, :file_identity_changed}

  defp inject_fault(point, point), do: throw({:injected_backup_fault, point})
  defp inject_fault(_configured, _point), do: :ok

  defp file_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.mode, stat.size}
  end

  defp object_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid}
  end

  defp same_filesystem_object?(left, right) do
    {left.type, left.major_device, left.minor_device, left.inode, left.uid} ==
      {right.type, right.major_device, right.minor_device, right.inode, right.uid}
  end

  defp verification_keys do
    ~w(
      application_id foreign_key_violations migrations quick_check row_counts rowid_proofs
      schema_sha256 sqlite_source_id sqlite_version
    )
  end

  defp equal(value, value), do: :ok
  defp equal(_actual, _expected), do: {:error, :mismatch}

  defp backup_failed do
    StartupError.new(
      :backup_failed,
      false,
      "A verified migration backup could not be created.",
      "Leave the canonical database unchanged and inspect only independently verified artifacts."
    )
  end
end
