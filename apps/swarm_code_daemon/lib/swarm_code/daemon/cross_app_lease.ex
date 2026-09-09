defmodule SwarmCode.Daemon.CrossAppLease do
  @moduledoc false
  use GenServer

  alias Exqlite.{DatabaseBinding, DirectoryScope, GuardedLease}
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

  def seal_binding(server, binding), do: GenServer.call(server, {:seal_binding, binding}, 15_000)

  def create_binding(server, basename),
    do: GenServer.call(server, {:create_binding, basename}, 15_000)

  def consume(server, capability, size), do: GenServer.call(server, {:consume, capability, size})
  def admit_repo(server, generation), do: GenServer.call(server, {:admit_repo, generation})
  def close_binding(server), do: GenServer.call(server, :close_binding)
  def binding_status(server), do: GenServer.call(server, :binding_status)

  def verify_promoted(server, generation, decision),
    do: GenServer.call(server, {:verify_promoted, generation, decision}, 15_000)

  def configure_connection(options, server, generation) do
    slot = Keyword.fetch!(options, :pool_index)

    case GenServer.call(server, {:authorize_slot, generation, slot}) do
      {:ok, ticket} ->
        options
        |> Keyword.put(:database_binding, ticket)
        |> Keyword.put(
          :database_binding_ready,
          {__MODULE__, :connection_ready, [server, generation, slot]}
        )

      _ ->
        raise "guarded database connection refused"
    end
  end

  def connection_ready(server, generation, slot, pid, db) when pid == self(),
    do: GenServer.call(server, {:connection_ready, generation, slot, db})

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
        binding: nil,
        capability: nil,
        generation: nil,
        repo: nil,
        pool_size: 0,
        slots: %{},
        coordinator_monitor: nil,
        coordinator: elem(opts[:startup_reply], 0),
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

  def handle_call(
        {:seal_binding, admission},
        {caller, _},
        %{coordinator: caller, binding: nil, capability: nil} = state
      ) do
    result =
      protected(fn ->
        with :ok <- verify_physical(state),
             :ok <- GuardedLease.assert_held(state.lease),
             :ok <-
               SwarmCode.Daemon.Schema.Gate.verify_binding(
                 state.paths.database,
                 admission,
                 state.uid
               ),
             {:regular, device, _minor, inode, uid} <- admission.identity,
             true <- uid == state.uid and Path.basename(state.paths.database) == "swarm_code.db" do
          DatabaseBinding.acquire(state.lease, {device, inode, uid}, "swarm_code.db")
        end
      end)

    case result do
      {:ok, binding} ->
        capability = make_ref()
        monitor = Process.monitor(caller)
        Process.unlink(caller)

        {:reply, {:ok, capability},
         %{
           state
           | binding: binding,
             capability: capability,
             phase: :probed,
             coordinator_monitor: monitor
         }}

      _ ->
        {:reply, {:error, :database_binding_changed}, state}
    end
  end

  def handle_call({:consume, capability, size}, {caller, _}, state) do
    if caller == state.coordinator and state.phase == :probed and
         is_reference(capability) and capability == state.capability and size in 1..8 do
      generation = make_ref()

      {:reply, {:ok, generation},
       %{state | capability: nil, generation: generation, pool_size: size, phase: :starting_repo}}
    else
      {:reply, {:error, :invalid_ready_capability}, state}
    end
  end

  def handle_call({:admit_repo, generation}, {caller, _}, state) do
    if state.phase == :starting_repo and state.repo == nil and generation == state.generation and
         linked_ancestor?(caller, state.coordinator) do
      opts = [
        name: nil,
        log: false,
        pool_size: state.pool_size,
        pool_count: 1,
        journal_mode: :wal,
        temp_store: :memory,
        synchronous: :full,
        foreign_keys: :on,
        busy_timeout: 2_000,
        timeout: 5_000,
        queue_target: 50,
        idle_interval: 1_000,
        configure: {__MODULE__, :configure_connection, [self(), generation]},
        database_binding: :requires_slot_authorization,
        telemetry_prefix: [:swarm_code, :guarded_repo]
      ]

      {:reply, {:ok, opts}, %{state | repo: caller}}
    else
      {:reply, {:error, :invalid_ready_capability}, state}
    end
  end

  def handle_call({:authorize_slot, generation, slot}, {caller, _}, state) do
    existing = state.slots[slot]
    replaceable = existing == nil or existing.pid == caller or not Process.alive?(existing.pid)

    if state.phase in [:starting_repo, :live] and generation == state.generation and
         is_integer(slot) and slot in 1..state.pool_size and replaceable and
         connection_member?(caller, state.repo, slot) do
      case protected(fn ->
             with :ok <- verify_physical(state),
                  :ok <- DatabaseBinding.assert_held(state.binding),
                  do: DatabaseBinding.authorize(state.binding, caller)
           end) do
        {:ok, ticket} ->
          entry = %{pid: caller, ready: false, db: nil}
          {:reply, {:ok, ticket}, %{state | slots: Map.put(state.slots, slot, entry)}}

        _ ->
          fence_reply(state)
      end
    else
      {:reply, {:error, :invalid_connection_member}, state}
    end
  end

  def handle_call({:connection_ready, generation, slot, db}, {caller, _}, state) do
    if state.phase in [:starting_repo, :live] and generation == state.generation and
         match?(%{pid: ^caller, ready: false}, state.slots[slot]) and
         connection_member?(caller, state.repo, slot) do
      case protected(fn ->
             with :ok <- DatabaseBinding.assert_connection(db),
                  do: DatabaseBinding.assert_held(state.binding)
           end) do
        :ok ->
          slots = Map.put(state.slots, slot, %{pid: caller, ready: true, db: db})

          ready =
            map_size(slots) == state.pool_size and
              Enum.all?(slots, fn {_, item} -> item.ready end)

          if ready, do: send(state.coordinator, {:guarded_pool_ready, self(), generation})
          {:reply, :ok, %{state | slots: slots, phase: if(ready, do: :live, else: state.phase)}}

        _ ->
          fence_reply(state)
      end
    else
      {:reply, {:error, :invalid_connection_member}, state}
    end
  end

  def handle_call(
        {:verify_promoted, generation,
         %SwarmCode.Daemon.Schema.Gate.Decision{status: :ready, pending: []} = decision},
        {caller, _},
        state
      ) do
    if caller == state.coordinator and generation == state.generation and state.phase == :live do
      result =
        protected(fn ->
          with :ok <- DatabaseBinding.assert_held(state.binding),
               :ok <-
                 SwarmCode.Daemon.Schema.Gate.verify_binding(
                   state.paths.database,
                   decision.binding,
                   state.uid
                 ),
               do: DatabaseBinding.assert_held(state.binding)
        end)

      {:reply, result, state}
    else
      {:reply, {:error, :database_binding_changed}, state}
    end
  end

  def handle_call({:verify_promoted, _, _}, _from, state),
    do: {:reply, {:error, :database_binding_changed}, state}

  def handle_call(:binding_status, _from, state) do
    ready = Enum.count(state.slots, fn {_, slot} -> slot.ready and Process.alive?(slot.pid) end)
    {:reply, %{phase: state.phase, initialized_slots: ready}, state}
  end

  def handle_call(:close_binding, {caller, _}, %{coordinator: caller} = state) do
    case protected(fn -> close_native_binding(state) end) do
      :ok -> {:reply, :ok, %{state | binding: nil, phase: :binding_closed, slots: %{}}}
      _ -> {:reply, {:error, :cleanup_pending}, %{state | phase: :closing}}
    end
  end

  def handle_call({:seal_binding, _}, _from, state),
    do: {:reply, {:error, :invalid_ready_capability}, state}

  def handle_call(
        {:create_binding, basename},
        {caller, _},
        %{coordinator: caller, binding: nil, capability: nil} = state
      )
      when basename == "swarm_code.db" do
    result =
      protected(fn ->
        with true <- Path.basename(state.paths.database) == basename,
             :ok <-
               SwarmCode.Daemon.Platform.DatabaseFingerprint.verify_path_or_absent(
                 state.paths.database,
                 state.record.database_fingerprint
               ),
             :ok <- verify_physical(state) do
          DatabaseBinding.create(state.lease, basename)
        end
      end)

    case result do
      {:ok, binding, identity} ->
        capability = make_ref()
        monitor = Process.monitor(caller)
        Process.unlink(caller)

        state = %{
          state
          | binding: binding,
            capability: capability,
            coordinator_monitor: monitor,
            phase: :probed
        }

        case refresh_created_fingerprint(state) do
          {:ok, next} -> {:reply, {:ok, capability, identity}, next}
          _ -> {:reply, {:error, :database_binding_changed}, %{state | phase: :failed}}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:create_binding, _}, _from, state),
    do: {:reply, {:error, :invalid_ready_capability}, state}

  def handle_call(:close_binding, _from, state),
    do: {:reply, {:error, :invalid_ready_capability}, state}

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

  defp refresh_created_fingerprint(state) do
    with :ok <- DatabaseBinding.assert_held(state.binding),
         {:ok, fingerprint} <-
           SwarmCode.Daemon.Platform.DatabaseFingerprint.for_path(state.paths.database) do
      record = %{state.record | database_fingerprint: fingerprint}

      with :ok <-
             AtomicReplace.write(
               state.paths.owner_record,
               [Jason.encode_to_iodata!(OwnerRecord.to_map(record)), "\n"],
               mode: 0o600
             ),
           :ok <- DatabaseBinding.assert_held(state.binding) do
        {:ok, %{state | record: record}}
      end
    end
  end

  defp cleanup(state) do
    case protected(fn -> close_native_binding(state) end) do
      :ok -> cleanup_lease(state)
      _ -> {:error, :native_cleanup_unconfirmed}
    end
  end

  defp close_native_binding(%{binding: nil}), do: :ok

  defp close_native_binding(state) do
    if state.repo == nil or not Process.alive?(state.repo) do
      Enum.each(state.slots, fn {_, slot} ->
        if slot.db, do: Exqlite.Sqlite3.close(slot.db)
      end)
    end

    with 0 <- DatabaseBinding.connections(state.binding), do: DatabaseBinding.close(state.binding)
  end

  defp fence_reply(state) do
    send(state.coordinator, {:guarded_pool_failed, self()})
    {:reply, {:error, :database_binding_changed}, %{state | phase: :failed}}
  end

  # DBConnection runs connection supervisors under its global watcher, not
  # beneath Repo. Match the real supervisor child ID, owner pool and slot;
  # reaching Repo through arbitrary process links is not membership proof.
  defp connection_member?(pid, repo, slot) when is_pid(repo) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         [supervisor | _] when is_pid(supervisor) <- Keyword.get(dictionary, :"$ancestors"),
         children <- Supervisor.which_children(supervisor),
         {{Exqlite.Connection, pool, ^slot}, ^pid, :worker, _} <-
           Enum.find(children, fn {_, child, _, _} -> child == pid end),
         true <-
           Enum.any?(Supervisor.which_children(repo), fn {_, child, _, _} -> child == pool end) do
      true
    else
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp connection_member?(_, _, _), do: false

  defp linked_ancestor?(pid, target) when is_pid(target) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         [^target | _] <- Keyword.get(dictionary, :"$ancestors"),
         {:links, links} <- Process.info(pid, :links) do
      target in links
    else
      _ -> false
    end
  end

  defp linked_ancestor?(_, _), do: false

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{coordinator_monitor: ref} = state) do
    if is_pid(state.repo), do: Process.exit(state.repo, :kill)
    send(self(), :drain_binding)
    {:noreply, %{state | phase: :closing}}
  end

  def handle_info(:drain_binding, state) do
    case protected(fn -> close_native_binding(state) end) do
      :ok ->
        {:stop, :normal, %{state | binding: nil}}

      _ ->
        Process.send_after(self(), :drain_binding, 100)
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp cleanup_lease(state) do
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
