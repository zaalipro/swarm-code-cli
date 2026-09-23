defmodule SwarmCode.Development.LiveSession do
  @moduledoc false
  alias SwarmCode.Daemon.Runtime.Configuration
  alias SwarmCode.Daemon.Service
  alias SwarmCode.Daemon.Service.LiveBackend
  alias SwarmCodeCLI.Companion
  alias SwarmCodeCLI.UI.{Capabilities, Init, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.Daemon
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

  def run do
    unless System.argv() == [],
      do: Mix.raise("The live launcher accepts configuration through environment variables only")

    unless :init.get_argument(:noinput) != :error,
      do: Mix.raise("Use scripts/dev/run_live_session.sh (requires -noinput)")

    unless :prim_tty.isatty(:stdin) == true and :prim_tty.isatty(:stdout) == true and
             System.get_env("TERM") not in [nil, "", "dumb"],
           do: Mix.raise("DEVELOPMENT LIVE SESSION requires a real terminal (TTY)")

    root = System.get_env("SWARM_PROJECT_ROOT") || File.cwd!()

    provider_url =
      case System.get_env("SWARM_PROVIDER", "openai") do
        "anthropic" -> System.get_env("SWARM_BASE_URL") || System.get_env("ANTHROPIC_BASE_URL")
        _ -> System.get_env("SWARM_BASE_URL") || System.get_env("OPENAI_BASE_URL")
      end

    unless is_binary(provider_url) and String.trim(provider_url) != "" do
      Mix.raise(
        "DEVELOPMENT LIVE SESSION requires an explicit base URL for the selected provider"
      )
    end

    config =
      case Configuration.from_env(System.get_env(), root) do
        {:ok, options} -> options
        {:error, reason} -> Mix.raise("Invalid live configuration: #{reason}")
      end

    executable = Path.expand("../../_build/terminal-port/debug/swarm-terminal-port", __DIR__)

    unless File.regular?(executable),
      do: Mix.raise("Build the guarded terminal port first: scripts/dev/check_terminal_port.sh")

    # Only HTTP/runtime support is started. Canonical storage/application startup
    # is not part of this development entrypoint.
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:swarm_code_core)
    {:ok, _} = Application.ensure_all_started(:swarm_code_cli)
    {:ok, _} = Application.ensure_all_started(:swarm_code_daemon)

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

    source_epoch = uuid()
    conversation_id = uuid()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {dir, stat} = private_directory!()

    try do
      {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)
      Process.unlink(supervisor)

      try do
        backend =
          child!(
            supervisor,
            LiveBackend,
            config ++
              [
                mode: :transient,
                source_epoch: source_epoch,
                conversation_id: conversation_id,
                project_id: uuid()
              ]
          )

        path = Path.join(dir, "s")

        child!(supervisor, Service,
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
          banner: :live_banner,
          now: System.system_time(:millisecond)
        }

        runtime =
          child!(supervisor, SessionRuntime,
            init: init,
            data_source: source,
            frame_ms: 33,
            close_ms: 3000,
            instruction_sink: self()
          )

        start_companion(supervisor, runtime, Path.basename(root))

        IO.puts(
          :stderr,
          "DEVELOPMENT LIVE SESSION — UNSAVED\nRuns and transcripts disappear when this session closes. Tools can change project files."
        )

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
            # The runtime names a close nobody asked for; say it now that the
            # terminal is restored.
            receive do
              {:session_closed, words} when is_binary(words) ->
                IO.puts(:stderr, "swarmcode: the session closed because " <> words <> ".")
            after
              0 -> :ok
            end

          {:DOWN, ^owner_monitor, :process, ^owner, _} ->
            Mix.raise("Development live terminal failed")

          {:DOWN, ^supervisor_monitor, :process, ^supervisor, _} ->
            Mix.raise("Development live session failed")
        end
      after
        if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 15_000)
      end
    after
      # Never recursively remove a namespace that could have been replaced.
      case File.lstat(dir) do
        {:ok, current}
        when current.inode == stat.inode and current.major_device == stat.major_device and
               current.type == :directory ->
          File.rmdir(dir)

        _ ->
          :ok
      end
    end

    IO.puts(:stderr, "DEVELOPMENT LIVE SESSION — UNSAVED: closed.")
  end

  defp private_directory! do
    # Short fixed parent keeps Unix socket paths below the platform limit.
    dir =
      Path.join(
        "/tmp",
        "scl-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        {dir, File.lstat!(dir)}

      {:error, :eexist} ->
        private_directory!()

      _ ->
        Mix.raise("Unable to create a private live session directory")
    end
  end

  defp color_mode do
    cond do
      System.get_env("NO_COLOR") != nil -> :monochrome
      System.get_env("COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      String.contains?(System.get_env("TERM") || "", "256color") -> :ansi256
      true -> :ansi16
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

  defp child!(supervisor, module, options) do
    case Supervisor.start_child(
           supervisor,
           Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 10_000)
         ) do
      {:ok, pid} -> pid
      _ -> Mix.raise("Unable to start development live session")
    end
  end

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    Enum.join([a, b, c, d, e], "-")
  end
end

SwarmCode.Development.LiveSession.run()
