defmodule SwarmCode.Daemon.CrossAppLease do
  @moduledoc false
  use GenServer

  alias Exqlite.{DirectoryScope, GuardedLease}
  alias SwarmCode.Daemon.CrossAppLease.OwnerRecord
  alias SwarmCode.Daemon.Files.AtomicReplace
  alias SwarmCode.Daemon.Platform.{PathSet, PhysicalBootPaths, ProcessIdentity}
  alias SwarmCode.Daemon.StartupError

  @test_build Mix.env() == :test
  @maximum_owner_bytes 32 * 1_024
  @required [:paths, :identity, :database_fingerprint, :schema_contract, :app_version]
  @allowed @required ++
             [:name] ++
             if(@test_build,
               do: [:cleanup_barrier, :test_open_hook, :owner_atomic_replace_opts],
               else: []
             )

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      significant: true
    }
  end

  def start_link(opts) do
    # Validate before inserting the private reply key, so duplicates and a
    # caller-forged startup channel cannot be erased by Keyword.put/3.
    with :ok <- validate_options(opts) do
      startup_ref = make_ref()
      init_opts = Keyword.put(opts, :startup_reply, {self(), startup_ref})

      case GenServer.start_link(__MODULE__, init_opts, Keyword.take(opts, [:name])) do
        {:error, :normal} ->
          receive do
            {^startup_ref, %StartupError{} = error} -> {:error, error}
          end

        result ->
          result
      end
    else
      _error -> {:error, lease_failed()}
    end
  end

  @spec owner(GenServer.server()) :: OwnerRecord.t()
  def owner(server), do: GenServer.call(server, :owner)

  @spec assert_held(GenServer.server()) :: :ok | {:error, StartupError.t()}
  def assert_held(server), do: GenServer.call(server, :assert_held)

  @impl true
  def init(opts) do
    case protected(fn -> prepare_owner(opts) end) do
      {:ok, state} -> {:ok, state}
      {:failed, reason, clean?} -> stop_with_error(opts, admission_error(reason, clean?))
      {:error, _reason} -> stop_with_error(opts, lease_failed())
    end
  end

  defp prepare_owner(opts) do
    record =
      opts
      |> Keyword.take([:identity, :schema_contract, :app_version, :database_fingerprint])
      |> Keyword.put(:socket_path, opts[:paths].socket)
      |> OwnerRecord.new()

    with {:ok, physical} <- PhysicalBootPaths.admit(opts[:paths]),
         {:ok, scope} <- DirectoryScope.new() do
      state = %{
        scope: scope,
        runtime_dir: nil,
        data_dir: nil,
        lease: nil,
        paths: opts[:paths],
        physical: physical,
        uid: opts[:identity].uid,
        record: record,
        phase: :admitting,
        cleanup_barrier: Keyword.get(opts, :cleanup_barrier, fn -> :ok end)
      }

      case protected(fn -> acquire_in_owner(state, opts) end) do
        {:ok, _state} = success -> success
        {:failed, _reason, _clean?} = failure -> failure
        {:error, reason} -> {:failed, reason, cleanup(state) == :ok}
        _other -> {:failed, :operation_failed, cleanup(state) == :ok}
      end
    end
  end

  defp acquire_in_owner(state, opts) do
    with {:ok, runtime} <- DirectoryScope.open_root(state.scope, state.physical.runtime),
         {:ok, data} <- DirectoryScope.open_root(state.scope, state.physical.data),
         :ok <- verify_uid(runtime, state.uid),
         :ok <- verify_uid(data, state.uid),
         :ok <- verify_physical(state),
         :ok <- DirectoryScope.lock(state.scope, runtime, data),
         :ok <- invoke_open_hook(Keyword.get(opts, :test_open_hook), state.paths.lease),
         {:ok, lease} <- GuardedLease.acquire(state.scope) do
      state = %{state | runtime_dir: runtime, data_dir: data, lease: lease}

      # Once a lease child exists, all failures drain it before its directory
      # scope. The scope must never be closed beneath an active SQLite child.
      case protected(fn -> publish_owner(state, opts) end) do
        {:ok, _state} = success -> success
        {:error, reason} -> {:failed, reason, cleanup(state) == :ok}
      end
    end
  end

  defp publish_owner(state, opts) do
    atomic_opts = Keyword.put(Keyword.get(opts, :owner_atomic_replace_opts, []), :mode, 0o600)
    contents = [Jason.encode_to_iodata!(OwnerRecord.to_map(state.record)), "\n"]

    with :ok <- GuardedLease.assert_held(state.lease),
         {:ok, {:regular, _device, _inode, uid, 0o600}} <- GuardedLease.identity(state.lease),
         true <- uid == state.uid,
         :ok <- AtomicReplace.write(state.paths.owner_record, contents, atomic_opts),
         :ok <- verify_physical(state),
         :ok <- GuardedLease.assert_held(state.lease) do
      {:ok, %{state | phase: :held}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :identity_mismatch}
    end
  end

  @impl true
  def handle_call(:owner, _from, state), do: {:reply, state.record, state}

  @impl true
  def handle_call(:assert_held, _from, state) do
    case protected(fn ->
           with :ok <- verify_physical(state), do: GuardedLease.assert_held(state.lease)
         end) do
      :ok -> {:reply, :ok, state}
      _error -> {:stop, :normal, {:error, lease_failed()}, %{state | phase: :fenced}}
    end
  end

  @impl true
  def format_status(%{state: state} = status) do
    # OTP status/crash diagnostics are observations, never resource handoff.
    %{status | state: %{phase: state.phase}}
  end

  @impl true
  def terminate(_reason, state) do
    case cleanup(state) do
      :ok -> :ok
      {:error, _reason} -> exit(:native_lease_cleanup_unconfirmed)
    end
  end

  defp cleanup(state) do
    # Each operation is protected independently: publication/removal or a test
    # callback exception cannot skip either native close. Every result counts.
    record_result =
      protected(fn ->
        remove_if_same_nonce(state.paths.owner_record, state.record.lease_nonce)
      end)

    barrier_result = protected(fn -> state.cleanup_barrier.() end)

    lease_result =
      protected(fn -> if state.lease, do: GuardedLease.close(state.lease), else: :ok end)

    scope_result = protected(fn -> DirectoryScope.close(state.scope) end)

    if Enum.all?([record_result, barrier_result, lease_result, scope_result], &(&1 == :ok)),
      do: :ok,
      else: {:error, :native_cleanup_unconfirmed}
  end

  defp verify_uid(directory, uid) do
    case DirectoryScope.identity(directory) do
      {:ok, {:directory, _device, _inode, ^uid, 0o700}} -> :ok
      _other -> {:error, :identity_mismatch}
    end
  end

  defp verify_physical(state) do
    case PhysicalBootPaths.admit(state.paths) do
      {:ok, physical} when physical == state.physical -> :ok
      _other -> {:error, :physical_path_changed}
    end
  end

  if @test_build do
    defp invoke_open_hook(nil, _path), do: :ok

    defp invoke_open_hook(hook, path) when is_function(hook, 2),
      do: hook.(:before_native_acquire, path)

    defp invoke_open_hook(hook, _path) when is_function(hook, 1),
      do: hook.(:before_native_acquire)
  else
    defp invoke_open_hook(nil, _path), do: :ok
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      if keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @allowed)) and
           Enum.all?(@required, &Keyword.has_key?(opts, &1)) and
           valid_paths?(opts[:paths]) and match?(%ProcessIdentity{}, opts[:identity]) and
           valid_test_options?(opts) do
        # OwnerRecord validates the five semantic values without accepting the
        # resource-owner startup options as diagnostic authority.
        case protected(fn ->
               opts
               |> Keyword.take([:identity, :schema_contract, :app_version, :database_fingerprint])
               |> Keyword.put(:socket_path, opts[:paths].socket)
               |> OwnerRecord.new()
             end) do
          %OwnerRecord{} -> :ok
          _other -> {:error, :invalid_options}
        end
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_options(_opts), do: {:error, :invalid_options}

  defp valid_paths?(%PathSet{} = paths) do
    fields = Map.from_struct(paths)

    Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(PathSet.__struct__()) -- [:__struct__]) and
      paths.platform in [:macos, :linux] and
      Enum.all?(Map.values(Map.delete(fields, :platform)), &valid_path?/1) and
      paths.runtime != paths.data and Path.dirname(paths.database) == paths.data and
      paths.lease == Path.join(paths.data, "instance_lease.db") and
      paths.owner_record == Path.join(paths.data, "instance_owner.json") and
      paths.socket == Path.join(paths.runtime, "daemon.sock") and
      paths.socket_metadata == Path.join(paths.runtime, "daemon.json") and
      paths.backups == Path.join(paths.data, "backups")
  rescue
    _error -> false
  end

  defp valid_paths?(_paths), do: false

  defp valid_path?(path) when is_binary(path) do
    byte_size(path) in 1..16_384 and String.valid?(path) and
      not String.contains?(path, [<<0>>, "\n", "\r"]) and
      Path.type(path) == :absolute and Path.expand(path) == path
  end

  defp valid_path?(_path), do: false

  defp valid_test_options?(opts) do
    (not Keyword.has_key?(opts, :cleanup_barrier) or is_function(opts[:cleanup_barrier], 0)) and
      (not Keyword.has_key?(opts, :test_open_hook) or is_function(opts[:test_open_hook], 1) or
         is_function(opts[:test_open_hook], 2)) and
      (not Keyword.has_key?(opts, :owner_atomic_replace_opts) or
         (is_list(opts[:owner_atomic_replace_opts]) and
            Keyword.keyword?(opts[:owner_atomic_replace_opts])))
  end

  # Native exceptions and hook failures are reduced to a bounded local code;
  # paths, SQL errors and exception text never cross the startup boundary.
  defp protected(function) do
    function.()
  rescue
    _error -> {:error, :operation_failed}
  catch
    _kind, _reason -> {:error, :operation_failed}
  end

  defp remove_if_same_nonce(path, nonce) do
    with {:ok, %File.Stat{type: :regular} = before} <- File.lstat(path),
         {:ok, contents} <- read_bounded(path),
         {:ok, %{"lease_nonce" => ^nonce}} <- Jason.decode(contents),
         {:ok, %File.Stat{type: :regular} = after_read} <- File.lstat(path),
         true <-
           {before.major_device, before.inode} == {after_read.major_device, after_read.inode} do
      File.rm(path)
    else
      _other -> :ok
    end
  end

  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @maximum_owner_bytes + 1) do
            contents when is_binary(contents) and byte_size(contents) <= @maximum_owner_bytes ->
              {:ok, contents}

            _other ->
              {:error, :owner_record_too_large}
          end
        after
          _ = File.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp admission_error(reason, clean?) do
    error =
      if reason in [:foundation_lock_held, :lease_held] do
        StartupError.new(
          :data_lease_held,
          true,
          "The canonical data lease is held by another runtime.",
          "Stop the owning runtime; never delete or force-unlock the lease."
        )
      else
        lease_failed()
      end

    if clean?,
      do: error,
      else: %{
        error
        | message:
            error.message <> " Native cleanup is abnormal; native settlement is unconfirmed."
      }
  end

  defp stop_with_error(opts, error) do
    {caller, startup_ref} = Keyword.fetch!(opts, :startup_reply)
    send(caller, {startup_ref, error})
    {:stop, :normal}
  end

  defp lease_failed do
    StartupError.new(
      :lease_failed,
      false,
      "The canonical data lease could not be safely acquired or verified.",
      "Inspect private path permissions and native lease diagnostics."
    )
  end
end
