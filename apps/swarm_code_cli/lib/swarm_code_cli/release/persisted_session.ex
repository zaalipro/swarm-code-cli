defmodule SwarmCodeCLI.Release.PersistedSession do
  @moduledoc """
  The saved `swarmcode` session: guarded storage, session selection, provider
  resolution, the terminal UI, and an orderly close.

  Nothing here raises to the terminal (pass70 B3). Every failure becomes one
  human sentence plus what to do, printed on stderr after the terminal is
  restored, and an exit status: 1 failure, 2 usage, 3 startup refused. The
  details go to the private log (`log_path/0`), which also receives every
  Logger message while the session runs, never the tty. After a session ends a
  short summary is printed to the main screen (pass70 B9).
  """
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.FoundationGate.BootConfig,
              SwarmCode.Daemon.Platform.Paths,
              SwarmCode.Daemon.Schema.Refusal,
              SwarmCode.Daemon.RepoLauncher,
              SwarmCode.Daemon.Service.SessionConfiguration,
              SwarmCode.Daemon.Service.SessionSelection,
              SwarmCode.Daemon.StartupError,
              SwarmCode.Daemon.Boot,
              SwarmCode.Daemon.Shutdown,
              SwarmCode.Domain.Engine,
              SwarmCode.Domain.Repo,
              Ecto.UUID
            ]}
  require Logger
  alias SwarmCode.Daemon.RepoLauncher
  alias SwarmCode.Daemon.FoundationGate.BootConfig
  alias SwarmCode.Daemon.Service.{PersistedBackend, SessionConfiguration, SessionSelection}
  alias SwarmCodeCLI.Companion
  alias SwarmCodeCLI.UI.{Capabilities, Init, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.Daemon
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

  @exit_failure 1
  @exit_usage 2
  @exit_refused 3
  @log_bytes 2_097_152
  @log_files 3

  @typedoc "A failure the user reads: exit status, one sentence, one action."
  @type failure :: %{status: 1..3, message: String.t(), action: String.t()}

  @doc "Runs the packaged TUI session. Returns the process exit status; never raises."
  @spec run() :: non_neg_integer()
  def run, do: main(nil, label: :release)

  # The packaged entry points a release may start, chosen by `SWARM_RELEASE_MODE`
  # from this fixed table (runtime input never names a module). `tui` is the
  # default whenever `SWARM_RELEASE_TUI=1`. Each entry returns the exit status.
  # The headless modes (`-p`, `--plain`) do not start the release: the
  # launcher evaluates `SwarmCodeCLI.Release.main/1`, which opens the session
  # through `with_saved_session/2`. The table lives here, under `release/`,
  # the one CLI directory allowed to look modules up at run time (the UI
  # architecture test).
  @entries %{"tui" => {__MODULE__, :run}}

  @doc "Runs the release entry named by `SWARM_RELEASE_MODE`; returns the exit status."
  @spec run_entry(String.t()) :: non_neg_integer()
  def run_entry(mode) when is_binary(mode) do
    with {module, function} <- Map.get(@entries, mode),
         true <- Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      _ ->
        IO.puts(
          :stderr,
          "swarmcode: this build has no #{inspect(mode)} mode. Run swarmcode --help."
        )

        @exit_usage
    end
  end

  @doc """
  Runs the TUI session for a development launcher (`scripts/dev/run_saved_session.sh`).
  Same behaviour as `run/0`, plus a first stderr line naming the conversation.
  """
  @spec run_dev() :: non_neg_integer()
  def run_dev, do: main(nil, label: :dev)

  # A trusted test runner passes this directly. No environment variable or
  # production command-line option can select an alternate database path.
  @spec run_for_test(keyword() | struct()) :: non_neg_integer()
  def run_for_test(boot_config) do
    if mix_test?(),
      do: main(boot_config, label: :dev),
      else: report(failure(@exit_usage, "Test boot configuration requires MIX_ENV=test.", ""))
  end

  @doc """
  Contract for headless entry points (owner E, `swarmcode -p` / `--plain`):
  boots guarded storage and the saved runtime exactly like the TUI (log file,
  lease, migrations, session selection, provider resolution, boot recovery),
  calls `fun.(session)` with `%{project: _, conversation: _, notice: _}`, then
  stops live runs and closes storage. `options`: `:project_root` (default
  `SWARM_PROJECT_ROOT` or cwd), `:conversation` (`:latest | :new | uuid`,
  default from `SWARM_CONVERSATION`). Returns `{:ok, fun_result}` or
  `{:error, failure}`; print a failure with `report/1`. Never raises.
  """
  @spec with_saved_session(keyword(), (map() -> term())) :: {:ok, term()} | {:error, failure()}
  def with_saved_session(options \\ [], fun) when is_list(options) and is_function(fun, 1) do
    guarded(fn ->
      root = Keyword.get_lazy(options, :project_root, &project_root/0)
      selection = Keyword.get_lazy(options, :conversation, &selection_from_env/0)
      check_root!(root)
      route_logger!(log_path(nil))
      start_applications!()

      with_storage(
        nil,
        fn session ->
          result = fun.(session)
          {:ok, result, %{stopped: stop_live_runs()}}
        end,
        root,
        conversation: selection
      )
    end)
    |> case do
      {:ok, {:ok, result, _summary}} -> {:ok, result}
      {:ok, {:error, failure}} -> {:error, failure}
      {:error, failure} -> {:error, failure}
    end
  end

  @doc "Prints a failure (two lines and the log path) on stderr and returns its exit status."
  @spec report(failure()) :: non_neg_integer()
  def report(%{status: status, message: message, action: action}) do
    # A sentence that names swarmcode itself is not prefixed twice (pass70 F14).
    message =
      case message do
        "swarmcode " <> rest -> rest
        message -> message
      end

    lines =
      ["swarmcode: " <> message] ++
        if(action != "", do: ["  " <> action], else: []) ++
        if(status != @exit_usage and File.exists?(log_path(nil)),
          do: ["  Details: " <> log_path(nil)],
          else: []
        )

    IO.puts(:stderr, Enum.join(lines, "\n"))
    status
  end

  @doc "The private log file: `~/Library/Logs/SwarmCode/cli.log` on macOS, XDG state on Linux."
  @spec log_path(term()) :: Path.t()
  def log_path(boot \\ nil) do
    case paths_for(boot) do
      {:ok, paths} -> Path.join(paths.state, "cli.log")
      _ -> Path.join([System.user_home!(), "Library", "Logs", "SwarmCode", "cli.log"])
    end
  end

  ## The TUI session

  defp main(test_boot, opts) do
    result =
      guarded(fn ->
        preflight!()
        root = project_root()
        check_root!(root)
        selection = selection_from_env()
        executable = terminal_port!()
        route_logger!(log_path(test_boot))
        start_applications!()

        with_storage(test_boot, fn session -> tui(session, executable, opts) end, root,
          conversation: selection
        )
      end)

    case result do
      {:ok, {:ok, outcome, summary}} ->
        print_summary(summary)
        outcome_status(outcome)

      {:ok, {:error, failure}} ->
        report(failure)

      {:error, failure} ->
        report(failure)
    end
  end

  defp tui(session, executable, opts) do
    started_at = DateTime.utc_now()

    if opts[:label] == :dev,
      do: IO.puts(:stderr, "swarmcode (dev) — conversation #{session.conversation.id}")

    outcome = run_ui(session, executable)
    # Read the summary while storage and the runs are still up, then stop them.
    summary = query_worker(fn -> summary(session, started_at) end)
    stopped = stop_live_runs()
    {:ok, outcome, Map.merge(summary, %{stopped: stopped, notice: session[:notice]})}
  end

  # Starts storage, selects and configures the session, runs `fun`, and always
  # closes the owned runtime. `fun` returns `{:ok, outcome, summary}`.
  defp with_storage(test_boot, fun, root, selection) do
    version = Application.spec(:swarm_code_daemon, :vsn) |> to_string()
    boot = test_boot || BootConfig.canonical(platform(), System.user_home!(), version)

    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 4)
    Process.unlink(launcher)

    try do
      with :ok <- await_storage(launcher, boot),
           :ok <- boot_runtime(),
           {:ok, session} <- open_session(root, selection) do
        fun.(session)
      end
    after
      close_owned_runtime(launcher)
    end
  end

  defp await_storage(launcher, boot) do
    case RepoLauncher.await_ready(launcher, 120_000) do
      {:ok, _repo} -> :ok
      {:error, reason} -> {:error, startup_failure(reason, boot)}
    end
  end

  defp open_session(root, selection) do
    # SQL callers are short-lived. Returning plain session structs does not
    # retain native statement resources in the launcher while the TUI runs.
    query_worker(fn ->
      with {:ok, session} <- SessionSelection.open(root, selection),
           {:ok, session} <- SessionConfiguration.prepare(session, System.get_env()) do
        {:ok, session}
      else
        {:error, reason} -> {:error, session_failure(reason, selection)}
      end
    end)
  end

  # B6: the desktop's boot recovery (interrupted runs, seeded providers, MCP
  # servers, research sweep, attachment prune) before the first snapshot. It
  # never stops the session; each step logs its own failure.
  defp boot_runtime do
    query_worker(fn -> SwarmCode.Daemon.Boot.run() end)
    :ok
  catch
    kind, reason ->
      Logger.error("boot recovery failed: #{Exception.format(kind, reason)}")
      :ok
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
          source_epoch: source_epoch,
          first_run_notice: session[:notice]
        )

      path = Path.join(dir, "s")

      child!(supervisor, SwarmCode.Daemon.Service,
        socket_path: path,
        nonce: nonce,
        source_epoch: source_epoch,
        backend: backend
      )

      source =
        child!(supervisor, Daemon,
          socket_path: path,
          nonce: nonce,
          source_epoch: source_epoch,
          timeout: 30_000
        )

      color_mode = color_mode()
      ascii? = ascii?(System.get_env())

      caps = %Capabilities{
        size: %Size{columns: 80, rows: 24},
        stdin_tty?: true,
        stdout_tty?: true,
        color_mode: color_mode,
        ascii?: ascii?,
        # pass71 F4: the rich tier (thin rails, V1) where the terminal has it.
        glyph_tier: Capabilities.glyph_tier(color_mode, :narrow, ascii?, System.get_env("TERM"))
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
          wall_clock: true,
          instruction_sink: self()
        )

      start_companion(supervisor, runtime, Path.basename(session.project.root_path))

      owner =
        child!(supervisor, Owner,
          runtime: runtime,
          capabilities: caps,
          # B10: SWARM_MOUSE=1 opts into wheel reports (they turn off the
          # terminal's own click-and-drag selection, so never by default).
          flags: %{
            alternate?: true,
            focus?: true,
            paste?: true,
            mouse?: System.get_env("SWARM_MOUSE") == "1"
          },
          executable: executable,
          theme: SwarmCodeCLI.UI.Theme.mode(System.get_env("SWARM_THEME"), settings_mode())
        )

      owner_monitor = Process.monitor(owner)
      supervisor_monitor = Process.monitor(supervisor)

      receive do
        {:DOWN, ^owner_monitor, :process, ^owner, :normal} ->
          # The runtime names a close nobody asked for (the daemon connection
          # went away, a frame could not be drawn); it is reported now that
          # the terminal is restored.
          receive do
            {:session_closed, words} when is_binary(words) ->
              {:failed,
               failure(
                 @exit_failure,
                 "The session closed because " <> words <> ".",
                 "Run swarmcode again; your conversation is saved."
               )}
          after
            0 -> :ok
          end

        {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
          Logger.error("terminal owner stopped: #{inspect(reason)}")

          {:failed,
           failure(
             @exit_failure,
             "The terminal stopped responding, so swarmcode closed.",
             "Run swarmcode again; your conversation is saved."
           )}

        {:DOWN, ^supervisor_monitor, :process, ^supervisor, reason} ->
          Logger.error("session supervisor stopped: #{inspect(reason)}")

          {:failed,
           failure(
             @exit_failure,
             "The session stopped unexpectedly, so swarmcode closed.",
             "Run swarmcode again; your conversation is saved."
           )}
      end
    after
      if Process.alive?(supervisor), do: stop_quietly(supervisor)

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

  ## Close

  # B6: the desktop's quit (pause workflows, stop runs, kill commands the runs
  # left running, flush, stop runs/research/MCP/LSP subtrees). Idempotent.
  # Returns the live runs it stopped (pass71 S4: `%{id, kind, title}` each).
  defp stop_live_runs do
    if Process.whereis(SwarmCode.Domain.Registry) do
      %{stopped_runs: stopped} =
        fun_with_deadline(fn -> SwarmCode.Daemon.Shutdown.run() end, 60_000)

      stopped
    else
      []
    end
  catch
    kind, reason ->
      Logger.error("stopping live runs failed: #{Exception.format(kind, reason)}")
      []
  end

  defp fun_with_deadline(fun, timeout), do: fun |> Task.async() |> Task.await(timeout)

  defp close_owned_runtime(launcher) do
    if Process.whereis(SwarmCode.Domain.Registry) do
      _ = stop_live_runs()
      # This process owns the VM runtime. Stop agents, tasks, research and
      # caches before retiring the guarded storage pool.
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
          Logger.error("guarded storage close: #{inspect(other)}")
      end
    end
  catch
    kind, reason -> Logger.error("closing storage failed: #{Exception.format(kind, reason)}")
  end

  defp stop_quietly(supervisor) do
    Supervisor.stop(supervisor, :normal, 15_000)
  catch
    :exit, _ -> :ok
  end

  ## Summary (B9)

  # Plain SQL: this app does not depend on Ecto at compile time.
  defp summary(session, started_at) do
    id = session.conversation.id
    since = DateTime.to_iso8601(started_at)

    title = scalar("SELECT title FROM conversations WHERE id = ?1", [id])

    prompt =
      scalar(
        "SELECT content FROM messages WHERE conversation_id = ?1 AND role = 'user' " <>
          "ORDER BY position DESC LIMIT 1",
        [id]
      )

    files =
      rows(
        "SELECT DISTINCT path FROM checkpoints WHERE conversation_id = ?1 AND inserted_at >= ?2 " <>
          "ORDER BY path LIMIT 200",
        [id, since]
      )

    %{
      title: title,
      prompt: prompt,
      files:
        for(
          [path] <- files,
          is_binary(path),
          do: Path.relative_to(path, session.project.root_path)
        ),
      root: session.project.root_path
    }
  rescue
    error ->
      Logger.error("exit summary: #{Exception.message(error)}")
      %{title: nil, prompt: nil, files: [], root: session.project.root_path}
  end

  defp scalar(sql, params) do
    case rows(sql, params) do
      [[value] | _] when is_binary(value) -> value
      _ -> nil
    end
  end

  defp rows(sql, params) do
    case SwarmCode.Domain.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) -> rows
      _ -> []
    end
  end

  defp print_summary(summary) do
    dim = fn text -> if(color?(), do: "\e[2m" <> text <> "\e[22m", else: text) end
    label = fn text -> dim.(String.pad_trailing(text, 14)) end

    title = one_line(summary[:title]) || "Untitled conversation"
    prompt = one_line(summary[:prompt])
    notice = one_line(summary[:notice])
    files = summary[:files] || []
    stopped = summary[:stopped] || []

    lines =
      [
        "",
        "  " <> bold(title),
        prompt && "  " <> label.("Last prompt") <> prompt,
        files != [] && "  " <> label.("Files changed") <> files_line(files),
        stopped != [] && "  " <> label.("Stopped") <> stopped_lines(stopped),
        notice && "  " <> label.("Note") <> notice,
        "  " <> label.("Resume") <> resume_command(summary[:root]),
        ""
      ]
      |> Enum.filter(&is_binary/1)

    IO.puts(Enum.join(lines, "\n"))
  end

  # pass71 S4 (R1): every run the quit stopped, one per line under the count.
  @doc false
  def stopped_lines(runs) do
    indent = "\n" <> String.duplicate(" ", 16) <> "· "

    Enum.join([
      plural(length(runs), "live run")
      | Enum.map(runs, fn run -> indent <> stopped_run(run) end)
    ])
  end

  defp stopped_run(run) do
    title = one_line(run[:title]) || "Untitled run"

    case run[:kind] do
      kind when kind in [nil, "", "chat"] -> title
      kind -> title <> " · " <> (one_line(kind) || "run")
    end
  end

  defp files_line(files) do
    shown = Enum.take(files, 3)
    rest = length(files) - length(shown)
    names = Enum.map(shown, &(one_line(&1) || "?"))
    "#{length(files)} · " <> Enum.join(names, ", ") <> if(rest > 0, do: ", +#{rest}", else: "")
  end

  defp resume_command(root) do
    here = System.get_env("PWD")

    if root == nil or root == here,
      do: "swarmcode --continue",
      else: "swarmcode --continue " <> shell_quote(root)
  end

  defp shell_quote(path) do
    if path =~ ~r/^[A-Za-z0-9_\/.~+-]+$/,
      do: path,
      else: "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  defp one_line(nil), do: nil

  defp one_line(text) when is_binary(text) do
    line =
      text
      |> String.split(["\r\n", "\n", "\r"], trim: true)
      |> List.first("")
      |> String.replace(~r/[\x00-\x1F\x7F-\x9F]/u, " ")
      |> String.trim()

    cond do
      line == "" -> nil
      String.length(line) > 72 -> String.slice(line, 0, 71) <> "…"
      true -> line
    end
  end

  defp plural(1, noun), do: "1 " <> noun
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp bold(text), do: if(color?(), do: "\e[1m" <> text <> "\e[22m", else: text)

  defp color?,
    do: System.get_env("NO_COLOR") in [nil, ""] and :prim_tty.isatty(:stdout) == true

  defp outcome_status(:ok), do: 0
  defp outcome_status({:failed, failure}), do: report(failure)

  ## Failures

  # Runs `fun`, turning a thrown failure or any crash into `{:error, failure}`.
  defp guarded(fun) do
    {:ok, fun.()}
  catch
    :throw, {__MODULE__, failure} ->
      {:error, failure}

    kind, reason ->
      Logger.error(
        "swarmcode stopped unexpectedly: " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error,
       failure(
         @exit_failure,
         "swarmcode stopped unexpectedly.",
         "Run it again; your conversation is saved."
       )}
  end

  defp fail!(status, message, action), do: throw({__MODULE__, failure(status, message, action)})

  defp failure(status, message, action), do: %{status: status, message: message, action: action}

  defp preflight! do
    unless System.argv() == [],
      do: fail!(@exit_usage, "unexpected arguments.", "Run swarmcode --help.")

    unless (release_tui?() or :init.get_argument(:noinput) != :error) and
             :prim_tty.isatty(:stdin) == true and
             :prim_tty.isatty(:stdout) == true and
             System.get_env("TERM") not in [nil, "", "dumb"],
           do:
             fail!(
               @exit_usage,
               "swarmcode needs an interactive terminal.",
               ~s(In pipes and scripts use swarmcode -p "prompt" or swarmcode --plain.)
             )
  end

  defp check_root!(root) do
    unless is_binary(root) and File.dir?(root),
      do: fail!(@exit_usage, "#{inspect(root)} is not a directory.", "Name a project directory.")
  end

  defp terminal_port! do
    executable =
      System.get_env("SWARM_TERMINAL_PORT") ||
        Path.expand("../../../../../_build/terminal-port/debug/swarm-terminal-port", __DIR__)

    if File.regular?(executable),
      do: executable,
      else:
        fail!(
          @exit_failure,
          "The swarmcode terminal helper is missing.",
          "Reinstall swarmcode (scripts/install.sh), or build it with scripts/dev/check_terminal_port.sh."
        )
  end

  defp start_applications! do
    for app <- [:req, :swarm_code_core, :swarm_code_cli, :swarm_code_daemon] do
      case Application.ensure_all_started(app) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("application #{app} did not start: #{inspect(reason)}")
          fail!(@exit_failure, "swarmcode could not start.", "Reinstall swarmcode.")
      end
    end

    Application.put_env(
      :swarm_code_daemon,
      :llm_providers,
      Application.get_env(:swarm_code_daemon, :llm_providers, %{})
      |> Map.merge(%{
        "openai_compatible" => SwarmCode.Domain.LLM.OpenAI,
        "anthropic" => SwarmCode.Domain.LLM.Anthropic
      })
    )
  end

  defp startup_failure(%{__struct__: SwarmCode.Daemon.StartupError} = error, boot) do
    Logger.error("startup refused: #{error.code}: #{error.message} #{error.action}")
    {message, action} = startup_words(error.code, error, boot)
    failure(@exit_refused, message, action)
  end

  defp startup_failure(reason, _boot) do
    Logger.error("guarded storage did not start: #{inspect(reason)}")
    {message, action} = storage_words(reason)
    failure(@exit_refused, message, action)
  end

  @doc false
  # The words a schema refusal is said with, for the regression tests.
  def schema_words(%{code: :schema_incompatible} = error),
    do: startup_words(:schema_incompatible, error, nil)

  defp startup_words(:desktop_active, _error, _boot),
    do:
      {"The SwarmCode app is open, and only one of them can use your conversations at a time.",
       "Quit the SwarmCode app, then run swarmcode again."}

  defp startup_words(:data_lease_held, _error, boot),
    do:
      {lease_holder(boot),
       "Close it first (Ctrl-C twice, and once more if it asks), then run swarmcode again."}

  # The allowlist's two refusals (pass70 D2: an upgrade only the app makes, a
  # database from a newer app) and the gate's stray-file and damaged-file ones
  # (Q13) already say what to do; any other schema failure gets the general
  # sentence.
  defp startup_words(:schema_incompatible, error, _boot) do
    refusals = [
      SwarmCode.Daemon.Schema.Refusal.desktop_upgrade_required(),
      SwarmCode.Daemon.Schema.Refusal.database_ahead(),
      SwarmCode.Daemon.Schema.Refusal.not_a_database(),
      SwarmCode.Daemon.Schema.Refusal.damaged()
    ]

    if Enum.any?(refusals, &(&1.message == error.message)),
      do: {error.message, error.action},
      else:
        {"Your conversations database comes from a SwarmCode version this swarmcode does not know.",
         "Update swarmcode, or open the SwarmCode app once to upgrade the database. Nothing was changed."}
  end

  defp startup_words(code, _error, _boot)
       when code in [:private_directory_failed, :path_resolution_failed, :lease_failed],
       do:
         {"swarmcode could not safely open its private data folder.",
          "Check that ~/Library/Application Support/SwarmCode belongs to you and has mode 0700."}

  defp startup_words(:macos_platform_helper_unavailable, _error, _boot),
    do:
      {"swarmcode could not check whether the SwarmCode app is running.",
       "Reinstall swarmcode (scripts/install.sh)."}

  defp startup_words(code, _error, _boot) when code in [:backup_failed, :backup_unverified],
    do:
      {"swarmcode could not make a verified backup before upgrading the database, so it changed nothing.",
       "Free some disk space and run swarmcode again."}

  defp startup_words(_code, error, _boot), do: {error.message, error.action}

  defp storage_words(reason) when reason in [:migration_failed, :migration_timeout],
    do:
      {"swarmcode could not upgrade the database; it was left as it was.",
       "Your verified backup is in the SwarmCode backups folder. Open the SwarmCode app, or report this."}

  defp storage_words(_reason),
    do:
      {"swarmcode could not open your conversations database.",
       "Close other SwarmCode windows and run swarmcode again."}

  defp session_failure(:provider_required, _),
    do:
      failure(
        @exit_refused,
        "No model provider is set up yet.",
        "Add one in SwarmCode Settings, or set SWARM_MODEL, SWARM_BASE_URL and SWARM_API_KEY in ~/.secrets."
      )

  defp session_failure(:unknown_model, _),
    do:
      failure(
        @exit_usage,
        "No provider offers the model given with --model.",
        "Use a model from /model, or provider/model."
      )

  defp session_failure(:conversation_not_found, _),
    do:
      failure(
        @exit_usage,
        "That conversation is not part of this project.",
        "Use swarmcode --continue, or --resume with an id from this project."
      )

  defp session_failure(:invalid_project, _),
    do:
      failure(
        @exit_usage,
        "That project directory cannot be opened.",
        "Name a readable directory."
      )

  defp session_failure(reason, _selection) do
    Logger.error("session could not be prepared: #{inspect(reason)}")

    failure(
      @exit_failure,
      "swarmcode could not open the conversation.",
      "Run swarmcode again; nothing was changed."
    )
  end

  # B7: the lease owner record names the process that holds the data lease.
  defp lease_holder(boot) do
    with {:ok, paths} <- paths_for(boot),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 32_768 <-
           File.lstat(paths.owner_record),
         {:ok, body} <- File.read(paths.owner_record),
         {:ok, %{"pid" => pid} = record} when is_integer(pid) <- Jason.decode(body) do
      since =
        case DateTime.from_iso8601(to_string(record["acquired_at"])) do
          {:ok, at, _} -> ", since " <> local_clock(at)
          _ -> ""
        end

      "Another swarmcode (process #{pid}#{since}) is already using your conversations."
    else
      _ -> "Another swarmcode is already using your conversations."
    end
  rescue
    _ -> "Another swarmcode is already using your conversations."
  end

  defp local_clock(%DateTime{} = at) do
    {_date, {hour, minute, _}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()
  end

  ## Logging

  # Every Logger message of this VM goes to a private, rotated file: the tty is
  # the TUI's (rel F4, F8). The directory is 0700 and the file 0600.
  defp route_logger!(path) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- touch_private(path) do
      config = %{
        file: String.to_charlist(path),
        max_no_bytes: @log_bytes,
        max_no_files: @log_files
      }

      handler = %{
        config: config,
        level: :info,
        formatter: Logger.default_formatter(colors: [enabled: false])
      }

      _ = :logger.remove_handler(:default)

      case :logger.add_handler(:default, :logger_std_h, handler) do
        :ok -> :ok
        {:error, _} -> quiet_console()
      end
    else
      _ -> quiet_console()
    end
  end

  # Without a log file nothing may reach the terminal either.
  defp quiet_console do
    _ = :logger.remove_handler(:default)
    :ok
  end

  defp touch_private(path) do
    case File.open(path, [:append]) do
      {:ok, io} ->
        File.close(io)
        File.chmod(path, 0o600)

      error ->
        error
    end
  end

  ## Helpers

  defp paths_for(nil) do
    home = System.user_home!()

    SwarmCode.Daemon.Platform.Paths.resolve(
      platform: platform(),
      mode: :production,
      home: home,
      env:
        Map.take(
          System.get_env(),
          ~w(TMPDIR XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR)
        )
    )
  rescue
    _ -> :error
  end

  defp paths_for(%{__struct__: _} = boot) do
    SwarmCode.Daemon.Platform.Paths.resolve(
      platform: boot.platform,
      mode: boot.mode,
      home: boot.home,
      env: boot.env
    )
  rescue
    _ -> :error
  end

  defp paths_for(boot) when is_list(boot) do
    SwarmCode.Daemon.Platform.Paths.resolve(Keyword.take(boot, [:platform, :mode, :home, :env]))
  rescue
    _ -> :error
  end

  defp paths_for(_), do: :error

  defp platform, do: if(match?({:unix, :darwin}, :os.type()), do: :macos, else: :linux)

  defp project_root, do: System.get_env("SWARM_PROJECT_ROOT") || File.cwd!()

  defp query_worker(fun), do: fun |> Task.async() |> Task.await(30_000)

  defp selection_from_env do
    case System.get_env("SWARM_CONVERSATION") do
      value when value in [nil, "", "latest"] ->
        :latest

      "new" ->
        :new

      id ->
        case Ecto.UUID.cast(id) do
          {:ok, ^id} ->
            id

          _ ->
            fail!(
              @exit_usage,
              "SWARM_CONVERSATION must be latest, new, or a conversation id.",
              "Run swarmcode --help."
            )
        end
    end
  end

  defp child!(supervisor, module, options) do
    case Supervisor.start_child(
           supervisor,
           Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 10_000)
         ) do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.error("#{inspect(module)} did not start: #{inspect(reason)}")
        fail!(@exit_failure, "swarmcode could not start its session.", "Run it again.")
    end
  end

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
        fail!(
          @exit_failure,
          "swarmcode could not create its private socket folder.",
          "Check /tmp."
        )
    end
  end

  defp mix_test? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp release_tui?, do: System.get_env("SWARM_RELEASE_TUI") == "1"

  @doc """
  Whether the session draws the ASCII twins of its glyphs (pass70 Q12):
  `SWARM_ASCII=1` asks for it, for a terminal or font without the box,
  block and symbol glyphs. Before, nothing in the release could reach that
  tier.
  """
  @spec ascii?(map()) :: boolean()
  def ascii?(env) when is_map(env), do: Map.get(env, "SWARM_ASCII") in ["1", "true", "yes"]

  # pass71 F4: the desktop's light/dark choice (`settings.mode`), read
  # without `Settings.get/0`, which inserts the row when it is missing.
  defp settings_mode do
    case SwarmCode.Domain.Repo.query(
           "SELECT mode FROM settings ORDER BY inserted_at LIMIT 1",
           []
         ) do
      {:ok, %{rows: [[mode]]}} -> mode
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp color_mode do
    cond do
      System.get_env("NO_COLOR") != nil -> :monochrome
      System.get_env("COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      String.contains?(System.get_env("TERM") || "", "256color") -> :ansi256
      true -> :ansi16
    end
  end
end
