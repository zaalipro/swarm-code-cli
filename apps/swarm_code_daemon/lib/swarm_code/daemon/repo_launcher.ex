defmodule SwarmCode.Daemon.RepoLauncher do
  @moduledoc "Owns existing-schema Foundation admission and a private guarded Repo pool."
  use GenServer, restart: :temporary
  require Logger
  alias SwarmCode.Daemon.{CrossAppLease, FoundationGate}
  alias SwarmCode.Domain.Repo

  # Guarded cleanup is bounded (pass70 B1, rel F1): at most this many 100 ms
  # attempts, one full-VM garbage collection on the way (unreachable statement
  # references in other heaps keep native handles open), then a terminal
  # `:cleanup_unconfirmed` answer instead of an endless retry.
  @cleanup_attempts 50
  @cleanup_gc_attempt 10

  def start_link(options) do
    if Keyword.keyword?(options) and
         Enum.sort(Keyword.keys(options)) == [:boot_config, :pool_size] and
         options[:pool_size] in 1..8 do
      GenServer.start_link(__MODULE__, options)
    else
      {:error, :invalid_guarded_startup}
    end
  end

  def await_ready(server, timeout \\ 30_000), do: GenServer.call(server, :await_ready, timeout)

  @doc """
  Stops the guarded Repo and settles the native lease. Answers `:ok`, or
  `{:error, :cleanup_unconfirmed}` when a native handle is still pending after
  the bounded cleanup (committed data is durable either way).
  """
  @spec close(GenServer.server()) :: :ok | {:error, :cleanup_unconfirmed}
  def close(server), do: GenServer.call(server, :close, 20_000)
  def status(server), do: GenServer.call(server, :status)
  def socket_path(server), do: GenServer.call(server, :socket_path)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       phase: :preparing,
       options: options,
       lease: nil,
       repo: nil,
       generation: nil,
       schema_status: nil,
       ready: nil,
       migration: nil,
       migration_sources: nil,
       waiters: [],
       closers: [],
       timer: nil,
       failure: nil,
       cleanup_attempts: 0
     }, {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    case FoundationGate.prepare_for_repo(state.options[:boot_config]) do
      {:ok, ready} ->
        state = %{state | lease: ready.lease, ready: ready}

        with {:ok, bootstrap} <- preflight_migrations(ready),
             {:ok, capability} <- seal_or_create(ready),
             {:ok, generation} <-
               CrossAppLease.consume(ready.lease, capability, state.options[:pool_size]) do
          case start_repo(ready.lease, generation) do
            {:ok, repo} ->
              timer = Process.send_after(self(), :pool_timeout, 15_000)

              {:noreply,
               %{
                 state
                 | repo: repo,
                   generation: generation,
                   schema_status: ready.schema.status,
                   migration_sources: bootstrap,
                   phase: :starting_repo,
                   timer: timer
               }}

            _ ->
              fail(state, :guarded_repo_start_failed)
          end
        else
          _ -> fail(state, :database_binding_changed)
        end

      {:error, error} ->
        fail(state, error)
    end
  end

  defp seal_or_create(%FoundationGate.Ready{schema: %{status: :new_database}, lease: lease}) do
    with {:ok, capability, _identity} <- CrossAppLease.create_binding(lease, "swarm_code.db"),
         do: {:ok, capability}
  end

  defp seal_or_create(%FoundationGate.Ready{
         schema: %{status: :migration_required},
         lease: lease,
         binding: binding
       }),
       do: CrossAppLease.seal_binding(lease, binding)

  defp seal_or_create(ready), do: FoundationGate.seal_ready(ready)

  defp audited_migrations do
    manifest = SwarmCode.Daemon.Schema.MigrationManifest.load!()
    directory = Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations")

    migrations =
      Enum.map(manifest.migrations, fn entry ->
        path = Path.join(directory, entry.filename)
        {:ok, %{type: :regular, size: size}} = File.lstat(path)
        true = size <= 1_048_576
        source = File.read!(path)
        # Extraction changed only the namespace. Reverse that exact adaptation
        # and compare every source byte to the audited desktop manifest.
        upstream = String.replace(source, "SwarmCode.Domain.", "SwarmCode.")
        true = Base.encode16(:crypto.hash(:sha256, upstream), case: :lower) == entry.source_sha256
        {entry.version, path, source}
      end)

    {manifest, migrations}
  end

  defp run_migrations(repo, ready, manifest, sources) do
    Repo.put_dynamic_repo(repo)

    migrations =
      Enum.map(sources, fn {version, path, source} ->
        {[{module, _beam}], _diagnostics} =
          Code.with_diagnostics([log: false], fn -> Code.compile_string(source, path) end)

        {version, module}
      end)

    Ecto.Migrator.run(Repo, migrations, :up, all: true, dynamic_repo: repo, log: false)

    SwarmCode.Daemon.Schema.Gate.check_bound(
      ready.paths.database,
      manifest,
      ready.schema.app_version,
      uid: ready.identity.uid
    )
  rescue
    _ -> {:error, :migration_failed}
  catch
    _, _ -> {:error, :migration_failed}
  end

  defp start_repo(lease, generation) do
    Repo.start_link(name: nil, guarded_repo: {lease, generation})
  catch
    _, _ -> {:error, :guarded_repo_start_failed}
  end

  @impl true
  def handle_call(:await_ready, _from, %{phase: :live} = state),
    do: {:reply, {:ok, state.repo}, state}

  def handle_call(:await_ready, _from, %{failure: failure} = state) when failure != nil,
    do: {:reply, {:error, failure}, state}

  def handle_call(:await_ready, from, state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:status, _from, state) do
    slots =
      if state.lease && Process.alive?(state.lease),
        do: CrossAppLease.binding_status(state.lease).initialized_slots,
        else: 0

    {:reply, %{phase: state.phase, initialized_slots: slots}, state}
  end

  def handle_call(:socket_path, _from, %{ready: %{paths: %{socket: socket}}} = state),
    do: {:reply, {:ok, socket}, state}

  def handle_call(:socket_path, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:close, from, state) do
    state =
      stop_repo(%{state | phase: :closing, closers: [from | state.closers], cleanup_attempts: 0})

    send(self(), :cleanup)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:guarded_pool_ready, lease, generation},
        %{lease: lease, generation: generation, phase: :starting_repo} = state
      ) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.schema_status in [:new_database, :migration_required] do
      case state.migration_sources do
        {:ok, manifest, sources} ->
          parent = self()

          {pid, monitor} =
            spawn_monitor(fn ->
              result = run_migrations(state.repo, state.ready, manifest, sources)
              send(parent, {:migration_complete, self(), result})
            end)

          timer = Process.send_after(self(), :migration_timeout, 120_000)
          {:noreply, %{state | phase: :migrating, migration: {pid, monitor}, timer: timer}}

        _ ->
          fail(state, :migration_source_invalid)
      end
    else
      publish_live(state)
    end
  end

  def handle_info(
        {:migration_complete, pid, {:ok, decision}},
        %{migration: {pid, monitor}, phase: :migrating} = state
      ) do
    Process.demonitor(monitor, [:flush])
    Process.cancel_timer(state.timer)

    case CrossAppLease.verify_promoted(state.lease, state.generation, decision) do
      :ok ->
        publish_live(%{
          state
          | migration: nil,
            ready: %{state.ready | schema: decision, binding: decision.binding},
            timer: nil
        })

      _ ->
        fail(%{state | migration: nil}, :migration_verification_failed)
    end
  end

  def handle_info({:migration_complete, pid, _}, %{migration: {pid, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    fail(%{state | migration: nil}, :migration_failed)
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{migration: {_, monitor}} = state),
    do: fail(%{state | migration: nil}, :migration_failed)

  def handle_info(:migration_timeout, %{phase: :migrating} = state),
    do: fail(state, :migration_timeout)

  def handle_info({:guarded_pool_failed, lease}, %{lease: lease} = state),
    do: fail(state, :database_binding_changed)

  def handle_info(:pool_timeout, %{phase: :starting_repo} = state),
    do: fail(state, :guarded_pool_timeout)

  def handle_info({:EXIT, pid, _}, state) when pid == state.repo or pid == state.lease do
    if state.phase in [:closing, :failed],
      do: {:noreply, state},
      else: fail(state, :database_binding_changed)
  end

  def handle_info(:cleanup, state) do
    state = stop_repo(state)
    attempt = state.cleanup_attempts + 1
    if attempt == @cleanup_gc_attempt, do: collect_garbage()

    case if(state.repo == nil, do: settle_lease(state.lease), else: {:error, :cleanup_pending}) do
      :ok ->
        Enum.each(state.closers, &GenServer.reply(&1, :ok))
        next = %{state | lease: nil, repo: nil, closers: [], cleanup_attempts: 0}
        if state.phase == :closing, do: {:stop, :normal, next}, else: {:noreply, next}

      _ when attempt >= @cleanup_attempts ->
        # The lease keeps draining on its own once its coordinator is gone.
        Logger.warning("Guarded storage closed with a native handle still pending.")
        Enum.each(state.closers, &GenServer.reply(&1, {:error, :cleanup_unconfirmed}))
        next = %{state | closers: [], cleanup_attempts: attempt}
        if state.phase == :closing, do: {:stop, :normal, next}, else: {:noreply, next}

      _ ->
        Process.send_after(self(), :cleanup, 100)
        {:noreply, %{state | cleanup_attempts: attempt}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp preflight_migrations(%{schema: %{status: :ready}}), do: {:ok, nil}

  defp preflight_migrations(_) do
    case migration_sources() do
      {:ok, _, _} = sources -> {:ok, sources}
      _ -> {:error, :migration_source_invalid}
    end
  end

  defp migration_sources do
    {manifest, migrations} = audited_migrations()
    {:ok, manifest, migrations}
  rescue
    _ -> {:error, :migration_source_invalid}
  end

  defp publish_live(state) do
    case publish_repo(state.repo) do
      :ok ->
        Enum.each(state.waiters, &GenServer.reply(&1, {:ok, state.repo}))
        {:noreply, %{state | phase: :live, waiters: [], timer: nil}}

      _ ->
        fail(state, :repo_name_in_use)
    end
  end

  defp fail(state, reason) do
    if state.timer, do: Process.cancel_timer(state.timer)
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
    state = stop_repo(%{state | phase: :failed, failure: reason, waiters: [], timer: nil})
    send(self(), :cleanup)
    {:noreply, state}
  end

  defp stop_repo(%{migration: {pid, monitor}} = state) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> :ok
    end

    stop_repo(%{state | migration: nil})
  end

  defp stop_repo(%{repo: nil} = state), do: state

  defp stop_repo(state) do
    if Process.whereis(Repo) == state.repo, do: Process.unregister(Repo)
    monitor = Process.monitor(state.repo)

    try do
      Supervisor.stop(state.repo, :shutdown, 5_000)
    catch
      :exit, _ -> Process.exit(state.repo, :kill)
    end

    receive do
      {:DOWN, ^monitor, :process, _, _} -> %{state | repo: nil}
    after
      1_000 ->
        Process.demonitor(monitor, [:flush])
        state
    end
  end

  defp publish_repo(repo) do
    if Process.whereis(Repo) == nil and Process.register(repo, Repo), do: :ok, else: :error
  rescue
    ArgumentError -> :error
  end

  # Unreachable statement or connection references in any live heap keep a
  # native SQLite handle open until that process collects. One pass at cleanup
  # time is cheap and makes the close deterministic.
  defp collect_garbage do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
  end

  defp settle_lease(nil), do: :ok

  defp settle_lease(lease) do
    if Process.alive?(lease) do
      with :ok <- CrossAppLease.close_binding(lease), do: GenServer.stop(lease, :normal, 5_000)
    else
      {:error, :cleanup_pending}
    end
  catch
    :exit, _ -> {:error, :cleanup_pending}
  end

  @impl true
  def terminate(_, state) do
    _ = stop_repo(state)
    # Native owner remains monitored by its coordinator; if this call cannot
    # settle, its DOWN path retains and drains the lease graph.
    _ = settle_lease(state.lease)
    :ok
  end

  @impl true
  def format_status(status), do: %{status | state: %{phase: status.state.phase}}
end
