defmodule SwarmCode.Daemon.FoundationGate do
  @moduledoc false

  import Bitwise

  alias SwarmCode.Daemon.Backup
  alias SwarmCode.Daemon.Backup.Artifact
  alias SwarmCode.Daemon.CrossAppLease

  alias SwarmCode.Daemon.Platform.{
    DatabaseFingerprint,
    PathSet,
    Paths,
    PrivateDirectory,
    ProcessIdentity
  }

  alias SwarmCode.Daemon.Schema
  alias SwarmCode.Daemon.Schema.Gate.Decision
  alias SwarmCode.Daemon.Schema.MigrationManifest
  alias SwarmCode.Daemon.StartupError

  @manifest_source Path.expand("../../../priv/schema/desktop-dbb8804b.json", __DIR__)
  @external_resource @manifest_source
  @audited_manifest MigrationManifest.load!(@manifest_source)
  @schema_contract %{
    epoch: @audited_manifest.data_epoch,
    newest_migration: List.last(@audited_manifest.migrations).version,
    manifest_sha256: @audited_manifest.migration_set_sha256
  }
  @default_app_version @audited_manifest.minimum_reader

  @maximum_path_bytes 16 * 1_024
  @maximum_identity_bytes 4 * 1_024
  @maximum_pid 9_223_372_036_854_775_807
  @desktop_applications ["SwarmCode", "SwarmCode.app", "com.zaali.swarmcode"]
  @lease_stop_timeout 5_000
  @lease_down_timeout 5_000
  @cleanup_owner_ready_timeout 5_000
  @cleanup_owner_result_timeout @lease_stop_timeout + @lease_down_timeout + 1_000
  @test_build Mix.env() == :test
  @default_mode (case Mix.env() do
                   :prod -> :production
                   :test -> :test
                   _other -> :development
                 end)

  @path_options [:platform, :mode, :home, :env, :database_path]
  @base_options @path_options ++ [:app_version]
  if @test_build do
    @allowed_options @base_options ++
                       [
                         :backup_operation_id,
                         :backup_opts,
                         :backup_options,
                         :clock,
                         :detector,
                         :desktop_detector,
                         :directory_ensure,
                         :identity,
                         :identity_fun,
                         :lease_options,
                         :lease_opts,
                         :manifest_path,
                         :now,
                         :operation_id
                       ]
  else
    @allowed_options @base_options
  end

  defmodule Ready do
    @moduledoc false

    alias SwarmCode.Daemon.Platform.{PathSet, ProcessIdentity}
    alias SwarmCode.Daemon.Schema.Gate.Decision

    @enforce_keys [:paths, :identity, :lease, :schema, :backup]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            paths: PathSet.t(),
            identity: ProcessIdentity.t(),
            lease: pid(),
            schema: Decision.t(),
            backup: nil
          }
  end

  @spec prepare(keyword()) :: {:ok, Ready.t()} | {:error, StartupError.t()}
  def prepare(opts) when is_list(opts) do
    try do
      with {:ok, paths} <- resolve_paths(opts),
           {:ok, config} <- configuration(opts, paths),
           {:ok, identity} <- obtain_identity(config.identity),
           :ok <- ensure_private_directories(paths, identity.uid, config.directory_ensure),
           :ok <- detect_desktop(config.desktop_detector, identity.uid),
           {:ok, fingerprint} <- database_fingerprint(paths.database),
           {:ok, lease} <- acquire_lease(paths, identity, fingerprint, config) do
        prepare_while_holding_lease(lease, paths, identity, fingerprint, config)
      end
    rescue
      _error -> {:error, foundation_failed()}
    catch
      _kind, _reason -> {:error, foundation_failed()}
    end
  end

  def prepare(_opts), do: {:error, foundation_failed()}

  @doc false
  @spec schema_contract() :: %{
          epoch: non_neg_integer(),
          newest_migration: pos_integer(),
          manifest_sha256: String.t()
        }
  def schema_contract, do: @schema_contract

  defp resolve_paths(opts) do
    try do
      path_opts = [
        platform: Keyword.get_lazy(opts, :platform, &current_platform/0),
        mode: Keyword.get(opts, :mode, @default_mode),
        home: Keyword.get_lazy(opts, :home, &System.user_home!/0),
        env: Keyword.get_lazy(opts, :env, &System.get_env/0)
      ]

      path_opts =
        case Keyword.fetch(opts, :database_path) do
          {:ok, path} -> Keyword.put(path_opts, :database_path, path)
          :error -> path_opts
        end

      case Paths.resolve(path_opts) do
        {:ok, %PathSet{} = paths} ->
          if valid_path_set?(paths), do: {:ok, paths}, else: {:error, path_resolution_failed()}

        _other ->
          {:error, path_resolution_failed()}
      end
    rescue
      _error -> {:error, path_resolution_failed()}
    catch
      _kind, _reason -> {:error, path_resolution_failed()}
    end
  end

  defp configuration(opts, paths) do
    with true <- Keyword.keyword?(opts),
         keys <- Keyword.keys(opts),
         true <- keys == Enum.uniq(keys),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         {:ok, app_version} <- app_version(opts),
         {:ok, test_config} <- test_configuration(opts, paths.platform) do
      {:ok, Map.put(test_config, :app_version, app_version)}
    else
      _other -> {:error, foundation_failed()}
    end
  end

  if @test_build do
    defp test_configuration(opts, platform) do
      identity =
        first_option(opts, [:identity, :identity_fun], fn ->
          ProcessIdentity.current(platform: platform)
        end)

      desktop_detector =
        first_option(opts, [:desktop_detector, :detector], default_desktop_detector(platform))

      directory_ensure = Keyword.get(opts, :directory_ensure, &PrivateDirectory.ensure/2)
      clock = first_option(opts, [:clock, :now], &DateTime.utc_now/0)
      clock = if is_function(clock, 0), do: clock, else: fn -> clock end
      manifest_path = Keyword.get(opts, :manifest_path)
      operation_id = first_option(opts, [:backup_operation_id, :operation_id], nil)
      backup_options = first_option(opts, [:backup_options, :backup_opts], [])
      lease_options = first_option(opts, [:lease_options, :lease_opts], [])

      if valid_identity_source?(identity) and valid_detector_source?(desktop_detector) and
           is_function(directory_ensure, 2) and is_function(clock, 0) and
           (is_nil(manifest_path) or valid_path?(manifest_path)) and
           (is_nil(operation_id) or valid_uuid?(operation_id)) and
           valid_backup_options?(backup_options) and valid_lease_options?(lease_options) do
        {:ok,
         %{
           identity: identity,
           desktop_detector: desktop_detector,
           directory_ensure: directory_ensure,
           clock: clock,
           manifest_path: manifest_path,
           backup_operation_id: operation_id,
           backup_options: backup_options,
           lease_options: lease_options
         }}
      else
        {:error, :invalid_test_configuration}
      end
    end

    defp first_option(opts, keys, default) do
      case Enum.find(keys, &Keyword.has_key?(opts, &1)) do
        nil -> default
        key -> Keyword.fetch!(opts, key)
      end
    end

    defp valid_identity_source?(%ProcessIdentity{}), do: true
    defp valid_identity_source?(value), do: is_function(value, 0)

    defp valid_detector_source?(value) when is_function(value, 0), do: true
    defp valid_detector_source?(value), do: value in [:none] or match?({:active, _}, value)

    defp valid_backup_options?(opts) do
      Keyword.keyword?(opts) and Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
        Enum.all?(Keyword.keys(opts), &(&1 in [:fault, :test_hook]))
    end

    defp valid_lease_options?(opts) do
      (Keyword.keyword?(opts) and Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
         Keyword.keys(opts) == [:cleanup_barrier] and
         is_function(Keyword.fetch!(opts, :cleanup_barrier), 0)) or opts == []
    end
  else
    defp test_configuration(_opts, platform) do
      {:ok,
       %{
         identity: fn -> ProcessIdentity.current(platform: platform) end,
         desktop_detector: default_desktop_detector(platform),
         directory_ensure: &PrivateDirectory.ensure/2,
         clock: &DateTime.utc_now/0,
         manifest_path: nil,
         backup_operation_id: nil,
         backup_options: [],
         lease_options: []
       }}
    end
  end

  defp app_version(opts) do
    version = Keyword.get_lazy(opts, :app_version, &runtime_app_version/0)

    with true <- is_binary(version) and byte_size(version) in 1..128,
         {:ok, parsed} <- Version.parse(version),
         true <- to_string(parsed) == version do
      {:ok, version}
    else
      _other -> {:error, :invalid_app_version}
    end
  end

  defp runtime_app_version do
    case Application.spec(:swarm_code_daemon, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _other -> @default_app_version
    end
  end

  defp obtain_identity(callback) do
    result =
      case callback do
        %ProcessIdentity{} = identity -> identity
        _other -> invoke_zero_arity(callback)
      end

    case result do
      {:ok, %ProcessIdentity{} = identity} ->
        validate_identity(identity)

      %ProcessIdentity{} = identity ->
        validate_identity(identity)

      {:error, :macos_platform_helper_unavailable} ->
        {:error, macos_platform_helper_unavailable()}

      _other ->
        {:error, process_identity_unavailable()}
    end
  end

  defp validate_identity(
         %ProcessIdentity{
           uid: uid,
           pid: pid,
           process_start_id: process_start_id,
           boot_id: boot_id
         } = identity
       )
       when is_integer(uid) and uid >= 0 and is_integer(pid) and pid > 0 do
    if valid_identity_text?(process_start_id) and valid_identity_text?(boot_id),
      do: {:ok, identity},
      else: {:error, process_identity_unavailable()}
  end

  defp validate_identity(_identity), do: {:error, process_identity_unavailable()}

  defp ensure_private_directories(paths, uid, callback) do
    Enum.reduce_while(private_directories(paths), :ok, fn path, :ok ->
      result =
        try do
          callback.(path, uid)
        rescue
          _error -> :callback_failed
        catch
          _kind, _reason -> :callback_failed
        end

      case result do
        :ok -> {:cont, :ok}
        _other -> {:halt, {:error, private_directory_failed()}}
      end
    end)
  end

  defp private_directories(paths) do
    platform_directories =
      case paths.platform do
        :macos -> [Path.dirname(paths.cache)]
        :linux -> []
      end

    [paths.data, paths.config, paths.state, paths.cache, paths.runtime, paths.backups]
    |> Kernel.++(platform_directories)
    |> Enum.flat_map(&directory_chain/1)
    |> Enum.uniq()
    |> Enum.sort_by(fn path -> {length(Path.split(path)), path} end)
  end

  # `PrivateDirectory.ensure/2` intentionally creates one leaf only. Build the
  # product-owned chain without mkdir-p so every component is checked by the
  # same ownership/mode gate and parent components are admitted first.
  defp directory_chain(path) when is_binary(path) do
    expanded = Path.expand(path)
    components = Path.split(expanded)

    {chain, _prefix, _started?} =
      Enum.reduce(tail_components(components), {[], hd(components), false}, fn component,
                                                                               {chain, prefix,
                                                                                started?} ->
        next = Path.join(prefix, component)

        cond do
          started? ->
            {[next | chain], next, true}

          next == expanded ->
            {[next | chain], next, true}

          match?(
            {:ok, %File.Stat{type: type}} when type in [:directory, :symlink],
            File.lstat(next)
          ) ->
            {chain, next, false}

          true ->
            {[next | chain], next, true}
        end
      end)

    Enum.reverse(chain)
  end

  defp directory_chain(_path), do: []

  defp tail_components([_root | rest]), do: rest
  defp tail_components([]), do: []

  defp detect_desktop(callback, uid) do
    result = invoke_zero_arity(callback)

    case result do
      :none ->
        :ok

      {:active, metadata} ->
        active_desktop(metadata, uid)

      _other ->
        {:error, macos_platform_helper_unavailable()}
    end
  end

  defp invoke_zero_arity(callback) when is_function(callback, 0) do
    try do
      callback.()
    rescue
      _error -> :callback_failed
    catch
      _kind, _reason -> :callback_failed
    end
  end

  defp invoke_zero_arity(value), do: value

  defp active_desktop(metadata, uid) when is_map(metadata) do
    case detector_metadata(metadata) do
      {:ok, pid, application, nil} ->
        {:error, desktop_active(pid, application)}

      {:ok, pid, application, detected_uid} when detected_uid == uid ->
        {:error, desktop_active(pid, application)}

      _other ->
        {:error, macos_platform_helper_unavailable()}
    end
  end

  defp active_desktop(_metadata, _uid), do: {:error, macos_platform_helper_unavailable()}

  defp detector_metadata(metadata) do
    cond do
      exact_keys?(metadata, [:application, :pid]) ->
        {:ok, Map.get(metadata, :pid), Map.get(metadata, :application), nil}

      exact_keys?(metadata, [:application, :pid, :uid]) ->
        {:ok, Map.get(metadata, :pid), Map.get(metadata, :application), Map.get(metadata, :uid)}

      exact_keys?(metadata, ["application", "pid"]) ->
        {:ok, Map.get(metadata, "pid"), Map.get(metadata, "application"), nil}

      exact_keys?(metadata, ["application", "pid", "uid"]) ->
        {:ok, Map.get(metadata, "pid"), Map.get(metadata, "application"),
         Map.get(metadata, "uid")}

      true ->
        :malformed
    end
    |> validate_detector_metadata()
  end

  defp validate_detector_metadata({:ok, pid, application, uid})
       when is_integer(pid) and pid in 1..@maximum_pid and is_integer(uid) and uid >= 0 do
    if valid_application_name?(application), do: {:ok, pid, application, uid}, else: :malformed
  end

  defp validate_detector_metadata({:ok, pid, application, :same_uid})
       when is_integer(pid) and pid in 1..@maximum_pid do
    if valid_application_name?(application), do: {:ok, pid, application, nil}, else: :malformed
  end

  defp validate_detector_metadata({:ok, pid, application, nil})
       when is_integer(pid) and pid in 1..@maximum_pid do
    if valid_application_name?(application), do: {:ok, pid, application, nil}, else: :malformed
  end

  defp validate_detector_metadata(_other), do: :malformed

  defp exact_keys?(map, expected) do
    keys = Map.keys(map)
    length(keys) == length(expected) and Enum.all?(keys, &(&1 in expected))
  end

  defp default_desktop_detector(:linux), do: fn -> :none end

  defp default_desktop_detector(:macos),
    do: fn -> {:error, :macos_platform_helper_unavailable} end

  defp default_desktop_detector(_platform),
    do: fn -> {:error, :macos_platform_helper_unavailable} end

  defp database_fingerprint(path) do
    try do
      case DatabaseFingerprint.for_path_or_absent(path) do
        {:ok, fingerprint} when is_binary(fingerprint) -> {:ok, fingerprint}
        _other -> {:error, database_fingerprint_failed()}
      end
    rescue
      _error -> {:error, database_fingerprint_failed()}
    catch
      _kind, _reason -> {:error, database_fingerprint_failed()}
    end
  end

  defp acquire_lease(paths, identity, fingerprint, config) do
    required = [
      lease_path: paths.lease,
      owner_path: paths.owner_record,
      identity: identity,
      database_fingerprint: fingerprint,
      schema_contract: @schema_contract,
      socket_path: paths.socket,
      app_version: config.app_version
    ]

    lease_opts = Keyword.merge(config.lease_options, required)

    result =
      try do
        CrossAppLease.start_link(lease_opts)
      rescue
        _error -> :lease_start_failed
      catch
        _kind, _reason -> :lease_start_failed
      end

    case result do
      {:ok, lease} when is_pid(lease) ->
        {:ok, lease}

      {:error, %StartupError{code: :data_lease_held} = error} ->
        {:error, error}

      _other ->
        {:error, lease_failed()}
    end
  end

  defp prepare_while_holding_lease(lease, paths, identity, fingerprint, config) do
    monitor = Process.monitor(lease)

    result =
      try do
        with :ok <- detect_desktop(config.desktop_detector, identity.uid),
             :ok <- verify_database_fingerprint(paths.database, fingerprint),
             {:ok, manifest} <- load_manifest(config.manifest_path),
             :ok <- validate_loaded_contract(manifest),
             {:ok, %Decision{} = decision} <-
               schema_check(paths.database, manifest, config.app_version) do
          finish_decision(decision, lease, paths, identity, fingerprint, config)
        else
          {:error, %StartupError{} = error} -> {:error, error}
          _other -> {:error, foundation_failed()}
        end
      rescue
        _error -> {:error, foundation_failed()}
      catch
        _kind, _reason -> {:error, foundation_failed()}
      end

    case result do
      {:ok, %Ready{lease: ^lease}} = success ->
        Process.demonitor(monitor, [:flush])
        success

      {:error, %StartupError{} = error} ->
        {:error, stop_lease_before_return(lease, monitor, error)}

      _other ->
        {:error, stop_lease_before_return(lease, monitor, foundation_failed())}
    end
  end

  defp verify_database_fingerprint(path, fingerprint) do
    case DatabaseFingerprint.verify_path_or_absent(path, fingerprint) do
      :ok -> :ok
      _other -> {:error, database_fingerprint_changed()}
    end
  rescue
    _error -> {:error, database_fingerprint_changed()}
  catch
    _kind, _reason -> {:error, database_fingerprint_changed()}
  end

  defp schema_check(path, manifest, app_version) do
    try do
      case Schema.Gate.check(path, manifest, app_version) do
        {:ok, %Decision{} = decision} -> {:ok, decision}
        {:error, %StartupError{} = error} -> {:error, error}
        _other -> {:error, schema_incompatible()}
      end
    rescue
      _error -> {:error, schema_incompatible()}
    catch
      _kind, _reason -> {:error, schema_incompatible()}
    end
  end

  defp load_manifest(nil) do
    safe_load_manifest(fn -> MigrationManifest.load!() end)
  end

  defp load_manifest(path) do
    safe_load_manifest(fn -> MigrationManifest.load!(path) end)
  end

  defp safe_load_manifest(loader) do
    try do
      case loader.() do
        %MigrationManifest{} = manifest -> {:ok, manifest}
        _other -> {:error, migration_manifest_invalid()}
      end
    rescue
      _error -> {:error, migration_manifest_invalid()}
    catch
      _kind, _reason -> {:error, migration_manifest_invalid()}
    end
  end

  defp validate_loaded_contract(%MigrationManifest{} = manifest) do
    newest = List.last(manifest.migrations)

    if ((manifest.data_epoch == @schema_contract.epoch and newest) &&
          newest.version == @schema_contract.newest_migration) and
         manifest.migration_set_sha256 == @schema_contract.manifest_sha256 do
      :ok
    else
      {:error, migration_manifest_invalid()}
    end
  end

  defp finish_decision(
         %Decision{status: :ready} = decision,
         lease,
         paths,
         identity,
         _fingerprint,
         _config
       ) do
    case assert_held(lease) do
      :ok ->
        {:ok,
         %Ready{
           paths: paths,
           identity: identity,
           lease: lease,
           schema: decision,
           backup: nil
         }}

      {:error, %StartupError{} = error} ->
        {:error, error}
    end
  end

  defp finish_decision(
         %Decision{status: :new_database},
         _lease,
         _paths,
         _identity,
         _fingerprint,
         _config
       ) do
    {:error, new_database_implementation_not_installed()}
  end

  defp finish_decision(
         %Decision{status: :migration_required} = decision,
         lease,
         paths,
         identity,
         fingerprint,
         config
       ) do
    operation_id = config.backup_operation_id || backup_operation_id(fingerprint, decision)

    backup_opts =
      Keyword.merge(config.backup_options,
        uid: identity.uid,
        now: config.clock
      )

    case Backup.Gate.create(
           paths.database,
           paths.backups,
           operation_id,
           lease,
           decision,
           backup_opts
         ) do
      {:ok, %Artifact{} = artifact} ->
        {:error, migration_implementation_not_installed(artifact)}

      {:error, %StartupError{} = error} ->
        {:error, error}

      _other ->
        {:error, foundation_failed()}
    end
  end

  defp finish_decision(_decision, _lease, _paths, _identity, _fingerprint, _config),
    do: {:error, foundation_failed()}

  defp assert_held(lease) do
    result =
      try do
        CrossAppLease.assert_held(lease)
      rescue
        _error -> :lease_not_held
      catch
        _kind, _reason -> :lease_not_held
      end

    if result == :ok, do: :ok, else: {:error, lease_failed()}
  end

  defp backup_operation_id(fingerprint, %Decision{probe: probe}) do
    payload = [
      "swarm-code-foundation-backup-operation\n",
      "version=1\n",
      "database_fingerprint=",
      fingerprint,
      ?\n,
      "schema_sha256=",
      probe.schema_sha256,
      ?\n,
      "target_manifest=",
      @schema_contract.manifest_sha256,
      ?\n
    ]

    <<time_low::32, time_mid::16, time_high::16, clock_sequence::16, node::48, _rest::binary>> =
      :crypto.hash(:sha256, payload)

    time_high = bor(band(time_high, 0x0FFF), 0x5000)
    clock_sequence = bor(band(clock_sequence, 0x3FFF), 0x8000)

    {:ok, uuid} =
      Ecto.UUID.load(<<time_low::32, time_mid::16, time_high::16, clock_sequence::16, node::48>>)

    uuid
  end

  defp stop_lease_before_return(lease, monitor, primary_error) do
    caller = self()
    ref = make_ref()
    {owner, owner_monitor} = spawn_monitor(fn -> cleanup_owner_entry(caller, ref, lease) end)

    case await_cleanup_owner_ready(owner, owner_monitor, ref) do
      :ready ->
        # The cleanup owner has linked the lease before this caller drops its
        # acquisition link. This closes the only hand-off gap in which caller
        # cancellation could orphan the SQLite connection.
        _ = Process.unlink(lease)
        send(owner, {:foundation_cleanup_release, ref, caller})
        await_cleanup_owner_result(owner, owner_monitor, lease, monitor, ref, primary_error)

      {:owner_down, owner_down?} ->
        # The caller still owns the original link. A failed owner cannot strand
        # the lease, so contain the linked fallback and settle the owner first.
        fallback_cleanup_with_link(
          lease,
          monitor,
          owner,
          owner_monitor,
          owner_down?,
          ref,
          primary_error
        )

      :timeout ->
        # Ask an owner that has not completed hand-off to leave without touching
        # the caller's link. If it is unresponsive, the fallback force-terminates
        # it while trapping the link signals locally.
        send(owner, {:foundation_cleanup_cancel, ref, caller})

        owner_down? =
          case await_owner_down(owner, owner_monitor, @cleanup_owner_ready_timeout) do
            {:down, _reason} -> true
            :timeout -> false
          end

        fallback_cleanup_with_link(
          lease,
          monitor,
          owner,
          owner_monitor,
          owner_down?,
          ref,
          primary_error
        )
    end
  end

  defp await_cleanup_owner_ready(owner, owner_monitor, ref) do
    receive do
      {:foundation_cleanup_owner_ready, ^ref, ^owner} ->
        :ready

      {:foundation_cleanup_owner_failed, ^ref, ^owner} ->
        {:owner_down, false}

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        {:owner_down, true}
    after
      @cleanup_owner_ready_timeout -> :timeout
    end
  end

  defp await_cleanup_owner_result(owner, owner_monitor, lease, monitor, ref, primary_error) do
    receive do
      {:foundation_cleanup_owner_result, ^ref, abnormal?} when is_boolean(abnormal?) ->
        send(owner, {:foundation_cleanup_ack, ref, self()})
        lease_reason = await_lease_down_or_force(lease, monitor)
        settle_cleanup_owner(owner, owner_monitor)

        if abnormal? or abnormal_exit_reason?(lease_reason),
          do: record_cleanup_problem(primary_error),
          else: primary_error

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        _ = await_lease_down_or_force(lease, monitor)
        flush_cleanup_owner_messages(ref, owner)
        record_cleanup_problem(primary_error)
    after
      @cleanup_owner_result_timeout ->
        _ = Process.exit(owner, :kill)
        _ = await_owner_down(owner, owner_monitor, :infinity)
        _ = await_lease_down_or_force(lease, monitor)
        flush_cleanup_owner_messages(ref, owner)
        record_cleanup_problem(primary_error)
    end
  end

  defp cleanup_owner_entry(caller, ref, lease) do
    # This process owns the lease only for the failure-cleanup interval. It is
    # deliberately not linked to the caller: caller shutdown is observed
    # through a monitor, while the lease link guarantees owner cancellation
    # cannot leave an acquired SQLite connection behind.
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    lease_monitor = Process.monitor(lease)

    state = %{
      caller: caller,
      caller_monitor: caller_monitor,
      lease: lease,
      lease_monitor: lease_monitor,
      ref: ref,
      lease_exit_abnormal?: false
    }

    case link_cleanup_lease(lease) do
      :ok ->
        send(caller, {:foundation_cleanup_owner_ready, ref, self()})
        cleanup_owner_wait_release(state)

      :error ->
        send(caller, {:foundation_cleanup_owner_failed, ref, self()})
    end
  end

  defp link_cleanup_lease(lease) do
    Process.link(lease)
    :ok
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp cleanup_owner_wait_release(state) do
    receive do
      {:foundation_cleanup_release, ref, caller}
      when ref == state.ref and caller == state.caller ->
        cleanup_owner_run(state)

      {:foundation_cleanup_cancel, ref, caller}
      when ref == state.ref and caller == state.caller ->
        Process.unlink(state.lease)
        :ok

      {:EXIT, lease, reason} when lease == state.lease ->
        cleanup_owner_wait_release(%{
          state
          | lease_exit_abnormal?: state.lease_exit_abnormal? or abnormal_exit_reason?(reason)
        })

      {:DOWN, monitor, :process, lease, reason}
      when monitor == state.lease_monitor and lease == state.lease ->
        cleanup_owner_finish(
          state,
          state.lease_exit_abnormal? or abnormal_exit_reason?(reason)
        )

      {:DOWN, monitor, :process, caller, reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        cleanup_owner_after_caller_down(state, reason)
    end
  end

  defp cleanup_owner_run(state) do
    graceful_result = request_graceful_stop(state.lease)

    case await_owner_lease_down(state, graceful_result, state.lease_exit_abnormal?) do
      {:lease_down, reason, abnormal?} ->
        cleanup_owner_finish(state, abnormal? or abnormal_exit_reason?(reason))

      {:caller_down, reason} ->
        cleanup_owner_after_caller_down(state, reason)

      {:timeout, _abnormal?} ->
        force_owner_lease(state)
    end
  end

  defp request_graceful_stop(lease) do
    # A zero wait dispatches GenServer's synchronous stop request and returns
    # immediately; the cleanup owner then observes the exact lease monitor for
    # up to @lease_down_timeout while it remains able to notice caller death.
    try do
      case GenServer.stop(lease, :normal, 0) do
        :ok -> :requested
        _other -> :failed
      end
    rescue
      _error -> :failed
    catch
      :exit, {:timeout, _details} -> :requested
      :exit, _reason -> :failed
      _kind, _reason -> :failed
    end
  end

  defp await_owner_lease_down(state, graceful_result, abnormal?) do
    timeout = if graceful_result == :requested, do: @lease_down_timeout, else: 0

    receive do
      {:EXIT, lease, reason} when lease == state.lease ->
        await_owner_lease_down(
          state,
          graceful_result,
          abnormal? or abnormal_exit_reason?(reason)
        )

      {:DOWN, monitor, :process, lease, reason}
      when monitor == state.lease_monitor and lease == state.lease ->
        {:lease_down, reason, abnormal?}

      {:DOWN, monitor, :process, caller, reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        {:caller_down, reason}
    after
      timeout -> {:timeout, abnormal?}
    end
  end

  defp force_owner_lease(state) do
    _ = Process.exit(state.lease, :kill)

    case await_owner_forced_down(state, false, nil) do
      {:lease_down, _reason, caller_down?, caller_reason} ->
        if caller_down?,
          do: cleanup_owner_exit_after_lease_down(state, caller_reason),
          else: cleanup_owner_finish(state, true)
    end
  end

  defp await_owner_forced_down(state, caller_down?, caller_reason) do
    receive do
      {:EXIT, lease, _reason} when lease == state.lease ->
        await_owner_forced_down(state, caller_down?, caller_reason)

      {:DOWN, monitor, :process, caller, reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        await_owner_forced_down(state, true, reason)

      {:DOWN, monitor, :process, lease, reason}
      when monitor == state.lease_monitor and lease == state.lease ->
        {:lease_down, reason, caller_down?, caller_reason}
    end
  end

  defp cleanup_owner_after_caller_down(state, caller_reason) do
    _ = Process.exit(state.lease, :kill)
    _ = await_owner_forced_down(state, true, caller_reason)
    cleanup_owner_exit_after_lease_down(state, caller_reason)
  end

  defp cleanup_owner_exit_after_lease_down(state, caller_reason) do
    Process.unlink(state.lease)
    exit(caller_reason)
  end

  defp cleanup_owner_finish(state, abnormal?) do
    Process.unlink(state.lease)
    send(state.caller, {:foundation_cleanup_owner_result, state.ref, abnormal?})

    receive do
      {:foundation_cleanup_ack, ref, caller}
      when ref == state.ref and caller == state.caller ->
        :ok

      {:DOWN, monitor, :process, caller, _reason}
      when monitor == state.caller_monitor and caller == state.caller ->
        :ok
    after
      @cleanup_owner_ready_timeout -> :ok
    end
  end

  defp await_lease_down_or_force(lease, monitor) do
    case await_lease_down(lease, monitor, @lease_down_timeout) do
      {:ok, reason} ->
        reason

      :timeout ->
        _ = Process.exit(lease, :kill)
        await_lease_down(lease, monitor, :infinity)
    end
  end

  defp await_lease_down(lease, monitor, :infinity) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, reason} -> reason
    end
  end

  defp await_lease_down(lease, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^lease, reason} -> {:ok, reason}
    after
      timeout -> :timeout
    end
  end

  defp await_owner_down(owner, monitor, :infinity) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, reason} -> {:down, reason}
    end
  end

  defp await_owner_down(owner, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, reason} -> {:down, reason}
    after
      timeout -> :timeout
    end
  end

  defp settle_cleanup_owner(owner, monitor) do
    case await_owner_down(owner, monitor, @cleanup_owner_ready_timeout) do
      {:down, _reason} ->
        :ok

      :timeout ->
        _ = Process.exit(owner, :kill)
        _ = await_owner_down(owner, monitor, :infinity)
        :ok
    end
  end

  defp fallback_cleanup_with_link(
         lease,
         monitor,
         owner,
         owner_monitor,
         owner_down?,
         ref,
         primary_error
       ) do
    previous_trap_exit = Process.flag(:trap_exit, true)
    linked_sources = linked_processes()

    try do
      unless owner_down? do
        _ = Process.exit(owner, :kill)
        _ = await_owner_down(owner, owner_monitor, :infinity)
      end

      graceful_result = request_graceful_stop(lease)

      result =
        case await_graceful_lease_down_contained(lease, monitor, graceful_result, false) do
          {:down, reason, abnormal?} ->
            if abnormal? or abnormal_exit_reason?(reason),
              do: record_cleanup_problem(primary_error),
              else: primary_error

          {:timeout, _abnormal?} ->
            _ = Process.exit(lease, :kill)
            _ = await_lease_down_contained(lease, monitor)
            record_cleanup_problem(primary_error)
        end

      _ = Process.flag(:trap_exit, previous_trap_exit)
      replay_unrelated_exit_messages(lease, previous_trap_exit, linked_sources)
      flush_cleanup_owner_messages(ref, owner)
      result
    after
      _ = Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp await_graceful_lease_down_contained(lease, monitor, graceful_result, abnormal?) do
    timeout = if graceful_result == :requested, do: @lease_down_timeout, else: 0

    receive do
      {:EXIT, ^lease, reason} ->
        await_graceful_lease_down_contained(
          lease,
          monitor,
          graceful_result,
          abnormal? or abnormal_exit_reason?(reason)
        )

      {:DOWN, ^monitor, :process, ^lease, reason} ->
        {:down, reason, abnormal?}
    after
      timeout -> {:timeout, abnormal?}
    end
  end

  defp await_lease_down_contained(lease, monitor) do
    receive do
      {:EXIT, ^lease, _reason} -> await_lease_down_contained(lease, monitor)
      {:DOWN, ^monitor, :process, ^lease, _reason} -> :ok
    end
  end

  defp linked_processes do
    case Process.info(self(), :links) do
      {:links, links} when is_list(links) -> links
      _other -> []
    end
  end

  defp replay_unrelated_exit_messages(_lease, true, _linked_sources), do: :ok

  defp replay_unrelated_exit_messages(lease, false, linked_sources) do
    replay_unrelated_exit_messages(
      lease,
      false,
      Enum.reject(linked_sources, &(&1 == lease)),
      false
    )
  end

  # A real link emits at most one EXIT signal for a given peer. Remove each
  # observed peer from the replay set so forged/repeated mailbox tuples cannot
  # keep cleanup in an unbounded drain loop.
  defp replay_unrelated_exit_messages(lease, false, remaining_sources, lease_exit_seen?) do
    receive do
      {:EXIT, ^lease, _reason} when not lease_exit_seen? ->
        replay_unrelated_exit_messages(lease, false, remaining_sources, true)

      {:EXIT, from, reason} ->
        if from in remaining_sources do
          remaining_sources = List.delete(remaining_sources, from)

          if abnormal_exit_reason?(reason) do
            Process.exit(self(), reason)
          else
            replay_unrelated_exit_messages(lease, false, remaining_sources, lease_exit_seen?)
          end
        else
          send(self(), {:EXIT, from, reason})
          :ok
        end
    after
      0 -> :ok
    end
  end

  defp flush_cleanup_owner_messages(ref, owner) do
    receive do
      {:foundation_cleanup_owner_ready, ^ref, ^owner} ->
        flush_cleanup_owner_messages(ref, owner)

      {:foundation_cleanup_owner_failed, ^ref, ^owner} ->
        flush_cleanup_owner_messages(ref, owner)

      {:foundation_cleanup_owner_result, ^ref, _abnormal?} ->
        flush_cleanup_owner_messages(ref, owner)
    after
      0 -> :ok
    end
  end

  defp abnormal_exit_reason?(nil), do: true
  defp abnormal_exit_reason?(:normal), do: false
  defp abnormal_exit_reason?(_reason), do: true

  defp record_cleanup_problem(%StartupError{} = error) do
    %{
      error
      | message:
          error.message <>
            " The acquired data lease required abnormal cleanup before this refusal returned.",
        action:
          error.action <>
            " Confirm the CLI daemon is stopped; a stale diagnostic owner record may remain."
    }
  end

  defp valid_path_set?(paths) do
    paths
    |> Map.from_struct()
    |> Map.delete(:platform)
    |> Map.values()
    |> Enum.all?(&valid_path?/1)
  end

  defp valid_path?(path) when is_binary(path) and byte_size(path) in 1..@maximum_path_bytes do
    String.valid?(path) and Path.type(path) == :absolute and
      not String.contains?(path, [<<0>>, "\n", "\r"])
  end

  defp valid_path?(_path), do: false

  defp valid_identity_text?(value)
       when is_binary(value) and byte_size(value) in 1..@maximum_identity_bytes do
    String.valid?(value) and not String.contains?(value, [<<0>>, "\n", "\r"])
  end

  defp valid_identity_text?(_value), do: false

  defp valid_application_name?(value) when is_binary(value) and byte_size(value) in 1..256 do
    value in @desktop_applications and
      String.valid?(value) and not String.contains?(value, [<<0>>, "\n", "\r", "\e"])
  end

  defp valid_application_name?(_value), do: false

  if @test_build do
    defp valid_uuid?(value) when is_binary(value) do
      case Ecto.UUID.cast(value) do
        {:ok, ^value} -> true
        _other -> false
      end
    end

    defp valid_uuid?(_value), do: false
  end

  defp current_platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _other -> :unsupported
    end
  end

  defp path_resolution_failed do
    StartupError.new(
      :path_resolution_failed,
      false,
      "Canonical SwarmCode paths could not be resolved safely.",
      "Use an absolute supported home/XDG path and an allowed startup mode."
    )
  end

  defp process_identity_unavailable do
    StartupError.new(
      :process_identity_unavailable,
      false,
      "The current process identity could not be established safely.",
      "Install the required platform helper or correct the local identity service."
    )
  end

  defp private_directory_failed do
    StartupError.new(
      :private_directory_failed,
      false,
      "A product-owned private directory failed ownership or mode validation.",
      "Inspect the configured paths; each product directory must be owned by this user at mode 0700."
    )
  end

  defp macos_platform_helper_unavailable do
    StartupError.new(
      :macos_platform_helper_unavailable,
      true,
      "The signed macOS desktop-detection helper is unavailable or returned invalid data.",
      "Do not start the CLI daemon; install a build containing the signed platform helper."
    )
  end

  defp desktop_active(pid, application) do
    application = safe_action_text(application)

    StartupError.new(
      :desktop_active,
      true,
      "The SwarmCode macOS desktop is already running for this user.",
      "Quit the detected #{application} desktop (PID #{pid}) before starting the CLI daemon; there is no force-unlock option."
    )
  end

  defp safe_action_text(value) when is_binary(value) do
    value
    |> String.replace(~r/[^[:alnum:] ._@:-]/u, "?")
    |> String.slice(0, 128)
  end

  defp safe_action_text(_value), do: "SwarmCode"

  defp database_fingerprint_failed do
    StartupError.new(
      :database_fingerprint_failed,
      false,
      "The canonical database path could not be fingerprinted safely.",
      "Inspect the canonical database path without replacing, deleting, or repairing it."
    )
  end

  defp database_fingerprint_changed do
    StartupError.new(
      :database_fingerprint_changed,
      false,
      "The canonical database changed while the foundation gate was running.",
      "Stop other runtimes and retry without replacing or repairing the canonical database."
    )
  end

  defp lease_failed do
    StartupError.new(
      :lease_failed,
      false,
      "The cross-application data lease could not be acquired safely.",
      "Inspect the private lease paths and stop other runtimes; never force-unlock the lease."
    )
  end

  defp migration_manifest_invalid do
    StartupError.new(
      :migration_manifest_invalid,
      false,
      "The bundled desktop migration manifest is unavailable or invalid.",
      "Reinstall the exact signed SwarmCode CLI build before accessing the canonical database."
    )
  end

  defp schema_incompatible do
    StartupError.new(
      :schema_incompatible,
      false,
      "The canonical database is incompatible with the audited read-only schema contract.",
      "Use a supported SwarmCode version or restore only from a verified backup; no migration was run."
    )
  end

  defp new_database_implementation_not_installed do
    StartupError.new(
      :new_database_implementation_not_installed,
      false,
      "Creating a canonical database is not installed in this pre-Repo milestone.",
      "Use no startup path yet; this milestone only validates pre-Repo safety infrastructure."
    )
  end

  defp migration_implementation_not_installed(%Artifact{} = artifact) do
    database = safe_path_for_action(artifact.database)
    manifest = safe_path_for_action(artifact.manifest)

    StartupError.new(
      :migration_implementation_not_installed,
      false,
      "A verified backup was retained, but migration execution is not installed in this pre-Repo milestone.",
      "Preserve the verified backup database at #{database} and manifest at #{manifest}. No migration was run."
    )
  end

  defp safe_path_for_action(path) when is_binary(path) do
    path
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "?")
    |> String.slice(0, @maximum_path_bytes)
  end

  defp safe_path_for_action(_path), do: "<unavailable>"

  defp foundation_failed do
    StartupError.new(
      :foundation_gate_failed,
      false,
      "The pre-Repo foundation gate failed closed.",
      "Inspect the installed build and local private-path configuration before retrying."
    )
  end
end
