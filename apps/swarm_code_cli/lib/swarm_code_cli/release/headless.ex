defmodule SwarmCodeCLI.Release.Headless do
  @moduledoc """
  The saved session without the full-screen view: `swarmcode -p PROMPT` (one
  turn, then exit) and `swarmcode --plain` (the line presenter, for pipes, CI
  and SSH).

  Startup is the saved session's (`Release.PersistedSession`, owner B):
  guarded storage, the project's session, the service and its client. That
  module exposes only `run/0` today, so its steps are repeated here as a thin
  adapter; the pass-70 notes ask for a public open/close there so this module
  can call it instead of keeping a copy.

  `run/2` returns the exit code: 0 done, 1 the run failed (or the session
  broke), 3 startup refused. Usage (2) is the caller's. Nothing here prints a
  stack trace: every failure is one line on stderr, and the answer owns
  stdout, so log output goes to stderr and only from warnings up.
  """
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.FoundationGate.BootConfig,
              SwarmCode.Daemon.RepoLauncher,
              SwarmCode.Daemon.StartupError,
              SwarmCode.Daemon.Service,
              SwarmCode.Daemon.Service.PersistedBackend,
              SwarmCode.Daemon.Service.SessionConfiguration,
              SwarmCode.Daemon.Service.SessionSelection,
              SwarmCode.Domain.Engine,
              SwarmCode.Domain.LLM.OpenAI,
              SwarmCode.Domain.LLM.Anthropic,
              Ecto.UUID
            ]}

  alias SwarmCode.Daemon.FoundationGate.BootConfig
  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Daemon.StartupError
  alias SwarmCode.Daemon.Service.{PersistedBackend, SessionConfiguration, SessionSelection}
  alias SwarmCodeCLI.Plain.{OneShot, Options}
  alias SwarmCodeCLI.UI.DataSource.Daemon

  @type mode :: {:prompt, binary(), :text | :json} | {:plain, :text | :ndjson}

  @doc """
  Opens the saved session and runs `mode` in it.

  Options: `project_root` (default `SWARM_PROJECT_ROOT`, else the current
  directory), `conversation` (`"latest"`, `"new"` or a conversation id;
  default `SWARM_CONVERSATION`, else latest) and `model` (a session override,
  exported as `SWARM_MODEL_OVERRIDE` for the provider configuration).
  """
  @spec run(mode(), keyword()) :: 0 | 1 | 3
  def run(mode, options \\ []) do
    root = Keyword.get(options, :project_root) || System.get_env("SWARM_PROJECT_ROOT")
    root = if root in [nil, ""], do: File.cwd!(), else: root
    conversation = Keyword.get(options, :conversation) || System.get_env("SWARM_CONVERSATION")
    if model = Keyword.get(options, :model), do: System.put_env("SWARM_MODEL_OVERRIDE", model)

    with {:ok, selection} <- selection(conversation),
         :ok <- directory(root),
         :ok <- start_applications() do
      logs_to_stderr()
      open(root, selection, mode)
    else
      {:refused, text} -> refuse(text)
    end
  rescue
    error -> fail("SwarmCode stopped unexpectedly (#{inspect(error.__struct__)}).")
  catch
    kind, _ -> fail("SwarmCode stopped unexpectedly (#{kind}).")
  end

  @doc "The one line a startup failure prints, without the `swarmcode:` prefix."
  @spec refusal(term()) :: binary()
  def refusal(%{__struct__: StartupError, message: message, action: action}),
    do: String.trim("#{message} #{action}")

  def refusal(:conversation_not_found),
    do:
      "No conversation with that id in this project. " <>
        "Run swarmcode --continue, or pick one with /resume."

  def refusal(reason) when reason in [:provider_required, :endpoint_required],
    do:
      "No model provider is set up. Add one in the SwarmCode app's Settings, " <>
        "or export SWARM_MODEL, SWARM_BASE_URL and SWARM_API_KEY."

  def refusal(:invalid_project), do: "That directory cannot be opened as a project."

  def refusal(:session_unavailable),
    do: "The project's saved session could not be opened. Try again in a moment."

  def refusal(reason) when is_atom(reason),
    do: "SwarmCode could not start (#{reason |> Atom.to_string() |> String.replace("_", " ")})."

  def refusal(_), do: "SwarmCode could not start."

  # -- startup ----------------------------------------------------------------

  defp selection(nil), do: {:ok, [conversation: :latest]}
  defp selection("latest"), do: {:ok, [conversation: :latest]}
  defp selection("new"), do: {:ok, [conversation: :new]}

  defp selection(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, [conversation: id]}
      _ -> {:refused, "A conversation is latest, new, or a conversation id; #{id} is none."}
    end
  end

  defp directory(root) do
    if File.dir?(root), do: :ok, else: {:refused, "#{root} is not a directory."}
  end

  defp start_applications do
    started =
      Enum.all?(
        [:req, :swarm_code_core, :swarm_code_cli, :swarm_code_daemon],
        &match?({:ok, _}, Application.ensure_all_started(&1))
      )

    if started do
      # The daemon resolves a provider kind through this registry; the saved
      # session registers both adapters, and so must this one.
      Application.put_env(
        :swarm_code_daemon,
        :llm_providers,
        Application.get_env(:swarm_code_daemon, :llm_providers, %{})
        |> Map.merge(%{
          "openai_compatible" => SwarmCode.Domain.LLM.OpenAI,
          "anthropic" => SwarmCode.Domain.LLM.Anthropic
        })
      )

      :ok
    else
      {:refused, "SwarmCode could not start its runtime."}
    end
  end

  # The console handler writes to stdout, which here is the answer. It moves
  # to stderr and keeps only warnings and errors; any other handler (a log
  # file) is left alone.
  defp logs_to_stderr do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: :logger_std_h, config: %{type: :standard_io}} = handler} ->
        :logger.remove_handler(:default)

        :logger.add_handler(:default, :logger_std_h, %{
          level: :warning,
          formatter: handler.formatter,
          filters: handler.filters,
          filter_default: handler.filter_default,
          config: %{type: :standard_error}
        })

      {:ok, %{module: :logger_std_h}} ->
        :logger.set_handler_config(:default, :level, :warning)

      _ ->
        :ok
    end
  end

  defp open(root, selection, mode) do
    version = Application.spec(:swarm_code_daemon, :vsn) |> to_string()
    platform = if match?({:unix, :darwin}, :os.type()), do: :macos, else: :linux
    boot = BootConfig.canonical(platform, System.user_home!(), version)

    case RepoLauncher.start_link(boot_config: boot, pool_size: 4) do
      {:ok, launcher} ->
        Process.unlink(launcher)

        try do
          with {:ok, _} <- RepoLauncher.await_ready(launcher, 120_000),
               {:ok, session} <- session(root, selection) do
            run_session(session, mode)
          else
            {:error, reason} -> refuse(refusal(reason))
          end
        after
          close_owned_runtime(launcher)
        end

      {:error, reason} ->
        refuse(refusal(reason))
    end
  end

  defp session(root, selection) do
    query_worker(fn ->
      with {:ok, session} <- SessionSelection.open(root, selection) do
        SessionConfiguration.prepare(session, System.get_env())
      end
    end)
  end

  defp run_session(session, mode) do
    {dir, stat} = private_directory()
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)
    Process.unlink(supervisor)

    try do
      source_epoch = Ecto.UUID.generate()
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      socket = Path.join(dir, "s")

      with {:ok, backend} <-
             child(supervisor, PersistedBackend,
               mode: :persisted,
               repo: SwarmCode.Domain.Repo,
               project_root: session.project.root_path,
               project_id: session.project.id,
               conversation_id: session.conversation.id,
               source_epoch: source_epoch
             ),
           {:ok, _service} <-
             child(supervisor, SwarmCode.Daemon.Service,
               socket_path: socket,
               nonce: nonce,
               source_epoch: source_epoch,
               backend: backend
             ),
           {:ok, source} <-
             child(supervisor, Daemon,
               socket_path: socket,
               nonce: nonce,
               source_epoch: source_epoch
             ) do
        present(mode, source, source_epoch, session.conversation.id)
      else
        _ -> fail("The saved session could not start its service.")
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 15_000)
      remove_private_directory(dir, stat)
    end
  end

  defp present({:prompt, prompt, format}, source, epoch, conversation) do
    OneShot.run(
      data_source: source,
      source_epoch: epoch,
      conversation_id: conversation,
      prompt: prompt,
      format: format,
      progress: tty?(:stderr)
    )
  end

  defp present({:plain, format}, source, epoch, conversation) do
    {:ok, plain} =
      SwarmCodeCLI.Plain.Session.start_link(
        data_source: source,
        source_epoch: epoch,
        conversation_id: conversation,
        now: System.system_time(:millisecond),
        input: :standard_io,
        output: :standard_io,
        error: :standard_error,
        # At the end of the input the session waits for the runs it started.
        eof: :wait,
        options: %Options{format: format, banner: :saved, detached_runs?: false},
        observer: self()
      )

    Process.unlink(plain)
    monitor = Process.monitor(plain)

    receive do
      {:plain_session, ^plain, {:closed, reason}} ->
        Process.demonitor(monitor, [:flush])
        plain_code(reason)

      {:DOWN, ^monitor, :process, ^plain, _} ->
        fail("The plain session stopped unexpectedly.")
    end
  end

  defp plain_code(reason) when reason in [:eof, :detach, :interrupt], do: 0
  defp plain_code(:run_failed), do: 1

  defp plain_code(:needs_input) do
    IO.puts(:stderr, "swarmcode: a run is waiting for an answer; open swarmcode to give it.")
    1
  end

  defp plain_code(reason),
    do:
      fail("The plain session closed: #{reason |> Atom.to_string() |> String.replace("_", " ")}.")

  # -- close ------------------------------------------------------------------

  defp close_owned_runtime(launcher) do
    if Process.whereis(SwarmCode.Domain.Registry) do
      query_worker(fn -> {:ok, SwarmCode.Domain.Engine.stop_all()} end)
      Application.stop(:swarm_code_daemon)
    end

    if Process.alive?(launcher) do
      case RepoLauncher.close(launcher) do
        :ok ->
          :ok

        {:error, {:cleanup_pending, _}} ->
          monitor = Process.monitor(launcher)

          receive do
            {:DOWN, ^monitor, :process, ^launcher, _} -> :ok
          after
            10_000 ->
              IO.puts(
                :stderr,
                "swarmcode: storage cleanup is still pending; it finishes on exit."
              )
          end

        _ ->
          IO.puts(:stderr, "swarmcode: storage could not be closed cleanly.")
      end
    end
  catch
    _, _ -> :ok
  end

  # -- plumbing ---------------------------------------------------------------

  defp query_worker(fun) do
    fun |> Task.async() |> Task.await(30_000)
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  defp child(supervisor, module, options) do
    Supervisor.start_child(
      supervisor,
      Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 10_000)
    )
  end

  defp private_directory do
    dir =
      Path.join(
        "/tmp",
        "scl-h-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        {dir, File.lstat!(dir)}

      {:error, :eexist} ->
        private_directory()
    end
  end

  defp remove_private_directory(dir, stat) do
    case File.lstat(dir) do
      {:ok, current}
      when current.inode == stat.inode and current.major_device == stat.major_device and
             current.type == :directory ->
        File.rm(Path.join(dir, "s"))
        File.rmdir(dir)

      _ ->
        :ok
    end
  end

  defp tty?(device) do
    :prim_tty.isatty(device) == true
  catch
    _, _ -> false
  end

  defp refuse(text) do
    IO.puts(:stderr, "swarmcode: " <> text)
    3
  end

  defp fail(text) do
    IO.puts(:stderr, "swarmcode: " <> text)
    1
  end
end
