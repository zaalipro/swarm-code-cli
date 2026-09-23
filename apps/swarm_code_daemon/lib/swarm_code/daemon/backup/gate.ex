defmodule SwarmCode.Daemon.Backup.Gate do
  @moduledoc false

  import Bitwise

  require Logger

  alias Exqlite.Sqlite3
  alias SwarmCode.Daemon.Backup.{Artifact, Manifest}
  alias SwarmCode.Daemon.CrossAppLease
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord

  alias SwarmCode.Daemon.Platform.{
    DatabaseFingerprint,
    DirectoryHelper,
    DirectoryProtocol,
    PhysicalPath,
    PrivateDirectory,
    SourceSnapshot
  }

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
           :ok <- ensure_backup_directory(backup_dir, uid),
           {:ok, anchor} <- open_backup_directory(backup_dir, uid) do
        try do
          with :ok <-
                 invoke_test_hook(test_hook, :after_backup_directory_open, %{anchor: anchor}),
               :ok <- validate_backup_directory(anchor),
               {:ok, resolved_source} <- DatabaseFingerprint.resolve(source_path),
               :ok <- equal(resolved_source.fingerprint, owner.database_fingerprint),
               {:ok, source} <-
                 source_metadata(resolved_source.path, uid, resolved_source.fingerprint) do
            paths = paths(anchor.path, operation_id)

            :global.trans(
              {{__MODULE__, anchor.identity, operation_id}, self()},
              fn ->
                with :ok <- validate_backup_directory(anchor),
                     :ok <- lease_still_held(lease, resolved_source.fingerprint),
                     {:ok, source_probe} <- Probe.inspect(resolved_source.path),
                     :ok <- equal(source_probe, decision.probe),
                     :ok <-
                       source_unchanged(
                         resolved_source.path,
                         source,
                         resolved_source.fingerprint,
                         uid
                       ) do
                  case artifact_state(paths, uid, anchor) do
                    :absent ->
                      with_pinned_source(
                        resolved_source,
                        source,
                        decision.probe,
                        uid,
                        operation_id,
                        anchor,
                        test_hook,
                        fn ->
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
                        end
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
                        test_hook,
                        fault
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

  @doc false
  def broker_verify_database(path, expected_probe), do: verify_database(path, expected_probe)

  @doc false
  def broker_file_entry(path, uid, published_name),
    do: private_file_entry(path, uid, published_name)

  defp safe_create(function) do
    try do
      case function.() do
        {:ok, %Artifact{}} = success ->
          success

        {:error, :cleanup_pending} ->
          {:error, cleanup_pending_error()}

        {:error, {:helper_cleanup, _reason}} ->
          {:error, cleanup_pending_error()}

        {:error, {:parent_cleanup, _reason}} ->
          {:error, cleanup_pending_error()}

        {:error, {:finish_ownership, _reason}} ->
          {:error, cleanup_pending_error()}

        _other ->
          {:error, backup_failed()}
      end
    rescue
      _error ->
        {:error, backup_failed()}
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
         when fault in [
                :after_snapshot,
                :after_manifest,
                :after_restore_copy,
                :before_publish,
                :finish_ownership
              ],
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
         %Decision{
           status: :ready,
           pending: [],
           applied: applied,
           probe: %Probe{migration_versions: applied}
         } = decision
       ) do
    validate_backup_arguments(source_path, backup_dir, operation_id, decision)
  end

  defp validate_arguments(
         source_path,
         backup_dir,
         operation_id,
         %Decision{status: :migration_required, probe: %Probe{}} = decision
       ) do
    validate_backup_arguments(source_path, backup_dir, operation_id, decision)
  end

  defp validate_arguments(_source_path, _backup_dir, _operation_id, _decision),
    do: {:error, :invalid_arguments}

  defp validate_backup_arguments(source_path, backup_dir, operation_id, %Decision{
         app_version: app_version
       })
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

  defp validate_backup_arguments(_source_path, _backup_dir, _operation_id, _decision),
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

  defp artifact_state(paths, uid, anchor) do
    with {:ok, current_path} <- validate_helper_directory(anchor) do
      result =
        case {DirectoryHelper.entry_state(
                anchor.helper,
                Path.basename(paths.final_database),
                uid
              ),
              DirectoryHelper.entry_state(anchor.helper, Path.basename(paths.final_manifest), uid)} do
          {:absent, :absent} -> :absent
          {{:ok, _database}, {:ok, _manifest}} -> :committed
          _other -> {:error, :ambiguous_artifact}
        end

      case validate_helper_directory(anchor) do
        {:ok, ^current_path} -> result
        _other -> {:error, :backup_directory_changed}
      end
    end
  end

  defp ensure_backup_directory(path, uid) do
    case PhysicalPath.resolve_directory(path) do
      {:ok, %{path: resolved}} ->
        PrivateDirectory.ensure(resolved, uid)

      {:error, _reason} ->
        parent = Path.dirname(Path.expand(path))

        with {:ok, %{path: resolved_parent}} <- PhysicalPath.resolve_directory(parent),
             leaf = Path.join(resolved_parent, Path.basename(path)),
             :ok <- PrivateDirectory.ensure(leaf, uid) do
          :ok
        else
          _other -> {:error, :unsafe_backup_directory}
        end
    end
  rescue
    _error -> {:error, :unsafe_backup_directory}
  catch
    _kind, _reason -> {:error, :unsafe_backup_directory}
  end

  defp open_backup_directory(path, uid, opts \\ []) do
    with {:ok, %{path: resolved_path, stat: stat}} <- PhysicalPath.resolve_directory(path),
         :ok <- private_directory_stat(stat, uid) do
      case :file.open(String.to_charlist(resolved_path), [:read, :raw, :directory]) do
        {:ok, handle} ->
          case DirectoryHelper.start(resolved_path, opts) do
            {:ok, helper} ->
              anchor = %{
                path: resolved_path,
                uid: uid,
                identity: directory_identity(stat),
                handle: handle,
                helper: helper
              }

              case validate_backup_directory(anchor) do
                :ok ->
                  {:ok, anchor}

                {:error, _reason} = error ->
                  DirectoryHelper.stop(helper)
                  _ = :file.close(handle)
                  error
              end

            {:error, _reason} = error ->
              _ = :file.close(handle)
              error
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp close_backup_directory(anchor) do
    _ = stop_helper_once(anchor.helper)
    Process.delete({__MODULE__, :stopped_helper, anchor.helper.owner})
    _ = :file.close(anchor.handle)
    :ok
  end

  # A successful/failed operation may already have stopped the broker while
  # performing its ownership handoff.  Keep the stop operation idempotent in
  # this caller so the outer directory close never waits on a retained reaper
  # a second time.
  defp stop_helper_once(helper) do
    key = {__MODULE__, :stopped_helper, helper.owner}

    case Process.get(key) do
      nil ->
        result =
          try do
            DirectoryHelper.stop(helper)
          rescue
            _error -> {:error, :directory_helper_cleanup_pending}
          catch
            _kind, _reason -> {:error, :directory_helper_cleanup_pending}
          end

        Process.put(key, result)
        result

      result ->
        result
    end
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

  defp validate_helper_directory(anchor) do
    with {:ok, current_path} <- DirectoryHelper.pwd(anchor.helper),
         :ok <- equal(current_path, anchor.path),
         {:ok, path_stat} <- File.lstat(current_path),
         :ok <- private_directory_stat(path_stat, anchor.uid),
         :ok <- equal(directory_identity(path_stat), anchor.identity),
         {:ok, handle_identity} <- directory_handle_identity(anchor.handle),
         :ok <- equal(handle_identity, anchor.identity) do
      {:ok, current_path}
    else
      _other -> {:error, :backup_directory_helper_changed}
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

  defp directory_handle_identity_relaxed(handle) do
    case :file.read_file_info(handle) do
      {:ok,
       {:file_info, _size, :directory, _access, _atime, _mtime, _ctime, _mode, _links, major,
        minor, inode, uid, _gid}} ->
        {:ok, {:directory, major, minor, inode, uid}}

      _other ->
        {:error, :unsafe_backup_directory_handle}
    end
  end

  defp directory_identity(stat),
    do: {:directory, stat.major_device, stat.minor_device, stat.inode, stat.uid}

  defp directory_operation(anchor, test_hook, point, function) do
    with {:ok, before_path} <- validate_helper_directory(anchor),
         :ok <- invoke_test_hook(test_hook, point, %{anchor: anchor}),
         {:ok, after_hook_path} <- validate_helper_directory(anchor),
         :ok <- equal(after_hook_path, before_path) do
      result = function.()
      validation = validate_helper_directory(anchor)

      case {result, validation} do
        {:ok, {:ok, ^before_path}} -> :ok
        {{:ok, _value} = success, {:ok, ^before_path}} -> success
        {{:error, _reason} = error, _validation} -> error
        {_result, {:error, _reason} = error} -> error
        {other, {:ok, ^before_path}} -> {:error, {:invalid_directory_operation_result, other}}
        {_result, {:ok, _changed_path}} -> {:error, :backup_directory_moved}
      end
    end
  end

  defp broker_verify_database(anchor, path, expected_probe) do
    DirectoryHelper.verify_database(anchor.helper, Path.basename(path), expected_probe)
  end

  defp broker_file_entry(anchor, path, uid, published_name) do
    DirectoryHelper.file_entry(anchor.helper, Path.basename(path), uid, published_name)
  end

  defp broker_file_identity(anchor, path, uid) do
    DirectoryHelper.private_identity(anchor.helper, Path.basename(path), uid)
  end

  defp broker_read_manifest(anchor, path, uid) do
    with {:ok, before} <- broker_file_identity(anchor, path, uid),
         {:ok, contents} <-
           DirectoryHelper.read_private(
             anchor.helper,
             Path.basename(path),
             uid,
             DirectoryProtocol.maximum_bytes() - 4_096
           ),
         {:ok, manifest} <- Manifest.decode(contents),
         {:ok, ^before} <- broker_file_identity(anchor, path, uid) do
      {:ok, manifest, before}
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

    operation_result =
      try do
        with {:ok, snapshot_identity} <-
               directory_operation(anchor, test_hook, :before_snapshot_create, fn ->
                 vacuum_snapshot(
                   paths.staging_database,
                   uid,
                   ownership,
                   anchor
                 )
               end),
             :ok <- inject_fault(fault, :after_snapshot),
             :ok <-
               invoke_test_hook(test_hook, :after_snapshot, %{
                 anchor: anchor,
                 path: paths.staging_database,
                 identity: snapshot_identity
               }),
             {:ok, snapshot_verification} <-
               broker_verify_database(anchor, paths.staging_database, decision.probe),
             {:ok, backup} <-
               broker_file_entry(
                 anchor,
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
                   anchor,
                   test_hook
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
               broker_file_entry(
                 anchor,
                 paths.staging_database,
                 uid,
                 Path.basename(paths.final_database)
               ),
             :ok <- equal(backup_before_publish, backup),
             {:ok, manifest_before_publish, manifest_file_before_publish} <-
               broker_read_manifest(anchor, paths.staging_manifest, uid),
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
             :ok <- validate_published(paths, uid, anchor),
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

    cleanup_result =
      finish_ownership(ownership, paths, uid, anchor, test_hook, fault)

    settle_cleanup(cleanup_result, operation_result, :create_new)
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
         test_hook,
         fault
       ) do
    ownership = begin_ownership()

    operation_result =
      try do
        with {:ok, manifest, manifest_file} <-
               broker_read_manifest(anchor, paths.final_manifest, uid),
             :ok <- validate_existing_manifest(manifest, source, decision, paths),
             {:ok, backup} <-
               broker_file_entry(
                 anchor,
                 paths.final_database,
                 uid,
                 Path.basename(paths.final_database)
               ),
             :ok <- equal(backup, manifest["backup"]),
             {:ok, verification} <-
               broker_verify_database(anchor, paths.final_database, decision.probe),
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
               broker_file_entry(
                 anchor,
                 paths.final_database,
                 uid,
                 Path.basename(paths.final_database)
               ),
             :ok <- equal(backup_after, backup),
             {:ok, manifest_after, manifest_file_after} <-
               broker_read_manifest(anchor, paths.final_manifest, uid),
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
      rescue
        _error -> {:error, :backup_creation_failed}
      catch
        _kind, _reason -> {:error, :backup_creation_failed}
      end

    cleanup_result =
      finish_ownership(ownership, paths, uid, anchor, test_hook, fault)

    settle_cleanup(cleanup_result, operation_result, :revalidate_existing)
  end

  # When the artifact was verified complete but its ownership cleanup failed,
  # the artifact still stands — the discarded cleanup failure is surfaced as a
  # warning carrying the reason, never swallowed silently.
  defp settle_cleanup(:ok, operation_result, _block), do: operation_result

  defp settle_cleanup({:error, reason}, {:ok, artifact}, block) do
    Logger.warning(
      "backup #{block}: verified artifact kept despite cleanup failure (#{inspect(reason)})"
    )

    {:ok, artifact}
  end

  defp settle_cleanup({:error, _reason}, _operation_result, _block),
    do: {:error, :cleanup_pending}

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

  defp vacuum_snapshot(staging_database, uid, ownership, anchor) do
    with {:ok, identity} <-
           DirectoryHelper.vacuum(anchor.helper, Path.basename(staging_database), uid),
         :ok <-
           register_owned_identity(
             ownership,
             staging_database,
             object_identity_from_file_identity(identity)
           ) do
      {:ok, identity}
    else
      _other -> {:error, :snapshot_failed}
    end
  end

  defp write_staging_manifest(
         owned_path,
         contents,
         uid,
         ownership,
         anchor,
         test_hook
       ) do
    contents = IO.iodata_to_binary(contents)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp_basename = ".#{Path.basename(owned_path)}.tmp.#{nonce}"
    temp_path = Path.join(anchor.path, temp_basename)

    with {:ok, identity} <-
           DirectoryHelper.write_private(anchor.helper, temp_basename, contents, uid),
         object_identity = object_identity_from_file_identity(identity),
         :ok <- register_owned_identity(ownership, temp_path, object_identity),
         :ok <-
           invoke_test_hook(test_hook, :after_manifest_temp_sync, %{
             anchor: anchor,
             path: owned_path
           }),
         {:ok, linked_identity} <-
           DirectoryHelper.link_owned(
             anchor.helper,
             temp_basename,
             Path.basename(owned_path),
             uid
           ),
         :ok <-
           register_owned_identity(
             ownership,
             owned_path,
             object_identity_from_file_identity(linked_identity)
           ),
         :ok <- register_link(ownership, temp_path, owned_path, identity, uid, anchor),
         :ok <- remove_registered(ownership, temp_path, anchor),
         :ok <- DirectoryHelper.sync_directory(anchor.helper) do
      {:ok, identity}
    else
      _other -> {:error, :manifest_write_failed}
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

  # pass70 B (A's request): the FTS5 index of pass 69 owns shadow tables, two
  # of them `WITHOUT ROWID` (`messages_fts_idx`, `messages_fts_config`), which
  # have no rowid to prove. SQLite maintains them from the virtual table, whose
  # own count and rowid proof are kept, and `quick_check` covers their b-trees.
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
          AND name NOT IN (
            SELECT name FROM pragma_table_list WHERE schema = 'main' AND type = 'shadow'
          )
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
             copy_cold_database(
               source_database,
               restore_path,
               uid,
               ownership,
               anchor,
               test_hook
             )
           end),
         :ok <- inject_fault(fault, :after_restore_copy),
         {:ok, restore_entry} <-
           broker_file_entry(anchor, restore_path, uid, Path.basename(restore_path)),
         :ok <- equal(restore_entry["sha256"], expected_sha256),
         {:ok, restore_verification} <-
           broker_verify_database(anchor, restore_path, verification_probe(expected_verification)),
         :ok <- equal(restore_verification, expected_verification),
         :ok <-
           directory_operation(anchor, test_hook, :before_restore_cleanup, fn ->
             remove_registered(ownership, restore_path, anchor)
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

  defp copy_cold_database(
         source,
         destination,
         uid,
         ownership,
         anchor,
         test_hook
       ) do
    with {:ok, opened_identity} <-
           DirectoryHelper.prepare_copy(
             anchor.helper,
             Path.basename(source),
             Path.basename(destination),
             uid
           ),
         :ok <-
           register_owned_identity(
             ownership,
             destination,
             object_identity_from_file_identity(opened_identity)
           ) do
      result =
        with :ok <-
               invoke_test_hook(test_hook, :after_restore_files_open, %{
                 anchor: anchor,
                 path: destination
               }),
             {:ok, identity} <- DirectoryHelper.finish_copy(anchor.helper) do
          {:ok, identity}
        else
          _other -> {:error, :restore_copy_failed}
        end

      if match?({:error, _reason}, result), do: DirectoryHelper.cancel_copy(anchor.helper)
      result
    else
      _other -> {:error, :restore_copy_failed}
    end
  end

  defp with_pinned_source(
         resolved_source,
         expected_source,
         expected_probe,
         uid,
         operation_id,
         anchor,
         test_hook,
         function
       ) do
    with {:ok, expected} <- snapshot_expected(resolved_source.path, expected_source, uid) do
      with_backup_snapshot(resolved_source.path, uid, expected, fn snapshot ->
        with {:ok, snapshot_source} <-
               source_metadata(snapshot, uid, snapshot_fingerprint(snapshot)) do
          with_snapshot_pins(
            snapshot,
            snapshot_source,
            expected_probe,
            uid,
            operation_id,
            anchor,
            test_hook,
            function
          )
        end
      end)
    end
  end

  defp snapshot_fingerprint(path) do
    {:ok, fingerprint} = DatabaseFingerprint.for_path(path)
    fingerprint
  end

  defp snapshot_expected(path, source, uid) do
    with {:ok, parent} <- File.lstat(Path.dirname(path)),
         {:ok, main} <- File.lstat(path),
         true <- file_identity(main) == source.identities["main"],
         {:ok, wal} <- snapshot_sidecar(path <> "-wal", source.identities["wal"]),
         {:ok, shm} <- snapshot_sidecar(path <> "-shm", source.identities["shm"]),
         true <- parent.type == :directory and parent.uid == uid do
      {:ok, %{main: main, wal: wal, shm: shm, parent: parent}}
    else
      _ -> {:error, :source_pin_failed}
    end
  end

  defp snapshot_sidecar(path, nil) do
    if File.lstat(path) == {:error, :enoent}, do: {:ok, nil}, else: {:error, :source_pin_failed}
  end

  defp snapshot_sidecar(path, expected) do
    with {:ok, stat} <- File.lstat(path), true <- file_identity(stat) == expected do
      {:ok, stat}
    else
      _ -> {:error, :source_pin_failed}
    end
  end

  # Keep the caller's ownership dictionaries on this process. The snapshot callback
  # only lends its path. The broker creates its own full copies before SQLite open.
  defp with_backup_snapshot(path, uid, expected, function) do
    requester = self()
    ref = make_ref()

    {runner, monitor} =
      spawn_monitor(fn ->
        runner = self()
        spawn(fn -> watch_snapshot_requester(requester, runner) end)

        result =
          SourceSnapshot.with_snapshot(
            path,
            uid,
            expected,
            fn snapshot ->
              send(requester, {ref, :snapshot_ready, self(), snapshot})

              receive do
                {^ref, :release_snapshot} -> :ok
              end
            end,
            timeout: 300_000,
            callback_timeout: 300_000
          )

        send(requester, {ref, :snapshot_result, self(), result})
      end)

    receive do
      {^ref, :snapshot_ready, callback, snapshot} ->
        operation =
          try do
            function.(snapshot)
          rescue
            _ -> {:error, :source_pin_failed}
          catch
            _, _ -> {:error, :source_pin_failed}
          end

        send(callback, {ref, :release_snapshot})

        case await_backup_snapshot(runner, monitor, ref) do
          :ok -> operation
          _ -> {:error, :cleanup_pending}
        end

      {^ref, :snapshot_result, ^runner, result} ->
        await_snapshot_runner_down(runner, monitor)

        if result == {:error, :snapshot_cleanup_pending},
          do: {:error, :cleanup_pending},
          else: {:error, :source_pin_failed}

      {:DOWN, ^monitor, :process, ^runner, _} ->
        {:error, :cleanup_pending}
    end
  end

  defp watch_snapshot_requester(requester, runner) do
    requester_monitor = Process.monitor(requester)
    runner_monitor = Process.monitor(runner)

    receive do
      {:DOWN, ^runner_monitor, :process, ^runner, _} -> :ok
      {:DOWN, ^requester_monitor, :process, ^requester, _} -> Process.exit(runner, :kill)
    end
  end

  defp await_backup_snapshot(runner, monitor, ref) do
    receive do
      {^ref, :snapshot_result, ^runner, result} ->
        await_snapshot_runner_down(runner, monitor)
        result

      {:DOWN, ^monitor, :process, ^runner, _} ->
        {:error, :snapshot_cleanup_pending}
    end
  end

  defp await_snapshot_runner_down(runner, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^runner, _} -> :ok
    end
  end

  defp with_snapshot_pins(
         snapshot,
         expected_source,
         expected_probe,
         uid,
         operation_id,
         anchor,
         test_hook,
         function
       ) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    basename = ".#{operation_id}.#{suffix}.source-pin.sqlite3"

    pins = %{
      main: Path.join(anchor.path, basename),
      wal: Path.join(anchor.path, basename <> "-wal"),
      shm: Path.join(anchor.path, basename <> "-shm")
    }

    specs = [
      {:wal, snapshot <> "-wal", Path.basename(pins.wal), expected_source.identities["wal"]},
      {:shm, snapshot <> "-shm", Path.basename(pins.shm), expected_source.identities["shm"]},
      {:main, snapshot, Path.basename(pins.main), expected_source.identities["main"]}
    ]

    ownership = begin_ownership()

    operation_result =
      try do
        with {:ok, identities} <-
               DirectoryHelper.open_source(anchor.helper, specs, expected_probe, uid),
             :ok <- register_source_pin_identities(ownership, pins, identities, uid),
             :ok <-
               invoke_test_hook(test_hook, :after_source_main_pin_link, %{
                 anchor: anchor,
                 path: pins.main
               }),
             :ok <-
               invoke_test_hook(test_hook, :after_source_wal_pin_link, %{
                 anchor: anchor,
                 path: pins.wal
               }),
             :ok <-
               invoke_test_hook(test_hook, :after_source_shm_pin_link, %{
                 anchor: anchor,
                 path: pins.shm
               }) do
          function.()
        else
          _other -> {:error, :source_pin_failed}
        end
      rescue
        _error -> {:error, :source_pin_failed}
      catch
        _kind, _reason -> {:error, :source_pin_failed}
      end

    unless helper_stopped?(anchor.helper) do
      _ = safe_close_source(anchor.helper)
    end

    cleanup_result = cleanup_source_pin_set(ownership, pins, anchor)
    Process.delete(ownership)

    case cleanup_result do
      :ok -> operation_result
      {:error, _reason} -> {:error, :cleanup_pending}
    end
  end

  defp safe_close_source(helper) do
    DirectoryHelper.close_source(helper)
  rescue
    _error -> {:error, :source_close_failed}
  catch
    _kind, _reason -> {:error, :source_close_failed}
  end

  # The broker is the authority that creates source pins.  Populate the parent
  # ledger only from identities observed after a successful open_source reply;
  # expected source identities alone are not evidence that this invocation made
  # a pathname.
  defp register_source_pin_identities(ownership, pins, identities, uid) do
    result =
      Enum.reduce_while([:main, :wal, :shm], :ok, fn kind, :ok ->
        path = Map.fetch!(pins, kind)
        expected = Map.get(identities, kind)
        generated_shm? = kind == :shm and is_nil(expected) and not is_nil(identities[:wal])

        case File.lstat(path) do
          {:error, :enoent} when is_nil(expected) and not generated_shm? ->
            {:cont, :ok}

          {:ok, %File.Stat{type: :regular, uid: ^uid, mode: mode} = stat}
          when band(mode, 0o7777) == @private_file_mode ->
            actual = file_identity(stat)

            valid? =
              (generated_shm? and is_nil(expected)) or
                (not is_nil(expected) and
                   object_identity_from_file_identity(actual) ==
                     object_identity_from_file_identity(expected))

            if valid? do
              case register_owned_identity(
                     ownership,
                     path,
                     object_identity_from_file_identity(actual)
                   ) do
                :ok -> {:cont, :ok}
                {:error, _reason} = error -> {:halt, error}
              end
            else
              {:halt, {:error, :source_pin_identity_changed}}
            end

          {:error, :enoent} ->
            {:halt, {:error, :source_pin_missing}}

          _other ->
            {:halt, {:error, :source_pin_ambiguous}}
        end
      end)

    result
  rescue
    _error -> {:error, :source_pin_identity_failed}
  catch
    _kind, _reason -> {:error, :source_pin_identity_failed}
  end

  defp cleanup_source_pin_set(ownership, pins, anchor) do
    state = Process.get(ownership) || %{files: %{}}

    # A live helper can repair its held cwd even when its pathname was moved;
    # when the broker has died the parent ledger below remains authoritative.
    unless helper_stopped?(anchor.helper) do
      _ = DirectoryHelper.repair_mode(anchor.helper, 0o700, anchor.uid)
    end

    known_results =
      Enum.map(state.files, fn {path, identity} ->
        parent_unlink_identity(path, identity, anchor)
      end)

    candidates =
      [pins.main, pins.wal, pins.shm] ++
        Enum.flat_map([pins.main, pins.wal, pins.shm], fn path ->
          [path <> "-journal", path <> "-wal", path <> "-shm"]
        end)

    ambiguous? =
      Enum.any?(candidates, fn path ->
        File.lstat(path) != {:error, :enoent} and not Map.has_key?(state.files, path)
      end)

    cond do
      not Enum.all?(known_results, &(&1 == :ok)) -> {:error, :cleanup_pending}
      ambiguous? -> {:error, :cleanup_pending}
      state.files == %{} -> :ok
      true -> sync_parent_directory(anchor)
    end
  end

  defp helper_stopped?(helper),
    do: not is_nil(Process.get({__MODULE__, :stopped_helper, helper.owner}))

  defp source_metadata(source_path, uid, fingerprint, opts \\ []) do
    verification_path = Keyword.get(opts, :verification_path, source_path)
    published_name = Keyword.get(opts, :published_name, Path.basename(source_path))

    with :ok <- DatabaseFingerprint.verify_resolved(verification_path, fingerprint),
         {:ok, main} <- stable_file(source_path, uid, published_name),
         {:ok, wal} <- optional_stable_file(source_path <> "-wal", uid, published_name <> "-wal"),
         {:ok, shm} <- optional_stable_file(source_path <> "-shm", uid, published_name <> "-shm"),
         :ok <- DatabaseFingerprint.verify_resolved(verification_path, fingerprint) do
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

  defp optional_stable_file(path, uid, published_name) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, _stat} -> stable_file(path, uid, published_name)
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

  defp begin_ownership do
    ownership = make_ref()
    Process.put(ownership, %{committed?: false, files: %{}})
    ownership
  end

  defp register_owned_identity(ownership, path, identity) do
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

  defp remove_registered(ownership, path, anchor) do
    state = Process.get(ownership)

    with {:ok, identity} <- Map.fetch(state.files, path),
         :ok <- DirectoryHelper.unlink_identity(anchor.helper, Path.basename(path), identity) do
      Process.put(
        ownership,
        update_in(state.files, fn files -> Map.delete(files, path) end)
      )

      :ok
    else
      _other -> {:error, :file_identity_changed}
    end
  end

  defp register_link(ownership, from, to, expected_file_identity, uid, anchor) do
    state = Process.get(ownership)

    with {:ok, expected_object_identity} <- Map.fetch(state.files, from),
         {:ok, ^expected_object_identity} <- Map.fetch(state.files, to),
         {:ok, actual_identity} <-
           DirectoryHelper.private_identity(anchor.helper, Path.basename(to), uid),
         :ok <-
           equal(object_identity_from_file_identity(actual_identity), expected_object_identity),
         :ok <- equal(actual_identity, expected_file_identity) do
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
         after_absence_point,
         after_link_point
       ) do
    with {:ok, current_path} <- validate_helper_directory(anchor),
         :ok <- invoke_test_hook(test_hook, before_point, %{anchor: anchor, paths: paths}),
         {:ok, ^current_path} <- validate_helper_directory(anchor),
         :absent <- DirectoryHelper.entry_state(anchor.helper, Path.basename(to), uid),
         :ok <-
           invoke_test_hook(test_hook, after_absence_point, %{anchor: anchor, paths: paths}),
         {:ok, ^current_path} <- validate_helper_directory(anchor),
         {:ok, _from_identity} <- Map.fetch(Process.get(ownership).files, from),
         false <- Map.has_key?(Process.get(ownership).files, to),
         {:ok, linked_identity} <-
           DirectoryHelper.link_owned(
             anchor.helper,
             Path.basename(from),
             Path.basename(to),
             uid
           ),
         :ok <-
           register_owned_identity(
             ownership,
             to,
             object_identity_from_file_identity(linked_identity)
           ),
         :ok <- invoke_test_hook(test_hook, after_link_point, %{anchor: anchor, paths: paths}),
         :ok <- register_link(ownership, from, to, expected_file_identity, uid, anchor),
         {:ok, ^current_path} <- validate_helper_directory(anchor),
         :ok <- remove_registered(ownership, from, anchor),
         :ok <- verify_identity_anchored(to, expected_file_identity, uid, anchor),
         {:ok, ^current_path} <- validate_helper_directory(anchor) do
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

  defp finish_ownership(ownership, paths, _uid, anchor, test_hook, fault) do
    state = Process.get(ownership) || %{committed?: false, files: %{}}

    helper_result =
      try do
        stop_helper_once(anchor.helper)
      rescue
        _error -> {:error, :directory_helper_cleanup_pending}
      catch
        _kind, _reason -> {:error, :directory_helper_cleanup_pending}
      end

    parent_result = parent_cleanup_owned(state, paths, anchor, test_hook)

    ownership_result = inject_fault(fault, :finish_ownership)

    result =
      case {helper_result, parent_result, ownership_result} do
        {:ok, :ok, :ok} ->
          :ok

        {{:error, helper_reason}, _, _} ->
          {:error, {:helper_cleanup, helper_reason}}

        {_, {:error, parent_reason}, :ok} ->
          {:error, {:parent_cleanup, parent_reason}}

        {_, _, {:error, ownership_reason}} ->
          {:error, {:finish_ownership, ownership_reason}}

        {:ok, :ok, _} ->
          {:error, :cleanup_pending}
      end

    Process.delete(ownership)
    result
  end

  defp parent_cleanup_owned(state, paths, anchor, test_hook) do
    case parent_validate_anchor(anchor) do
      {:error, :cleanup_directory_changed} = error ->
        # A live helper may already have completed its identity-ledger cleanup
        # before the caller's pathname was renamed/replaced.  If the current
        # pathname contains no operation-owned candidates, there is no
        # unaccounted object to report as pending; otherwise fail closed.
        if operation_candidates_absent?(paths), do: :ok, else: error

      :ok ->
        with :ok <- repair_parent_directory(anchor),
             :ok <- invoke_test_hook(test_hook, :before_parent_cleanup, %{anchor: anchor}) do
          preserve_final? =
            state.committed? or
              File.lstat(paths.final_manifest) != {:error, :enoent}

          files =
            Enum.reject(state.files, fn {path, _identity} ->
              preserve_final? and path in [paths.final_database, paths.final_manifest]
            end)

          results =
            Enum.map(files, fn {path, identity} ->
              parent_unlink_identity(path, identity, anchor)
            end)

          cleanup_status =
            if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :cleanup_pending}

          case cleanup_status do
            :ok -> unknown_operation_files(paths, state, anchor)
            error -> error
          end
        end

      other ->
        other
    end
  end

  defp repair_parent_directory(anchor) do
    case File.lstat(anchor.path) do
      {:ok, %File.Stat{type: :directory, uid: uid, mode: mode} = stat}
      when uid == anchor.uid ->
        if directory_identity(stat) != anchor.identity,
          do: {:error, :cleanup_directory_changed},
          else: repair_parent_directory_mode(anchor, mode, uid)

      _other ->
        {:error, :cleanup_directory_changed}
    end
  rescue
    _error -> {:error, :cleanup_directory_changed}
  catch
    _kind, _reason -> {:error, :cleanup_directory_changed}
  end

  defp repair_parent_directory_mode(anchor, mode, uid) do
    if band(mode, 0o7777) == 0o700 do
      :ok
    else
      with :ok <- File.chmod(anchor.path, 0o700),
           {:ok, %File.Stat{type: :directory, uid: ^uid, mode: repaired} = current} <-
             File.lstat(anchor.path),
           true <- band(repaired, 0o7777) == 0o700,
           :ok <- equal(directory_identity(current), anchor.identity) do
        :ok
      else
        _other -> {:error, :cleanup_directory_changed}
      end
    end
  end

  defp operation_candidates_absent?(paths) do
    candidates = [
      paths.staging_database,
      paths.staging_manifest,
      paths.restore,
      paths.staging_database <> "-journal",
      paths.staging_database <> "-wal",
      paths.staging_database <> "-shm",
      paths.restore <> "-journal",
      paths.restore <> "-wal",
      paths.restore <> "-shm"
    ]

    Enum.all?(candidates, &(File.lstat(&1) == {:error, :enoent}))
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp unknown_operation_files(paths, state, anchor) do
    candidates = [
      paths.staging_database,
      paths.staging_manifest,
      paths.restore,
      paths.staging_database <> "-journal",
      paths.staging_database <> "-wal",
      paths.staging_database <> "-shm",
      paths.restore <> "-journal",
      paths.restore <> "-wal",
      paths.restore <> "-shm"
    ]

    unknown? =
      Enum.any?(candidates, fn path ->
        File.lstat(path) != {:error, :enoent} and not Map.has_key?(state.files, path)
      end) or unknown_operation_prefix?(paths, state, anchor)

    if unknown?, do: {:error, :cleanup_pending}, else: sync_parent_directory(anchor)
  end

  defp unknown_operation_prefix?(paths, state, anchor) do
    operation_id = Path.basename(paths.final_database, ".sqlite3")
    prefix = "." <> operation_id <> "."

    case File.ls(anchor.path) do
      {:ok, names} ->
        Enum.any?(names, fn name ->
          String.starts_with?(name, prefix) and
            not Map.has_key?(state.files, Path.join(anchor.path, name))
        end)

      _other ->
        true
    end
  rescue
    _error -> true
  catch
    _kind, _reason -> true
  end

  defp sync_parent_directory(anchor) do
    case :file.sync(anchor.handle) do
      :ok -> :ok
      _other -> {:error, :cleanup_pending}
    end
  rescue
    _error -> {:error, :cleanup_pending}
  catch
    _kind, _reason -> {:error, :cleanup_pending}
  end

  defp parent_validate_anchor(anchor) do
    with {:ok, stat} <- File.lstat(anchor.path),
         true <- stat.type == :directory and stat.uid == anchor.uid,
         true <- directory_identity(stat) == anchor.identity,
         {:ok, handle_identity} <- directory_handle_identity_relaxed(anchor.handle),
         true <- handle_identity == anchor.identity do
      :ok
    else
      _other -> {:error, :cleanup_directory_changed}
    end
  end

  defp parent_unlink_identity(path, expected, anchor) do
    if Path.dirname(path) == anchor.path do
      case File.lstat(path) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{type: :regular, uid: uid} = stat} when uid == anchor.uid ->
          if object_identity_from_file_identity(file_identity(stat)) == expected do
            case File.rm(path) do
              :ok -> :ok
              {:error, :enoent} -> :ok
              _other -> {:error, :cleanup_pending}
            end
          else
            :ok
          end

        _other ->
          :ok
      end
    else
      {:error, :cleanup_pending}
    end
  rescue
    _error -> {:error, :cleanup_pending}
  catch
    _kind, _reason -> {:error, :cleanup_pending}
  end

  defp sync_directory_anchored(anchor, test_hook, point) do
    directory_operation(anchor, test_hook, point, fn ->
      DirectoryHelper.sync_directory(anchor.helper)
    end)
  end

  defp sync_file_anchored(path, anchor, test_hook, point, expected_identity) do
    directory_operation(anchor, test_hook, point, fn ->
      DirectoryHelper.sync_file(
        anchor.helper,
        Path.basename(path),
        expected_identity,
        anchor.uid
      )
    end)
  end

  defp durable_duplicate(paths, uid, anchor, test_hook) do
    with {:ok, database_identity} <-
           broker_file_identity(anchor, paths.final_database, uid),
         {:ok, manifest_identity} <-
           broker_file_identity(anchor, paths.final_manifest, uid),
         :ok <-
           sync_file_anchored(
             paths.final_database,
             anchor,
             test_hook,
             :before_duplicate_database_sync,
             database_identity
           ),
         :ok <- verify_identity_anchored(paths.final_database, database_identity, uid, anchor),
         :ok <-
           sync_file_anchored(
             paths.final_manifest,
             anchor,
             test_hook,
             :before_duplicate_manifest_sync,
             manifest_identity
           ),
         :ok <- verify_identity_anchored(paths.final_manifest, manifest_identity, uid, anchor),
         :ok <-
           sync_directory_anchored(anchor, test_hook, :before_duplicate_directory_sync),
         :ok <- validate_backup_directory(anchor) do
      :ok
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
    with :ok <-
           verify_identity_anchored(
             paths.staging_database,
             database_identity,
             uid,
             anchor
           ),
         :ok <-
           verify_identity_anchored(
             paths.staging_manifest,
             manifest_identity,
             uid,
             anchor
           ),
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
             :after_database_absence_check,
             :after_database_link
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
             :after_manifest_absence_check,
             :after_manifest_link
           ),
         :ok <-
           DirectoryHelper.commit(
             anchor.helper,
             [
               {Path.basename(paths.final_database), database_identity},
               {Path.basename(paths.final_manifest), manifest_identity}
             ],
             uid
           ),
         :ok <- mark_committed(ownership),
         :ok <- sync_directory_anchored(anchor, test_hook, :before_final_directory_sync) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp validate_published(paths, uid, anchor) do
    with {:ok, current_path} <- validate_helper_directory(anchor),
         {:ok, _stat} <-
           DirectoryHelper.entry_state(anchor.helper, Path.basename(paths.final_database), uid),
         {:ok, _stat} <-
           DirectoryHelper.entry_state(anchor.helper, Path.basename(paths.final_manifest), uid),
         :absent <-
           DirectoryHelper.entry_state(anchor.helper, Path.basename(paths.staging_database), uid),
         :absent <-
           DirectoryHelper.entry_state(anchor.helper, Path.basename(paths.staging_manifest), uid),
         :absent <- DirectoryHelper.entry_state(anchor.helper, Path.basename(paths.restore), uid),
         {:ok, ^current_path} <- validate_helper_directory(anchor) do
      :ok
    else
      _other -> {:error, :published_artifact_invalid}
    end
  end

  defp verify_identity_anchored(path, expected, uid, anchor) do
    case DirectoryHelper.private_identity(anchor.helper, Path.basename(path), uid) do
      {:ok, ^expected} -> :ok
      _other -> {:error, :file_identity_changed}
    end
  end

  # Fault injection for the cleanup tail: unlike the operation faults above
  # (which throw), `:finish_ownership` returns the cleanup-failure *result* so
  # both `create_new` and `revalidate_existing` keep the verified artifact and
  # surface the failure only in the warning. `nil` fault never fires.
  defp inject_fault(nil, _point), do: :ok
  defp inject_fault(:finish_ownership, :finish_ownership), do: {:error, :finish_ownership}
  defp inject_fault(point, point), do: throw({:injected_backup_fault, point})
  defp inject_fault(_configured, _point), do: :ok

  defp file_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.mode, stat.size}
  end

  defp object_identity_from_file_identity({type, major, minor, inode, uid, _mode, _size}) do
    {type, major, minor, inode, uid}
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

  defp cleanup_pending_error do
    StartupError.new(
      :cleanup_pending,
      true,
      "Backup cleanup is still pending; no settled failure is being reported while owned temporary files may remain.",
      "Keep the backup directory private and retry after the cleanup owner reports terminal evidence."
    )
  end
end
