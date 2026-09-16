defmodule SwarmCode.Development.PlainSession do
  @moduledoc false

  alias SwarmCode.Daemon.FoundationGate.BootConfig
  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Daemon.Service.{PersistedBackend, SessionConfiguration, SessionSelection}
  alias SwarmCodeCLI.Plain.{Options, Session}
  alias SwarmCodeCLI.UI.DataSource.Daemon

  def run do
    root = System.get_env("SWARM_PROJECT_ROOT") || File.cwd!()
    unless File.dir?(root), do: Mix.raise("SWARM_PROJECT_ROOT must be an existing directory")

    for app <- [:req, :swarm_code_core, :swarm_code_cli, :swarm_code_daemon],
        do: unwrap!(Application.ensure_all_started(app), "application startup")

    # The daemon resolves a provider kind through this registry and answers
    # "unknown provider kind" for anything absent; the saved-session launcher
    # has always registered both adapters, and this one must too or every
    # send fails before it reaches the network.
    Application.put_env(
      :swarm_code_daemon,
      :llm_providers,
      Application.get_env(:swarm_code_daemon, :llm_providers, %{})
      |> Map.merge(%{
        "openai_compatible" => SwarmCode.Domain.LLM.OpenAI,
        "anthropic" => SwarmCode.Domain.LLM.Anthropic
      })
    )

    boot = BootConfig.canonical(platform(), System.user_home!(), version())
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 4)
    Process.unlink(launcher)

    try do
      unwrap!(RepoLauncher.await_ready(launcher, 120_000), "guarded database startup")

      session =
        query_worker(fn ->
          selected =
            unwrap!(SessionSelection.open(root, selection_options()), "session selection")

          unwrap!(
            SessionConfiguration.prepare(selected, System.get_env()),
            "provider configuration"
          )
        end)

      run_session(session)
    after
      close_owned_runtime(launcher)
    end
  end

  defp run_session(session) do
    source_epoch = Ecto.UUID.generate()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {dir, stat} = private_directory!()

    supervisor =
      unwrap!(
        Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0),
        "session supervisor"
      )

    Process.unlink(supervisor)

    try do
      socket = Path.join(dir, "s")

      backend =
        child!(supervisor, PersistedBackend,
          mode: :persisted,
          repo: SwarmCode.Domain.Repo,
          project_root: session.project.root_path,
          project_id: session.project.id,
          conversation_id: session.conversation.id,
          source_epoch: source_epoch
        )

      child!(supervisor, SwarmCode.Daemon.Service,
        socket_path: socket,
        nonce: nonce,
        source_epoch: source_epoch,
        backend: backend
      )

      source =
        child!(supervisor, Daemon, socket_path: socket, nonce: nonce, source_epoch: source_epoch)

      {:ok, plain} =
        Session.start_link(
          data_source: source,
          source_epoch: source_epoch,
          conversation_id: session.conversation.id,
          now: System.system_time(:millisecond),
          input: :standard_io,
          output: :standard_io,
          error: :standard_error,
          options: %Options{
            format:
              if(System.get_env("SWARM_PLAIN_FORMAT") == "--ndjson", do: :ndjson, else: :text),
            banner: :saved,
            detached_runs?: false
          },
          observer: self()
        )

      ref = Process.monitor(plain)

      receive do
        {:plain_session, ^plain, {:closed, reason}} ->
          if reason in [:source_unavailable, :binding_failed, :watch_failed, :input_failed],
            do: Mix.raise("Plain session failed: #{reason}")

        {:DOWN, ^ref, :process, ^plain, reason} ->
          Mix.raise("Plain session failed: #{inspect(reason)}")
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 15_000)
      remove_private_directory(dir, stat)
    end
  end

  defp selection_options do
    case System.get_env("SWARM_CONVERSATION") do
      nil -> [conversation: :latest]
      "latest" -> [conversation: :latest]
      "new" -> [conversation: :new]
      id -> [conversation: id]
    end
  end

  defp query_worker(fun) do
    task = Task.async(fun)
    Task.await(task, 120_000)
  catch
    kind, reason -> Mix.raise("database query failed: #{kind} #{inspect(reason)}")
  end

  defp child!(supervisor, module, opts) do
    spec = {module, opts}
    unwrap!(Supervisor.start_child(supervisor, spec), "#{inspect(module)} startup")
  end

  defp unwrap!({:ok, value}, _), do: value
  defp unwrap!(:ok, _), do: :ok
  defp unwrap!({:error, reason}, label), do: Mix.raise("#{label} failed: #{inspect(reason)}")
  defp unwrap!(value, _), do: value

  defp platform, do: if(match?({:unix, :darwin}, :os.type()), do: :macos, else: :linux)
  defp version, do: Application.spec(:swarm_code_daemon, :vsn) |> to_string()

  defp private_directory! do
    parent = Path.join(System.tmp_dir!(), "swarm-code-cli")
    File.mkdir_p!(parent)
    dir = Path.join(parent, "plain-#{System.pid()}-#{System.unique_integer([:positive])}")
    :ok = File.mkdir!(dir)
    :ok = File.chmod(dir, 0o700)
    {:ok, stat} = File.lstat(dir)
    {dir, stat}
  end

  defp remove_private_directory(dir, stat) do
    case File.lstat(dir) do
      {:ok, current}
      when current.inode == stat.inode and current.major_device == stat.major_device ->
        File.rmdir(dir)

      _ ->
        :ok
    end
  end

  defp close_owned_runtime(launcher) do
    if Process.whereis(SwarmCode.Domain.Registry) do
      query_worker(fn -> SwarmCode.Domain.Engine.stop_all() end)
      Application.stop(:swarm_code_daemon)
    end

    if Process.alive?(launcher) do
      case RepoLauncher.close(launcher) do
        :ok ->
          IO.puts(:stderr, "PLAIN SESSION — closed; guarded storage released.")

        {:error, {:cleanup_pending, _}} ->
          monitor = Process.monitor(launcher)

          receive do
            {:DOWN, ^monitor, :process, ^launcher, :normal} ->
              IO.puts(:stderr, "PLAIN SESSION — pending cleanup released.")
          after
            10_000 -> Mix.raise("Guarded storage cleanup remains pending")
          end

        other ->
          Mix.raise("Guarded storage cleanup failed: #{inspect(other)}")
      end
    end
  catch
    _, _ -> :ok
  end
end

SwarmCode.Development.PlainSession.run()
