defmodule SwarmCodeCLI.Release.PersistedSession do
  @moduledoc false
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.FoundationGate.BootConfig,
              SwarmCode.Daemon.RepoLauncher,
              SwarmCode.Daemon.Service.SessionConfiguration,
              SwarmCode.Daemon.Service.SessionSelection,
              SwarmCode.Domain.Engine,
              Ecto.UUID
            ]}
  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Daemon.FoundationGate.BootConfig
  alias SwarmCode.Daemon.Service.{PersistedBackend, SessionConfiguration, SessionSelection}
  alias SwarmCodeCLI.Companion
  alias SwarmCodeCLI.UI.{Capabilities, Init, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.Daemon
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

  def run, do: launch(nil)

  # A trusted test runner passes this directly. No environment variable or
  # production command-line option can select an alternate database path.
  def run_for_test(boot_config) do
    unless mix_test?(), do: raise_error("Test boot configuration requires MIX_ENV=test")
    launch(boot_config)
  end

  defp launch(test_boot) do
    unless System.argv() == [], do: raise_error("Saved session accepts no command-line arguments")

    unless (release_tui?() or :init.get_argument(:noinput) != :error) and
             :prim_tty.isatty(:stdin) == true and
             :prim_tty.isatty(:stdout) == true and
             System.get_env("TERM") not in [nil, "", "dumb"],
           do: raise_error("SAVED DEV SESSION requires a real terminal and -noinput")

    root = System.get_env("SWARM_PROJECT_ROOT") || File.cwd!()
    unless File.dir?(root), do: raise_error("SWARM_PROJECT_ROOT must be an existing directory")
    options = selection_options!(System.get_env("SWARM_CONVERSATION"))

    executable =
      System.get_env("SWARM_TERMINAL_PORT") ||
        Path.expand("../../_build/terminal-port/debug/swarm-terminal-port", __DIR__)

    unless File.regular?(executable),
      do: raise_error("Build the guarded terminal port first: scripts/dev/check_terminal_port.sh")

    for app <- [:req, :swarm_code_core, :swarm_code_cli, :swarm_code_daemon],
        do: unwrap!(Application.ensure_all_started(app), "application startup")

    Application.put_env(
      :swarm_code_daemon,
      :llm_providers,
      Application.get_env(:swarm_code_daemon, :llm_providers, %{})
      |> Map.merge(%{
        "openai_compatible" => SwarmCode.Domain.LLM.OpenAI,
        "anthropic" => SwarmCode.Domain.LLM.Anthropic
      })
    )

    version = Application.spec(:swarm_code_daemon, :vsn) |> to_string()
    platform = if match?({:unix, :darwin}, :os.type()), do: :macos, else: :linux
    boot = test_boot || BootConfig.canonical(platform, System.user_home!(), version)
    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 4)
    Process.unlink(launcher)

    try do
      unwrap!(RepoLauncher.await_ready(launcher, 120_000), "guarded database startup")
      # SQL callers are short-lived. Returning plain session structs does not
      # retain native statement resources in the launcher while the TUI runs.
      session =
        query_worker(fn ->
          session = unwrap!(SessionSelection.open(root, options), "session selection")

          unwrap!(
            SessionConfiguration.prepare(session, System.get_env()),
            "provider configuration"
          )
        end)

      run_ui(session, executable)
    after
      close_owned_runtime(launcher)
    end
  end

  defp run_ui(session, executable) do
    {dir, stat} = private_directory!()
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)
    Process.unlink(supervisor)

    try do
      source_epoch = Ecto.UUID.generate()
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      conversation_id = session.conversation.id

      backend =
        child!(supervisor, PersistedBackend,
          mode: :persisted,
          repo: SwarmCode.Domain.Repo,
          project_root: session.project.root_path,
          project_id: session.project.id,
          conversation_id: conversation_id,
          source_epoch: source_epoch
        )

      path = Path.join(dir, "s")

      child!(supervisor, SwarmCode.Daemon.Service,
        socket_path: path,
        nonce: nonce,
        source_epoch: source_epoch,
        backend: backend
      )

      source =
        child!(supervisor, Daemon, socket_path: path, nonce: nonce, source_epoch: source_epoch)

      caps = %Capabilities{
        size: %Size{columns: 80, rows: 24},
        stdin_tty?: true,
        stdout_tty?: true,
        color_mode: color_mode()
      }

      init = %Init{
        focus: "composer",
        size: caps.size,
        capabilities: caps,
        source_epoch: source_epoch,
        destination: {:conversation, conversation_id},
        banner: :persisted_banner,
        now: System.system_time(:millisecond),
        keymap: Init.keymap_from_env()
      }

      runtime =
        child!(supervisor, SessionRuntime,
          init: init,
          data_source: source,
          frame_ms: 33,
          close_ms: 3000,
          instruction_sink: self()
        )

      start_companion(supervisor, runtime, Path.basename(session.project.root_path))
      IO.puts(:stderr, "SAVED DEV SESSION — conversation #{conversation_id}; q stops owned runs.")

      owner =
        child!(supervisor, Owner,
          runtime: runtime,
          capabilities: caps,
          flags: %{alternate?: true, focus?: true, paste?: true},
          executable: executable
        )

      owner_monitor = Process.monitor(owner)
      supervisor_monitor = Process.monitor(supervisor)

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, :normal} ->
          :ok

        {:DOWN, ^owner_monitor, :process, ^owner, _} ->
          raise_error("Saved terminal failed")

        {:DOWN, ^supervisor_monitor, :process, ^supervisor, _} ->
          raise_error("Saved session failed")
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 15_000)

      case File.lstat(dir) do
        {:ok, current}
        when current.inode == stat.inode and
               current.major_device == stat.major_device and current.type == :directory ->
          File.rmdir(dir)

        _ ->
          :ok
      end
    end
  end

  # The visual companion mirrors this session on a loopback port; the palette's
  # "Open visual companion" shows the URL. SWARM_COMPANION=0 leaves it out, and
  # the URL is never printed here because it carries the session token.
  defp start_companion(supervisor, runtime, project) do
    if System.get_env("SWARM_COMPANION") != "0" do
      companion = child!(supervisor, Companion, runtime: runtime, project: project)
      SessionRuntime.attach_companion(runtime, Companion.sink(companion))
    end
  end

  defp close_owned_runtime(launcher) do
    if Process.whereis(SwarmCode.Domain.Registry) do
      query_worker(fn -> SwarmCode.Domain.Engine.stop_all() end)
      # This process owns the development VM runtime. Stop agents, tasks,
      # research and caches before retiring the guarded storage pool.
      Application.stop(:swarm_code_daemon)
    end

    if Process.alive?(launcher) do
      case RepoLauncher.close(launcher) do
        :ok ->
          :ok

        {:error, :cleanup_unconfirmed} ->
          IO.puts(
            :stderr,
            "SwarmCode closed its database with one native handle still pending; saved data is safe."
          )

        other ->
          raise_error("Guarded storage cleanup failed: #{inspect(other)}")
      end
    end
  end

  defp query_worker(fun), do: fun |> Task.async() |> Task.await(30_000)
  defp selection_options!(nil), do: [conversation: :latest]
  defp selection_options!("latest"), do: [conversation: :latest]
  defp selection_options!("new"), do: [conversation: :new]

  defp selection_options!(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> [conversation: id]
      _ -> raise_error("SWARM_CONVERSATION must be latest, new, or a UUID")
    end
  end

  defp unwrap!({:ok, value}, _label), do: value

  defp unwrap!({:error, reason}, label),
    do: raise_error("Saved #{label} failed: #{inspect(reason)}")

  defp child!(supervisor, module, options),
    do:
      unwrap!(
        Supervisor.start_child(
          supervisor,
          Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 10_000)
        ),
        "component startup"
      )

  defp private_directory! do
    dir =
      Path.join(
        "/tmp",
        "scl-p-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        {dir, File.lstat!(dir)}

      {:error, :eexist} ->
        private_directory!()

      _ ->
        raise_error("Unable to create saved-session socket directory")
    end
  end

  defp mix_test? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp release_tui?, do: System.get_env("SWARM_RELEASE_TUI") == "1"

  defp raise_error(message), do: raise(RuntimeError, message)

  defp color_mode do
    cond do
      System.get_env("NO_COLOR") != nil -> :monochrome
      System.get_env("COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      String.contains?(System.get_env("TERM") || "", "256color") -> :ansi256
      true -> :ansi16
    end
  end
end
