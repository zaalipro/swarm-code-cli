defmodule SwarmCodeCLI.Release.PersistedSession do
  @moduledoc """
  The saved `ncode` session: guarded storage, session selection, provider
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
              SwarmCode.Domain.Tools.Path,
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

  alias SwarmCodeCLI.Release.TerminalPreferences

  @provider_setup_words "Add a model provider to start: pick a preset, paste its key."
  # cli020 B12/B13: what the interactive TUI answers with the Providers page.
  @setup_reasons [:provider_required, :model_required, :endpoint_required]

  defp setup_words(:provider_required), do: @provider_setup_words

  defp setup_words(reason),
    do: session_failure(reason, nil).message <> " " <> @provider_setup_words

  @exit_failure 1
  @exit_usage 2

  # cli020 §8.4: the Preferences fields E adds, passed into the launch map
  # unchanged (like `mouse?`) for D's `UI.Init`/`State`.
  @passthrough_preferences [
    :panel_mode,
    :notify,
    :title?,
    :paste_collapse_lines,
    :exit_transcript,
    :wheel_lines,
    :notice_seconds,
    :hint_letters,
    :reduced_motion,
    :palette,
    :status_items
  ]

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
          "ncode: this build has no #{inspect(mode)} mode. Run ncode --help."
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
  Contract for headless entry points (owner E, `ncode -p` / `--plain`):
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

  @doc """
  pass74 S1-14: the foundation-only boot of `ncode config` — the log file,
  the lease and the verified migrations (guarded storage); no session
  selection, no provider resolution, no boot recovery, no daemon socket.
  Returns `{:ok, fun.()}` or `{:error, failure}` (a startup refusal carries
  its `:code`). Never raises.
  """
  @spec with_foundation(keyword(), (-> term())) :: {:ok, term()} | {:error, failure()}
  def with_foundation(options \\ [], fun) when is_list(options) and is_function(fun, 0) do
    guarded(fn ->
      route_logger!(log_path(nil))
      start_applications!()
      version = Application.spec(:swarm_code_daemon, :vsn) |> to_string()

      boot =
        Keyword.get_lazy(options, :boot_config, fn ->
          BootConfig.canonical(platform(), System.user_home!(), version)
        end)

      {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 4)
      Process.unlink(launcher)

      try do
        case await_storage(launcher, boot) do
          :ok -> {:ok, fun.()}
          {:error, failure} -> {:error, failure}
        end
      after
        close_owned_runtime(launcher)
      end
    end)
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, failure}} -> {:error, failure}
      {:error, failure} -> {:error, failure}
    end
  end

  @doc "Prints a failure (two lines and the log path) on stderr and returns its exit status."
  @spec report(failure(), Path.t()) :: non_neg_integer()
  def report(%{status: status, message: message, action: action} = failure, log \\ log_path(nil)) do
    # A sentence that names ncode itself is not prefixed twice (pass70 F14).
    message =
      case message do
        "ncode " <> rest -> rest
        message -> message
      end

    lines =
      ["ncode: " <> message] ++
        if(action != "", do: ["  " <> action], else: []) ++
        if(details?(failure, log), do: ["  Details: " <> log], else: [])

    say(:stderr, Enum.join(lines, "\n"))
    status
  end

  # cli020 B15 (onboarding-3): the log is named only when it holds something,
  # and never for a refusal its own sentence fixes.
  @self_explained [:provider_required, :endpoint_required, :model_required]

  defp details?(%{status: status} = failure, log) do
    status != @exit_usage and Map.get(failure, :reason) not in @self_explained and
      match?({:ok, %File.Stat{type: :regular, size: size}} when size > 0, File.stat(log))
  end

  @doc false
  # cli020 B15: the failure a session reason becomes (tests).
  @spec session_failure_for(atom()) :: failure()
  def session_failure_for(reason), do: session_failure(reason, nil)

  @doc """
  pass72 G17 (QA Q17): writes the closing words, but never waits more than
  `timeout` for the terminal. After a hang-up the terminal is gone ("Writer
  crashed (:eio)") and a write could block forever, so the VM never stopped.
  """
  @spec say(:stdio | :stderr | pid(), iodata(), non_neg_integer()) :: :ok | :timeout
  def say(device, text, timeout \\ 2_000) do
    {pid, ref} = spawn_monitor(fn -> IO.puts(device, text) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        :timeout
    end
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
    # cli020 B9: SIGTERM and SIGHUP close the session the normal way (the
    # terminal restored, the runs stopped, the private folder removed).
    if test_boot == nil, do: SwarmCodeCLI.Release.Signals.install(self())

    result =
      guarded(fn ->
        preflight!()
        root = project_root()
        check_root!(root)
        {selection, ask?} = tui_selection()
        executable = terminal_port!()
        route_logger!(log_path(test_boot))
        start_applications!()

        with_storage(
          test_boot,
          fn session -> tui(session, executable, Keyword.put(opts, :resume_picker?, ask?)) end,
          root,
          conversation: selection,
          interactive: true
        )
      end)

    status =
      case result do
        {:ok, {:ok, outcome, summary}} ->
          print_summary(summary)
          outcome_status(outcome)

        {:ok, {:error, failure}} ->
          clear_starting_line(test_boot)
          report(failure)

        {:error, failure} ->
          clear_starting_line(test_boot)
          report(failure)
      end

    # cli020 B15: the log is on disk before the VM stops.
    SwarmCodeCLI.Release.flush_logs()
    status
  end

  # cli020 B20: a failure before the full screen erases the launcher's
  # "Starting ncode…" too (the summary does it itself).
  defp clear_starting_line(nil) do
    if match?({:ok, _}, :io.columns(:standard_io)), do: IO.write("\r\e[2K")
  end

  defp clear_starting_line(_test_boot), do: :ok

  defp tui(session, executable, opts) do
    started_at = DateTime.utc_now()

    if opts[:label] == :dev,
      do: IO.puts(:stderr, "ncode (dev) — conversation #{session.conversation.id}")

    {outcome, current} = run_ui(session, executable, opts[:resume_picker?] == true)
    shown = %{session | conversation: %{session.conversation | id: current}}
    # Read the summary while storage and the runs are still up, then stop them.
    summary = query_worker(fn -> summary(shown, started_at) end)
    stopped = stop_live_runs()
    {:ok, outcome, Map.merge(summary, %{stopped: stopped, notice: session[:notice]})}
  end

  # Starts storage, selects and configures the session, runs `fun`, and always
  # closes the owned runtime. `fun` returns `{:ok, outcome, summary}`.
  defp with_storage(test_boot, fun, root, options) do
    {interactive?, selection} = Keyword.pop(options, :interactive, false)

    version = Application.spec(:swarm_code_daemon, :vsn) |> to_string()
    boot = test_boot || BootConfig.canonical(platform(), System.user_home!(), version)

    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 4)
    Process.unlink(launcher)

    try do
      with :ok <- await_storage(launcher, boot),
           :ok <- boot_runtime(),
           {:ok, session} <- open_session(root, selection, interactive?) do
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

  defp open_session(root, selection, interactive?) do
    # SQL callers are short-lived. Returning plain session structs does not
    # retain native statement resources in the launcher while the TUI runs.
    query_worker(fn ->
      case resolved_selection(root, selection) do
        {:ok, selection} -> open_resolved(root, selection, interactive?)
        {:error, failure} -> {:error, failure}
      end
    end)
  end

  defp resolved_selection(root, selection) when is_binary(selection) do
    case Ecto.UUID.cast(selection) do
      {:ok, ^selection} -> {:ok, selection}
      _ -> resolve_resume(root, selection)
    end
  end

  defp resolved_selection(_root, selection), do: {:ok, selection}

  @doc """
  cli020 B19 (competitors-12): the conversation of the project at `root`
  that `value` names: an exact title, else a unique id prefix of at least 6
  characters. Several matches are a usage error listing up to five.
  """
  @spec resolve_resume(Path.t(), String.t()) :: {:ok, String.t()} | {:error, failure()}
  def resolve_resume(root, value) do
    case SessionSelection.resolve(root, value) do
      {:ok, id} ->
        {:ok, id}

      {:error, :none} ->
        {:error,
         failure(
           @exit_usage,
           "No conversation of this project matches #{value}.",
           "Give a title, or 6 or more characters of an id; ncode --resume alone opens the picker."
         )}

      {:error, {:ambiguous, n, rows}} ->
        lines = Enum.map(rows, fn {id, title} -> "#{id}  #{title}" end)

        {:error,
         failure(
           @exit_usage,
           "--resume #{value} matches #{n} conversations.",
           Enum.join(lines ++ ["Name more of the id, or run ncode --resume to pick."], "\n")
         )}
    end
  end

  defp open_resolved(root, selection, interactive?) do
    case SessionSelection.open(root, selection) do
      {:ok, opened} ->
        case prepare(opened, interactive?) do
          {:ok, session} ->
            {:ok, session}

          {:error, reason} ->
            # cli020 B11: a failed start leaves no empty conversation (and
            # no project row this call created).
            SessionSelection.discard(opened)
            {:error, session_failure(reason, selection)}
        end

      {:error, reason} ->
        {:error, session_failure(reason, selection)}
    end
  end

  # pass74 S1-13 (D11): `ncode settings` opens without a usable provider —
  # that is how one is added; the dispatch refuses a send until then.
  # cli020 B12 (onboarding-2): the interactive TUI (the release's full screen
  # on a terminal; `main/2`'s preflight checked both) opens Providers instead of
  # exiting 3; `-p`, `--plain` and a non-tty keep exit 3.
  defp prepare(session, interactive?) do
    case SessionConfiguration.prepare(session, System.get_env()) do
      {:error, reason} when reason in @setup_reasons ->
        cond do
          reason == :provider_required and settings_only?() ->
            {:ok, session}

          interactive? ->
            {:ok,
             session
             |> Map.put(:open_settings, "providers")
             |> Map.put(:setup_notice, setup_words(reason))}

          true ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  @doc false
  # pass74 S1-13: the launcher's `ncode settings [QUERY]`.
  @spec settings_only?() :: boolean()
  def settings_only?, do: System.get_env("SWARM_SETTINGS_ONLY") == "1"

  @doc false
  @spec settings_open() :: String.t() | nil
  def settings_open do
    if settings_only?(), do: open_query(System.get_env("SWARM_SETTINGS_OPEN") || ""), else: nil
  end

  # The reducer refuses an Init whose query is over 200 bytes or holds a
  # control character; such a query (the launcher refuses it first) opens
  # the Overview instead.
  defp open_query(query) do
    query = String.trim(query)

    if byte_size(query) <= 200 and String.valid?(query) and
         query
         |> String.to_charlist()
         |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F and not (&1 >= 0x80 and &1 <= 0x9F))),
       do: query,
       else: ""
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

  defp run_ui(session, executable, resume_picker?) do
    # cli020 B10: folders a hard exit left behind go first.
    _ = SwarmCodeCLI.Release.SocketSweep.sweep()
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
          first_run_notice: session[:notice] || session[:setup_notice]
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

      # pass73 T1/T2/T9: cli.json (read here, before the session starts) and
      # the environment decide the theme, the wheel and the diffs; pass74
      # S1-13: the launch's terminal comes from one `launch/4` (§3.8.4).
      cli_path = SwarmCodeCLI.Release.preferences_path()
      preferences = SwarmCodeCLI.UI.Init.Preferences.read(cli_path)
      launch = launch(System.get_env(), cli_path, preferences, settings_mode())
      put_accent(launch.accent)

      caps = %Capabilities{
        size: %Size{columns: 80, rows: 24},
        stdin_tty?: true,
        stdout_tty?: true,
        color_mode: launch.color_mode,
        ascii?: launch.ascii?,
        # pass71 F4: the rich tier (thin rails, V1) where the terminal has it.
        glyph_tier: launch.glyph_tier,
        ambiguous_width: launch.ambiguous_width,
        reduced_motion?: launch.reduced_motion?
      }

      init = %Init{
        focus: "composer",
        size: caps.size,
        capabilities: caps,
        source_epoch: source_epoch,
        destination: {:conversation, conversation_id},
        banner: :persisted_banner,
        now: System.system_time(:millisecond),
        keymap: launch.keymap,
        panel_mode: preferences.panel_mode,
        show_diffs: preferences.show_diffs,
        agent_summaries?: preferences.agent_summaries?,
        theme_mode: launch.theme,
        theme_env: launch.theme_env,
        mouse?: launch.mouse?
      }

      # pass74 S1-13: the settings layer's boot query, the cli values, the
      # launch facts and cli.json's `ask` (U1's `Init` fields; a build without
      # them ignores the keys).
      init =
        struct(init,
          settings_open: settings_open() || session[:open_settings],
          prefs: launch.prefs,
          launch_facts: launch_facts(launch, session.project.root_path, cli_path),
          resume_picker?: resume_picker?
        )

      runtime =
        child!(supervisor, SessionRuntime,
          init: init,
          data_source: source,
          frame_ms: 33,
          close_ms: 3000,
          wall_clock: true,
          instruction_sink: self(),
          # pass72 P6: the panel's shape persists in cli.json beside the database.
          preferences_path: SwarmCodeCLI.Release.preferences_path()
        )

      if launch.companion?,
        do: start_companion(supervisor, runtime, Path.basename(session.project.root_path))

      owner =
        child!(supervisor, Owner,
          runtime: runtime,
          capabilities: caps,
          # pass73 T9: wheel reports are on unless `/mouse off` or
          # SWARM_MOUSE=0 said otherwise; with them on, Shift-drag (Option-drag
          # in Terminal.app and iTerm2) still selects text.
          flags: %{
            alternate?: true,
            focus?: true,
            paste?: true,
            mouse?: launch.mouse?
          },
          executable: executable,
          theme: launch.theme,
          # cli020 M2 (E27): the palette cli.json names (`terminal.palette`).
          palette: Map.get(preferences, :palette, :carbon)
        )

      owner_monitor = Process.monitor(owner)
      supervisor_monitor = Process.monitor(supervisor)

      outcome =
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
                   "Run ncode again; your conversation is saved."
                 )}
            after
              0 -> :ok
            end

          {:DOWN, ^owner_monitor, :process, ^owner, reason} ->
            Logger.error("terminal owner stopped: #{inspect(reason)}")

            {:failed,
             failure(
               @exit_failure,
               "The terminal stopped responding, so ncode closed.",
               "Run ncode again; your conversation is saved."
             )}

          {:shutdown_signal, signal} when signal in [:sigterm, :sighup] ->
            Logger.info("closing on #{signal}")
            {:signal, signal}

          {:DOWN, ^supervisor_monitor, :process, ^supervisor, reason} ->
            Logger.error("session supervisor stopped: #{inspect(reason)}")

            {:failed,
             failure(
               @exit_failure,
               "The session stopped unexpectedly, so ncode closed.",
               "Run ncode again; your conversation is saved."
             )}
        end

      # pass71 F21: the summary describes the conversation on screen at the
      # end (after /new or /resume), not the one the session opened with.
      {outcome, current_conversation(runtime, conversation_id)}
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

  defp current_conversation(runtime, fallback) do
    case SessionRuntime.snapshot(runtime) do
      %{destination: {:conversation, id}} when is_binary(id) -> id
      _ -> fallback
    end
  catch
    :exit, _ -> fallback
  end

  # The visual companion mirrors this session on a loopback port; the palette's
  # "Open visual companion" shows the URL. SWARM_COMPANION=0 (or cli.json's
  # `companion`, §3.8.4) leaves it out, and the URL is never printed here
  # because it carries the session token.
  defp start_companion(supervisor, runtime, project) do
    companion = child!(supervisor, Companion, runtime: runtime, project: project)
    SessionRuntime.attach_companion(runtime, Companion.sink(companion))
  end

  @doc """
  pass74 S1-13 (§3.8.4): the launch's terminal: U3's
  `TerminalPreferences.launch/4` (the environment, `CliFile.read_all/1`'s
  snapshot, the desktop's mode, no flags: the launcher turns them into
  `SWARM_CONVERSATION`). A failure of those rules falls back to today's rules
  in the same shape, with one logged error.
  """
  @spec launch(map(), Path.t() | nil, map(), term()) :: map()
  def launch(env, cli_path, preferences, desktop_mode) when is_map(env) do
    snapshot = SwarmCode.Settings.CliFile.read_all(cli_path)

    try do
      TerminalPreferences.launch(env, snapshot, desktop_mode, %{})
    rescue
      error ->
        Logger.error("terminal preferences failed: #{Exception.format(:error, error)}")
        today(env, snapshot, preferences, desktop_mode)
    end
  end

  defp today(env, snapshot, preferences, desktop_mode) do
    color_mode = color_mode(env)
    ascii? = ascii?(env)
    start = start_preferences(env, preferences, desktop_mode)

    start
    |> Map.take(@passthrough_preferences)
    |> Map.merge(%{
      theme: start.theme,
      theme_env: start.theme_env,
      mouse?: start.mouse?,
      keymap: Init.keymap_from_env(Map.get(env, "SWARM_KEYMAP")),
      color_mode: color_mode,
      ascii?: ascii?,
      glyph_tier: Capabilities.glyph_tier(color_mode, :narrow, ascii?, Map.get(env, "TERM")),
      ambiguous_width: :narrow,
      reduced_motion?: false,
      accent: nil,
      companion?: Map.get(env, "SWARM_COMPANION") != "0",
      startup_conversation: :latest,
      prefs: snapshot.values,
      env_overrides: %{},
      flag_overrides: %{},
      warnings: []
    })
  end

  @doc "pass74 S1-13: what the settings layer shows about this launch (§3.8.3)."
  @spec launch_facts(map(), Path.t(), Path.t() | nil) :: map()
  def launch_facts(launch, root, cli_path) do
    %{
      env_overrides: launch.env_overrides,
      flag_overrides: launch.flag_overrides,
      flags: %{},
      project_root: root,
      log_path: log_path(nil),
      cli_path: cli_path,
      cli_version: Application.spec(:swarm_code_cli, :vsn) |> to_string(),
      home: System.user_home()
    }
  end

  # The accent is process-wide for the launch: written once, before the port
  # owner starts (U3's `Theme.put_accent/1`).
  defp put_accent(accent) do
    SwarmCodeCLI.UI.Theme.put_accent(accent)
    :ok
  end

  @doc """
  pass74 S1-13 (§3.8.4): the conversation a TUI session opens and whether it
  asks first. A flag or `SWARM_CONVERSATION` chooses; else cli.json's
  `startup_conversation` (`ask` opens the latest with the resume picker over
  it). A settings-only session opens the latest (it never starts a new one).
  """
  @spec tui_selection() :: {:latest | :new | String.t(), boolean()}
  def tui_selection do
    cond do
      # cli020 B19: bare `ncode --resume` opens the latest with the picker over it.
      System.get_env("SWARM_RESUME_PICKER") == "1" and not settings_only?() ->
        {:latest, true}

      System.get_env("SWARM_CONVERSATION") in [nil, ""] and not settings_only?() ->
        startup_selection(SwarmCodeCLI.Release.preferences_path())

      true ->
        {selection_from_env(), false}
    end
  end

  @doc false
  @spec startup_selection(Path.t() | nil) :: {:latest | :new, boolean()}
  def startup_selection(cli_path) do
    case SwarmCode.Settings.CliFile.read_all(cli_path).values["startup_conversation"] do
      "new" -> {:new, false}
      "ask" -> {:latest, true}
      _ -> {:latest, false}
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
          say(
            :stderr,
            "ncode closed its database with one native handle still pending; saved data is safe."
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

  @doc false
  # cli020 B21: `summary/3` for tests (`exchanges:` replaces cli.json's N).
  def exit_summary(session, started_at, opts \\ []), do: summary(session, started_at, opts)

  @doc """
  cli020 B21 (E26's `exit_transcript`, 0..20, default 3): how many of the
  last exchanges the exit summary prints, from cli.json's values.
  """
  @spec exit_transcript(map()) :: 0..20
  def exit_transcript(values) when is_map(values) do
    case Map.get(values, "exit_transcript") do
      n when is_integer(n) and n in 0..20 -> n
      _ -> 3
    end
  end

  @exchange_bytes 4_000
  @transcript_bytes 24 * 1024

  # Plain SQL: this app does not depend on Ecto at compile time.
  defp summary(session, started_at, opts \\ []) do
    id = session.conversation.id
    since = DateTime.to_iso8601(started_at)

    n =
      Keyword.get_lazy(opts, :exchanges, fn ->
        SwarmCodeCLI.Release.preferences_path()
        |> SwarmCode.Settings.CliFile.read_all()
        |> Map.get(:values, %{})
        |> exit_transcript()
      end)

    title = scalar("SELECT title FROM conversations WHERE id = ?1", [id])

    prompt =
      scalar(
        "SELECT content FROM messages WHERE conversation_id = ?1 AND role = 'user' " <>
          "ORDER BY position DESC LIMIT 1",
        [id]
      )

    files = net_changed(id, since, session.project.root_path)

    %{
      title: title,
      prompt: prompt,
      exchanges: exchanges(id, n),
      spent: spent(id, since, started_at),
      files: Enum.map(files, &Path.relative_to(&1, session.project.root_path)),
      root: session.project.root_path,
      conversation: id
    }
  rescue
    error ->
      Logger.error("exit summary: #{Exception.message(error)}")

      %{
        title: nil,
        prompt: nil,
        files: [],
        root: session.project.root_path,
        conversation: session.conversation.id
      }
  end

  # cli022 F5: the session's net change. Every write leaves a checkpoint row
  # (the file before it), and a rewind restores the files but keeps the rows,
  # so listing the rows called a file `/rewind` put back "changed". The
  # session's first row per path holds the file as it was before the session
  # touched it: a path whose file now equals that (or that did not exist then
  # and does not now) is left out. A row that could not be kept (binary or over
  # 2 MB), a path outside the project, a symlink or an unreadable file stays
  # listed. At most 200 paths, each file read only when its size matches.
  @net_paths 200

  defp net_changed(id, since, root) do
    real_root =
      case SwarmCode.Domain.Tools.Path.real_path(root) do
        {:ok, real} -> real
        _ -> root
      end

    rows(
      "SELECT path, rowid, restorable, previous_content IS NULL, " <>
        "LENGTH(CAST(previous_content AS BLOB)) FROM (SELECT path, rowid, restorable, " <>
        "previous_content, ROW_NUMBER() OVER (PARTITION BY path ORDER BY inserted_at, rowid) " <>
        "AS n FROM checkpoints WHERE conversation_id = ?1 AND inserted_at >= ?2) WHERE n = 1 " <>
        "ORDER BY path LIMIT ?3",
      [id, since, @net_paths]
    )
    |> Enum.flat_map(fn
      [path, rowid, restorable, absent, bytes] when is_binary(path) ->
        if unchanged?(path, rowid, restorable, absent, bytes, [root, real_root]),
          do: [],
          else: [path]

      _row ->
        []
    end)
  end

  defp unchanged?(path, rowid, restorable, absent, bytes, roots) do
    inside? = Enum.any?(roots, &String.starts_with?(path, String.trim_trailing(&1, "/") <> "/"))

    cond do
      restorable in [0, false] or not inside? ->
        false

      absent in [1, true] ->
        File.lstat(path) == {:error, :enoent}

      true ->
        same_content?(path, rowid, bytes)
    end
  end

  defp same_content?(path, rowid, bytes) do
    with {:ok, %File.Stat{type: :regular, size: ^bytes}} <- File.lstat(path),
         {:ok, now} <- File.read(path),
         [[before]] when is_binary(before) <-
           rows("SELECT previous_content FROM checkpoints WHERE rowid = ?1", [rowid]) do
      now == before
    else
      _ -> false
    end
  end

  # cli020 B21 (decision 4d): the last `n` exchanges, newest rows first from
  # SQL, each clipped to 4,000 bytes and 24 KiB in all (the newest kept),
  # returned oldest first.
  defp exchanges(_id, 0), do: []

  defp exchanges(id, n) do
    rows(
      "SELECT role, content FROM messages WHERE conversation_id = ?1 AND superseded_at IS NULL " <>
        "AND role IN ('user','assistant','shell') AND content != '' " <>
        "ORDER BY position DESC LIMIT ?2",
      [id, 2 * n]
    )
    |> Enum.reduce_while({[], 0}, fn
      [role, content], {kept, bytes} when is_binary(content) ->
        text = clip(content, @exchange_bytes)
        bytes = bytes + byte_size(text)

        if bytes > @transcript_bytes,
          do: {:halt, {kept, bytes}},
          else: {:cont, {[{role, text} | kept], bytes}}

      _row, acc ->
        {:cont, acc}
    end)
    |> elem(0)
  end

  defp clip(text, max) when byte_size(text) <= max, do: text
  defp clip(text, max), do: valid_prefix(binary_part(text, 0, max)) <> "…"

  defp valid_prefix(bin) do
    if String.valid?(bin) or bin == "",
      do: bin,
      else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # cli020 B21 (decision 4g): tokens, cost and time of the runs this session
  # started; nil when it started none.
  defp spent(id, since, started_at) do
    case rows(
           "SELECT COALESCE(SUM(tokens_in),0), COALESCE(SUM(tokens_out),0), SUM(cost_usd), " <>
             "COUNT(cost_usd), COUNT(*) FROM runs WHERE conversation_id = ?1 AND inserted_at >= ?2",
           [id, since]
         ) do
      [[tokens_in, tokens_out, cost, costed, count]] when is_integer(count) and count > 0 ->
        %{
          tokens: (tokens_in || 0) + (tokens_out || 0),
          cost: if(costed == count, do: cost),
          seconds: max(DateTime.diff(DateTime.utc_now(), started_at), 0)
        }

      _ ->
        nil
    end
  end

  @doc false
  def spent_line(%{tokens: tokens, cost: cost, seconds: seconds}) do
    [tokens_words(tokens), cost && cost_words(cost), duration(seconds)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp tokens_words(n) when n < 1_000, do: "#{n} tokens"
  defp tokens_words(n) when n < 1_000_000, do: one_decimal(n / 1_000) <> "k tokens"
  defp tokens_words(n), do: one_decimal(n / 1_000_000) <> "M tokens"

  defp one_decimal(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  defp cost_words(cost) when is_number(cost) and cost < 0.01, do: "<$0.01"

  defp cost_words(cost) when is_number(cost),
    do: "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 2)

  defp cost_words(_), do: nil

  defp duration(s) when s < 60, do: "#{s}s"
  defp duration(s) when s < 3_600, do: "#{div(s, 60)}m #{rem(s, 60)}s"

  defp duration(s),
    do:
      "#{div(s, 3_600)}h #{String.pad_leading(Integer.to_string(div(rem(s, 3_600), 60)), 2, "0")}m"

  # The exchanges as lines: `› ` for a prompt, `$ ` for a shell row (their
  # continuation lines indented two), a reply as is; a blank line before
  # every prompt but the first. Terminal controls never reach the scrollback.
  defp exchange_lines(exchanges) do
    exchanges
    |> Enum.with_index()
    |> Enum.flat_map(fn {{role, text}, index} ->
      lines = text |> scrub() |> String.split("\n")

      body =
        case role do
          "user" -> mark(lines, "› ")
          "shell" -> mark(lines, "$ ")
          _ -> lines
        end

      if index > 0 and role in ["user", "shell"], do: ["" | body], else: body
    end)
  end

  defp mark([first | rest], prefix), do: [prefix <> first | Enum.map(rest, &("  " <> &1))]

  defp scrub(text) do
    text
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)?/u, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/u, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]/u, "")
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

  defp print_summary(summary), do: say(:stdio, summary_text(summary))

  @doc false
  # cli020 B20/B21: the exit summary as written. It starts by erasing the
  # launcher's "Starting ncode…" line, then the last exchanges, then the block.
  def summary_text(summary) do
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
        summary[:spent] && "  " <> label.("Spent") <> spent_line(summary[:spent]),
        files != [] && "  " <> label.("Files changed") <> files_line(files),
        stopped != [] && "  " <> label.("Stopped") <> stopped_lines(stopped),
        notice && "  " <> label.("Note") <> notice,
        "  " <> label.("Resume") <> resume_command(summary[:root], summary[:conversation]),
        ""
      ]
      |> Enum.filter(&is_binary/1)

    transcript =
      case exchange_lines(summary[:exchanges] || []) do
        [] -> ""
        lines -> Enum.join(lines, "\n") <> "\n"
      end

    "\r\e[2K" <> transcript <> Enum.join(lines, "\n")
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

  @doc false
  def unknown_model_words(model) do
    case one_line(model) do
      nil -> "No provider offers the model given with --model."
      name -> "No provider offers the model " <> inspect(String.slice(name, 0, 120)) <> "."
    end
  end

  # pass71 F18 (review R20): the hint names this conversation; `--continue`
  # opened whichever was newest by then (a later `-p` one, another window's).
  @doc false
  def resume_command(root, conversation \\ nil) do
    here = System.get_env("PWD")

    flag =
      if is_binary(conversation) and conversation =~ ~r/\A[0-9a-fA-F-]{36}\z/,
        do: "--resume " <> conversation,
        else: "--continue"

    if root == nil or root == here,
      do: "ncode " <> flag,
      else: "ncode " <> shell_quote(root) <> " " <> flag
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

  defp outcome_status({:signal, signal}) do
    say(:stderr, "ncode: " <> SwarmCodeCLI.Release.Signals.words(signal))
    SwarmCodeCLI.Release.Signals.exit_code(signal)
  end

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
        "ncode stopped unexpectedly: " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error,
       failure(
         @exit_failure,
         "ncode stopped unexpectedly.",
         "Run it again; your conversation is saved."
       )}
  end

  defp fail!(status, message, action), do: throw({__MODULE__, failure(status, message, action)})

  defp failure(status, message, action), do: %{status: status, message: message, action: action}

  defp preflight! do
    unless System.argv() == [],
      do: fail!(@exit_usage, "unexpected arguments.", "Run ncode --help.")

    unless (release_tui?() or :init.get_argument(:noinput) != :error) and
             :prim_tty.isatty(:stdin) == true and
             :prim_tty.isatty(:stdout) == true and
             System.get_env("TERM") not in [nil, "", "dumb"],
           do:
             fail!(
               @exit_usage,
               "ncode needs an interactive terminal.",
               ~s(In pipes and scripts use ncode -p "prompt" or ncode --plain.)
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
          "The ncode terminal helper is missing.",
          "Reinstall ncode (curl -fsSL https://code.llmotions.com/install.sh | sh), or build it in a checkout with scripts/dev/check_terminal_port.sh."
        )
  end

  defp start_applications! do
    for app <- [:req, :swarm_code_core, :swarm_code_cli, :swarm_code_daemon] do
      case Application.ensure_all_started(app) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("application #{app} did not start: #{inspect(reason)}")
          fail!(@exit_failure, "ncode could not start.", "Reinstall ncode.")
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
    # pass74 S1-14: `ncode config` answers a held lease with its own words.
    @exit_refused |> failure(message, action) |> Map.put(:code, error.code)
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
      {"The ncode app is open, and only one of them can use your conversations at a time.",
       "Quit the ncode app, then run ncode again."}

  defp startup_words(:data_lease_held, _error, boot) do
    if settings_only?(),
      do: {lease_words(boot, :settings), ""},
      else:
        {lease_holder(boot),
         "Close it first (Ctrl-C twice, and once more if it asks), then run ncode again."}
  end

  # The allowlist's two refusals (pass70 D2: an upgrade only the app makes, a
  # database from a newer app), the gate's stray-file and damaged-file ones
  # (Q13) and the mode refusal (cli020 fix S4) already say what to do; any
  # other schema failure gets the general sentence.
  defp startup_words(:schema_incompatible, error, _boot) do
    refusals = [
      SwarmCode.Daemon.Schema.Refusal.desktop_upgrade_required(),
      SwarmCode.Daemon.Schema.Refusal.database_ahead(),
      SwarmCode.Daemon.Schema.Refusal.not_a_database(),
      SwarmCode.Daemon.Schema.Refusal.damaged(),
      # cli020 fix S4: one sentence, the path travels in the action.
      SwarmCode.Daemon.Schema.Refusal.database_mode("")
    ]

    if Enum.any?(refusals, &(&1.message == error.message)),
      do: {error.message, error.action},
      else:
        {"Your conversations database comes from an ncode version this ncode does not know.",
         "Update ncode, or open the ncode app once to upgrade the database. Nothing was changed."}
  end

  defp startup_words(code, _error, _boot)
       when code in [:private_directory_failed, :path_resolution_failed, :lease_failed],
       do:
         {"ncode could not safely open its private data folder.",
          "Check that ~/Library/Application Support/SwarmCode belongs to you and has mode 0700."}

  defp startup_words(:macos_platform_helper_unavailable, _error, _boot),
    do:
      {"ncode could not check whether the ncode app is running.",
       "Reinstall ncode: curl -fsSL https://code.llmotions.com/install.sh | sh"}

  defp startup_words(code, _error, _boot) when code in [:backup_failed, :backup_unverified],
    do:
      {"ncode could not make a verified backup before upgrading the database, so it changed nothing.",
       "Free some disk space and run ncode again."}

  defp startup_words(_code, error, _boot), do: {error.message, error.action}

  defp storage_words(reason) when reason in [:migration_failed, :migration_timeout],
    do:
      {"ncode could not upgrade the database; it was left as it was.",
       "Your verified backup is in the backups folder beside your conversations database. Open the ncode app, or report this."}

  defp storage_words(_reason),
    do:
      {"ncode could not open your conversations database.",
       "Close other ncode windows and run ncode again."}

  # pass74 S1-13 (D11): the exit-3 words name the settings command.
  defp session_failure(:provider_required, _),
    do:
      failure(
        @exit_refused,
        "No model provider is set up yet.",
        "Run 'ncode settings providers' to add one, or set NCODE_MODEL, NCODE_BASE_URL and NCODE_API_KEY in ~/.secrets (the older SWARM_* names still work)."
      )
      |> Map.put(:reason, :provider_required)

  # cli020 B13 (onboarding-4): a first run from the environment that lacks
  # an endpoint or a model says which.
  defp session_failure(:endpoint_required, _),
    do:
      failure(
        @exit_refused,
        "NCODE_BASE_URL is missing (OpenAI-compatible URLs end in /v1).",
        "Set NCODE_BASE_URL, or run 'ncode settings providers'."
      )
      |> Map.put(:reason, :endpoint_required)

  defp session_failure(:model_required, _),
    do:
      failure(
        @exit_refused,
        "NCODE_MODEL is missing.",
        "Set NCODE_MODEL to a model of your provider, or run 'ncode settings providers'."
      )
      |> Map.put(:reason, :model_required)

  # pass71 F19 (review R17): the sentence names the model that was given.
  defp session_failure(:unknown_model, _),
    do:
      failure(
        @exit_usage,
        unknown_model_words(System.get_env("SWARM_MODEL_OVERRIDE")),
        "Use a model from /model, or provider/model."
      )

  defp session_failure(:conversation_not_found, _),
    do:
      failure(
        @exit_usage,
        "That conversation is not part of this project.",
        "Use ncode --continue, or --resume with an id from this project."
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
      "ncode could not open the conversation.",
      "Run ncode again; nothing was changed."
    )
  end

  @doc false
  # pass74 S1-13/S1-14: a settings change while another session holds the
  # data. The owner record names its process, not its folder.
  @spec lease_words(term(), :settings | :config) :: String.t()
  def lease_words(boot, :settings),
    do:
      "A ncode session is open (#{lease_process(boot)}); change settings there with /settings, or close it first."

  def lease_words(boot, :config),
    do:
      "A ncode session is open (#{lease_process(boot)}); change it there with /settings, or close it first."

  defp lease_process(boot) do
    with {:ok, paths} <- paths_for(boot),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 32_768 <-
           File.lstat(paths.owner_record),
         {:ok, body} <- File.read(paths.owner_record),
         {:ok, %{"pid" => pid}} when is_integer(pid) <- Jason.decode(body) do
      "process #{pid}"
    else
      _ -> "another process"
    end
  rescue
    _ -> "another process"
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

      "Another ncode (process #{pid}#{since}) is already using your conversations."
    else
      _ -> "Another ncode is already using your conversations."
    end
  rescue
    _ -> "Another ncode is already using your conversations."
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
      _ = :logger.remove_handler(:default)

      case :logger.add_handler(:default, :logger_std_h, log_handler(path)) do
        :ok -> :ok
        {:error, _} -> quiet_console()
      end
    else
      _ -> quiet_console()
    end
  end

  # pass72 F: the filters are explicit. A handler added as `:default` without
  # them gets OTP's default-handler filters (`filter_default: :stop`, log only
  # the otp/sasl domains), which dropped every `Logger` call of the app (domain
  # `[:elixir]`) and left cli.log with nothing but OTP reports, so a session
  # that closed on "the daemon connection closed" never said why.
  @doc false
  def log_handler(path) do
    %{
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: @log_bytes,
        max_no_files: @log_files
      },
      level: :info,
      filter_default: :log,
      filters: [remote_gl: {&:logger_filters.remote_gl/2, :stop}],
      formatter: Logger.default_formatter(colors: [enabled: false])
    }
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

      # cli020 B19: an id, an id prefix or a title (`open_session/3` resolves it).
      value ->
        value
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
        fail!(@exit_failure, "ncode could not start its session.", "Run it again.")
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
          "ncode could not create its private socket folder.",
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

  @doc """
  pass73 T2/T9: the theme and the wheel a session starts with, from the
  environment, `cli.json` (`Init.Preferences.read/1`) and the desktop's
  settings mode. The theme is `SWARM_THEME` > cli.json (`/theme`) > the
  desktop's mode > dark; `theme_env` names the theme `SWARM_THEME` set (so
  `/theme` can say it wins at the next launch). Wheel reports are
  `SWARM_MOUSE=0|1` > cli.json (`/mouse`) > off (cli020 E26/D5).
  """
  @spec start_preferences(map(), map(), term()) :: %{
          theme: :dark | :light,
          theme_env: :dark | :light | nil,
          mouse?: boolean()
        }
  def start_preferences(env, preferences, settings_mode) when is_map(env) do
    theme_env =
      case env |> Map.get("SWARM_THEME", "") |> String.trim() |> String.downcase() do
        "dark" -> :dark
        "light" -> :light
        _ -> nil
      end

    fallback = Map.get(preferences, :theme) || settings_mode

    mouse? =
      case env |> Map.get("SWARM_MOUSE", "") |> String.trim() |> String.downcase() do
        value when value in ["1", "on", "true", "yes"] -> true
        value when value in ["0", "off", "false", "no"] -> false
        _ -> Map.get(preferences, :mouse?, false) == true
      end

    preferences
    |> Map.take(@passthrough_preferences)
    |> Map.merge(%{
      theme: theme_env || SwarmCodeCLI.UI.Theme.mode(nil, fallback),
      theme_env: theme_env,
      mouse?: mouse?
    })
  end

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

  # D21: NO_COLOR counts when it is present and not empty (no-color.org).
  defp color_mode(env) do
    cond do
      Map.get(env, "NO_COLOR") not in [nil, ""] -> :monochrome
      Map.get(env, "COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      String.contains?(Map.get(env, "TERM") || "", "256color") -> :ansi256
      true -> :ansi16
    end
  end
end
