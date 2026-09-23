defmodule SwarmCode.Domain.Tools.RunCommand do
  @moduledoc "Runs a shell command in the project root with streamed detail, a hard timeout and bounded output."
  @behaviour SwarmCode.Domain.Tools.Tool

  @impl true
  def name, do: "run_command"

  @impl true
  # Spec 54 §5 (54c H9): closed stdin and head/tail truncation are both real and
  # both were undocumented. Spec 66 T1/T6: so are the two sentences at the end —
  # a daemon the model starts survives the call, and the environment it sees has
  # the secrets taken out of it.
  def description,
    do:
      "Run a shell command in the project root and return its exit code with " <>
        "its combined stdout and stderr. stdin is closed, so a command that waits for input " <>
        "(an editor, an interactive prompt, a bare git commit) gets EOF rather than hanging. " <>
        "Output over 160 000 characters comes back as its head and tail with the number of " <>
        "bytes and lines dropped from the middle (max_output_chars raises that to 512 000), " <>
        "so pipe long output through a filter rather than " <>
        "dumping it. The command runs to the timeout configured in Settings and is killed, " <>
        "with its whole process tree, when it expires or the agent is stopped. " <>
        "A command that ends while leaving a background process running returns as soon as " <>
        "the command itself exits, whether or not that process keeps printing; the " <>
        "background process is left running and is not killed. " <>
        "A command still running after yield_ms (10 seconds by default) is not killed either: " <>
        "it keeps running in the background and the call returns \"exit code pending\" with " <>
        "the output so far and the os pid to poll — so starting a server and then curling it " <>
        "takes two calls, not a timeout. Call this tool again with poll: <os pid> for more " <>
        "of its output and its exit code once it has one, and stop: <os pid> to kill it. " <>
        "Variables whose name looks like a secret are removed from the environment unless " <>
        "Settings → Limits keeps them."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "Shell command to run"
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Optional timeout in milliseconds. Only used when it is LONGER than the " <>
              "configured command timeout (Settings → Limits); shorter values are ignored. " <>
              "Maximum 600000."
        },
        # spec 66 T7: one `cd apps/web && …` per call was pure tax on a monorepo.
        "workdir" => %{
          "type" => "string",
          "description" =>
            "Directory to run in, relative to the project root. Defaults to the project root."
        },
        # spec 67 G31: the cap used to be 20 000 characters at collection time,
        # so `mix test` with 40 failures came back as #1 and #40 and nothing
        # could ask for more. Codex keeps 1 MiB and budgets per call.
        "max_output_chars" => %{
          "type" => "integer",
          "description" =>
            "Optional cap on the characters of output returned (2000–512000, default 160000). " <>
              "The head and the tail are kept and the middle is dropped with a marker saying " <>
              "how many bytes and lines went."
        },
        # spec 67 G25: Codex's `yield_time_ms` — a foreground command that is
        # still running when the yield passes is handed to the background
        # instead of being blocked on to the timeout and then killed.
        "yield_ms" => %{
          "type" => "integer",
          "description" =>
            "Optional milliseconds to wait before handing a still-running command to the " <>
              "background (default 10000, minimum 1000). Raise it for a build or a test run " <>
              "you want to wait out in one call."
        },
        "poll" => %{
          "type" => "integer",
          "description" =>
            "Instead of running a command: the os pid of a background process this run left " <>
              "behind. Returns everything it has printed since the last poll, and its exit " <>
              "code once it has finished."
        },
        "stop" => %{
          "type" => "integer",
          "description" =>
            "Instead of running a command: the os pid of a background process to kill, " <>
              "with its whole process tree."
        },
        # spec 66 T3: never executed — it is what the approval card shows the user.
        "justification" => %{
          "type" => "string",
          "description" =>
            "One sentence the user will read when this command needs approval: why you are " <>
              "running it and what it will change. Required for anything that writes, " <>
              "installs, pushes or deletes."
        }
      },
      # spec 67 G25: `command` is required *unless* the call is a poll or a stop
      # of something this run already started, which `run/3` enforces. A schema
      # that made `command` unconditionally required made those two unusable.
      "required" => []
    }
  end

  @impl true
  # Reading more of the output of a process this run started is a read; killing
  # one is not.
  def permission(args) do
    poll? = pid_arg(args, "poll") != nil
    stop? = pid_arg(args, "stop") != nil

    if poll? and not stop? and blank?(args["command"]), do: :read, else: :execute
  end

  @impl true
  def title(args) do
    cond do
      pid = pid_arg(args, "stop") ->
        "stop background process #{pid}"

      pid = pid_arg(args, "poll") ->
        "poll background process #{pid}"

      true ->
        head = "run: " <> String.slice(to_string(args["command"] || ""), 0, 60)

        case args["workdir"] do
          dir when is_binary(dir) and dir != "" -> head <> " (in #{String.slice(dir, 0, 40)})"
          _ -> head
        end
    end
  end

  # A provider that streams its arguments as JSON text sends `"poll": "1234"`
  # about as often as `1234`.
  defp pid_arg(args, key) do
    case Map.get(args, key) do
      n when is_integer(n) and n > 1 ->
        n

      s when is_binary(s) ->
        case Integer.parse(String.trim(s)) do
          {n, ""} when n > 1 -> n
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp blank?(value), do: String.trim(to_string(value || "")) == ""

  @doc """
  The timeout of one call, in milliseconds (spec 07 §10).

  `settings.command_timeout_ms` is the floor, not a suggestion: models routinely
  ask for `timeout_ms: 30000` and that — not any hard-coded value — is what
  produced `command timed out after 30000 ms`. A model may still *raise* the
  timeout for something it knows is slow, up to the 600 s hard cap.
  """
  @spec timeout_for(map(), map()) :: {pos_integer(), pos_integer()}
  def timeout_for(args, ctx) do
    configured =
      (Map.get(ctx, :settings) && Map.get(ctx.settings, :command_timeout_ms)) || 120_000

    asked = args["timeout_ms"]
    asked = if is_integer(asked) and asked > 0, do: asked, else: 0

    {min(max(asked, configured), 600_000), configured}
  end

  @no_command "run_command needs a command — or poll: / stop: with the os pid of a " <>
                "background process this run started."

  @impl true
  def run(args, ctx, progress) do
    cond do
      pid = pid_arg(args, "stop") -> stop_background(pid, ctx, progress)
      pid = pid_arg(args, "poll") -> poll_background(pid, args, ctx, progress)
      blank?(args["command"]) -> {:error, @no_command}
      true -> run_command(args, ctx, progress)
    end
  end

  # ------------------------------------------------------------------ T25: poll and stop

  defp poll_background(os_pid, args, ctx, progress) do
    run_id = Map.get(ctx, :run_id)
    progress.(nil, "polling #{os_pid}")

    case SwarmCode.Domain.Tools.BackgroundProcs.poll(run_id, os_pid) do
      {:ok, %{status: nil} = read} ->
        progress.(100, "still running")

        {:ok,
         "exit code pending\n" <>
           poll_body(read, args) <>
           "\n[SwarmCode: background process #{os_pid} is still running; poll: #{os_pid} " <>
           "again for more output, stop: #{os_pid} kills it]"}

      {:ok, %{status: status} = read} ->
        progress.(100, "exit code #{status}")

        {:ok,
         "exit code #{status}\n" <>
           poll_body(read, args) <>
           "\n[SwarmCode: background process #{os_pid} has finished and is now forgotten]"}

      {:error, :unknown} ->
        {:error, unknown_background(os_pid)}
    end
  end

  defp stop_background(os_pid, ctx, progress) do
    run_id = Map.get(ctx, :run_id)
    progress.(nil, "stopping #{os_pid}")

    case SwarmCode.Domain.Tools.BackgroundProcs.stop(run_id, os_pid) do
      :ok ->
        progress.(100, "stopped #{os_pid}")
        {:ok, "stopped background process #{os_pid} and everything it had started"}

      {:error, :unknown} ->
        {:error, unknown_background(os_pid)}
    end
  end

  defp unknown_background(os_pid),
    do:
      "no background process #{os_pid} in this run — it has already finished and been " <>
        "collected, or it belongs to another run"

  defp poll_body(%{output: "", dropped: 0}, _args), do: "(no new output)"

  defp poll_body(%{output: output, dropped: dropped}, args) do
    limit = output_limit(args)

    buffers = %{
      head: [output],
      head_size: byte_size(output),
      tail: tail_new(),
      total: byte_size(output)
    }

    text = body(output(Map.put(buffers, :lines, newlines(output)), limit))

    if dropped > 0,
      do:
        "…[#{dropped} bytes printed before this poll were dropped from the 64 KB buffer]\n" <>
          text,
      else: text
  end

  defp run_command(args, ctx, progress) do
    {timeout, configured} = timeout_for(args, ctx)

    # When the agent (and therefore this op task) is stopped, the supervisor sends us an
    # exit signal; trapping it lets us kill the OS process instead of leaking it.
    Process.flag(:trap_exit, true)

    with {:ok, cd} <- workdir(args, ctx) do
      # spec 66 T1: the shell writes its exit status here on the way out, so a
      # command that leaves a background process holding stdout still reports one.
      rc_file = rc_file()

      try do
        spawn_and_collect(args, ctx, cd, rc_file, {timeout, configured}, progress)
      after
        File.rm(rc_file)
        File.rm(jobs_file(rc_file))
      end
    end
  end

  defp spawn_and_collect(args, ctx, cd, rc_file, {timeout, configured}, progress) do
    settings = Map.get(ctx, :settings) || %{}
    {shell, shell_args} = shell(settings, script(args["command"], rc_file))

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: shell_args,
        cd: String.to_charlist(cd),
        env: clean_env(settings)
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    progress.(nil, "running")

    case collect(port, watch(args, ctx, rc_file, port), deadline, progress) do
      {:ok, status, output} ->
        progress.(100, "exit code #{status}")
        {:ok, "exit code #{status}\n" <> body(output)}

      # spec 66 T1 / spec 67 B1: the command is over, something it started still
      # holds the pipe. The port goes to a janitor process that reads and throws
      # the rest away — closing it would send the survivor SIGPIPE/EPIPE, which
      # kills a Node or Python server the model started on purpose.
      {:drained, drained_ms, pids, output} ->
        head = exit_line(read_rc(rc_file))
        progress.(100, head)

        {:ok,
         head <>
           "\n" <>
           body(output) <>
           "\n[SwarmCode: the command exited but left a background process running " <>
           "(#{pid_list(pids)}); SwarmCode stopped reading its output after #{drained_ms} ms " <>
           "and left it running — anything it prints from now on is discarded]"}

      # spec 67 G25: the yield passed and the command is still running. It is
      # not killed — it goes on in the background with the janitor reading it,
      # and the model gets the os pid to poll. "Start the server, then curl it"
      # used to cost the whole timeout and then kill the server.
      {:yielded, os_pid, output} ->
        head = "exit code pending"
        progress.(100, "running in the background (#{os_pid})")

        {:ok,
         head <>
           "\n" <>
           body(output) <>
           "\n[SwarmCode: still running as background process #{os_pid}; run_command with " <>
           "poll: #{os_pid} returns more output, stop: #{os_pid} kills it]"}

      # spec 66 T2: the last thing a hung `mix test` printed is the whole point.
      {:timeout, output} ->
        {:error,
         "command timed out after #{timeout} ms — raise Settings → Limits → " <>
           "Command timeout (now #{configured} ms). Output before the timeout:\n" <>
           body(output)}
    end
  end

  defp body(output), do: String.replace_invalid(output)

  defp pid_list([]), do: "pid unknown"
  defp pid_list(pids), do: "pid " <> Enum.map_join(pids, ", ", &Integer.to_string/1)

  defp exit_line(nil),
    do: "exit code unknown (the command exited without reporting a status)"

  defp exit_line(status), do: "exit code #{status}"

  # ------------------------------------------------------------------ T1: the status file

  defp rc_file do
    Elixir.Path.join(
      System.tmp_dir!(),
      "swarm_code_rc_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    )
  end

  # Three lines: today's stdin close, the command, and the status handshake.
  # `$?` after the command is the status `sh -c` would have returned; a command
  # that ends in a bare `\` or calls `exec` never reaches line three and takes
  # the unknown-status path.
  # `command` is concatenated, not `to_string/1`-ed: a provider that streams a
  # non-string `command` still raises here and the model is told the call
  # crashed, exactly as before this task (`failure_test.exs:72`).
  defp script(command, rc_file) do
    # Spec 51 §7.3 (R18): the port's stdin is a pipe nobody ever writes to, so
    # `cat`, `git commit` without `-m`, `python`, `npm init`, `ssh` and `sudo`
    # sat `running` for the whole timeout waiting for input that never came.
    # `exec </dev/null` gives them EOF on the first read instead.
    # spec 67 G30: `jobs -p` is the only portable way to learn the pid of what
    # the command left behind — once the shell exits, a survivor is re-parented
    # to launchd and nothing links it to this call any more. It is written
    # before the status file, so a status file means the job list is complete.
    "exec </dev/null\n" <>
      command <>
      "\n" <>
      ~s(__sc_rc=$?; jobs -p > ") <>
      jobs_file(rc_file) <>
      ~s(" 2>/dev/null; printf %s "$__sc_rc" > ") <> rc_file <> ~s("; exit "$__sc_rc")
  end

  defp jobs_file(rc_file), do: rc_file <> ".jobs"

  # `sh`, `dash` and `bash` print one bare pid per line; `zsh` prints its whole
  # job line ("[1]  + 19603 running    (…)"). Anything else is ignored rather
  # than guessed at — a wrong pid here is a wrong `kill` later.
  @sh_job ~r/^(\d+)$/
  @zsh_job ~r/^\[\d+\]\s*[-+]?\s*(\d+)\b/

  defp read_jobs(rc_file) do
    case File.read(jobs_file(rc_file)) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          line = String.trim(line)

          case Regex.run(@sh_job, line) || Regex.run(@zsh_job, line) do
            [_match, pid] -> [String.to_integer(pid)]
            _none -> []
          end
        end)
        |> Enum.filter(&(&1 > 1))
        |> Enum.uniq()
        |> Enum.filter(&SwarmCode.Domain.OSProcess.alive?/1)

      _error ->
        []
    end
  end

  defp read_rc(rc_file) do
    with {:ok, text} <- File.read(rc_file),
         {status, ""} <- Integer.parse(String.trim(text)) do
      status
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------------------ T7: the shell

  @shells ~w(zsh bash fish sh dash ksh)

  @doc """
  The shell to run a command with, and its arguments (spec 66 T7).

  `SWARM_CODE_SHELL` overrides everything (the test suite pins it to `/bin/sh`
  so a developer's dotfiles cannot change what a command prints). After that the
  configured `shell_path`, then the user's `$SHELL` — mise, asdf, nvm and brew
  shims live in the user's dotfiles, and a `.app` launched from Finder has none
  of them on `PATH` without a login shell. The `/bin/sh` fallback stays
  non-login, which is byte-for-byte what SwarmCode did before this task.

  spec 67 B10: a non-interactive **login** shell reads the login files —
  `~/.zprofile`, `~/.zlogin`, `~/.bash_profile`, `~/.profile` — and **not**
  `~/.zshrc`, which zsh only reads when it is interactive (zsh(1), "STARTUP/
  SHUTDOWN FILES"). `eval "$(mise activate zsh)"` and `nvm` live in `~/.zshrc`
  by default, so they have to be moved to `~/.zprofile` for a packaged build to
  see them. Codex spawns `-lc` for the same reason and with the same limit
  (`codex-rs/core/src/shell.rs:25`).

  spec 67 B26: the path has to be *executable*, not merely a regular file —
  `/etc/hosts` passed `File.regular?/1`, `Port.open/2` then raised `:eacces`
  and every command of the run failed with a crash instead of falling back.
  """
  @spec shell(map() | struct(), String.t()) :: {String.t(), [String.t()]}
  def shell(settings, script) do
    case shell_path(settings) do
      nil -> {"/bin/sh", ["-c", script]}
      path -> {path, login_args(path, setting(settings, :shell_login, true), script)}
    end
  end

  defp shell_path(settings) do
    executable(System.get_env("SWARM_CODE_SHELL")) ||
      executable(setting(settings, :shell_path, nil)) ||
      detected_shell()
  end

  defp detected_shell do
    path = executable(System.get_env("SHELL"))
    if path && Elixir.Path.basename(path) in @shells, do: path
  end

  defp executable(path) when is_binary(path) and path != "",
    do: if(executable?(path), do: path)

  defp executable(_path), do: nil

  @doc """
  True when `path` is a regular file with an execute bit (spec 67 B26).

  `File.regular?/1` says yes to `/etc/hosts`; `Port.open({:spawn_executable, …})`
  then raises `:eacces`, `Operation` rescues it and the documented fallback to
  `$SHELL`/`/bin/sh` never happened — every command of the run crashed instead.
  `Settings.Setting` refuses such a path where the user can still see it.
  """
  @spec executable?(String.t() | nil) :: boolean()
  def executable?(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  def executable?(_path), do: false

  # fish spells it `-l -c`; every other shell here takes `-lc`. `sh` never runs
  # as a login shell whichever way it was chosen: there is no user rc to pick up
  # (only /etc/profile), and a `dash` that is `sh` rejects `-l` outright — which
  # would turn every command on a Linux box into an error.
  defp login_args(_path, false, script), do: ["-c", script]

  defp login_args(path, _login, script) do
    case Elixir.Path.basename(path) do
      "fish" -> ["-l", "-c", script]
      "sh" -> ["-c", script]
      _other -> ["-lc", script]
    end
  end

  defp setting(settings, key, default) do
    case Map.get(settings, key, default) do
      nil -> default
      value -> value
    end
  end

  # ------------------------------------------------------------------ T7: the working directory

  defp workdir(args, ctx) do
    case args["workdir"] do
      dir when is_binary(dir) and dir != "" ->
        case SwarmCode.Domain.Tools.Path.resolve(ctx.project_root, dir) do
          {:ok, path} ->
            if File.dir?(path),
              do: {:ok, path},
              else: {:error, "workdir is not a directory: #{dir}"}

          {:error, reason} ->
            {:error, reason}
        end

      _none ->
        {:ok, ctx.project_root}
    end
  end

  # Variables the release launcher (erlexec / bin/swarm_code) sets for OUR VM. A child
  # `mix`/`elixir`/`erl` would otherwise pick up this app's embedded ERTS and crash with
  # "cannot get bootfile". `{name, false}` removes a variable from the child's environment.
  @release_env ~w(ROOTDIR BINDIR EMU PROGNAME ERTS_LIB_DIR RELEASE_ROOT RELEASE_NAME RELEASE_VSN
                  RELEASE_COOKIE RELEASE_NODE RELEASE_MODE RELEASE_BOOT_SCRIPT RELEASE_BOOT_SCRIPT_CLEAN
                  RELEASE_TMP RELEASE_DISTRIBUTION RELEASE_COMMAND RELEASE_PROG RELEASE_SYS_CONFIG
                  RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS)

  # spec 66 T6: Erlang's `{env, …}` *extends* the BEAM's environment, so every
  # key the app was launched with — `ANTHROPIC_API_KEY`, `LLMOTIONS_API_KEY` —
  # was visible to `env` in every command the model ran. `{name, false}` removes
  # one. `GITHUB_TOKEN`/`GH_TOKEN` are kept by default so `gh` keeps working.
  @secret_name ~r/(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)/i

  @doc false
  def clean_env(settings \\ %{}) do
    clean_env_base() ++ scrubbed(settings)
  end

  defp scrubbed(settings) do
    if setting(settings, :shell_env_scrub, true) do
      keep = settings |> setting(:shell_env_keep, ["GITHUB_TOKEN", "GH_TOKEN"]) |> MapSet.new()

      for {name, _value} <- System.get_env(),
          not MapSet.member?(keep, name),
          Regex.match?(@secret_name, name),
          do: {String.to_charlist(name), false}
    else
      []
    end
  end

  @doc false
  def clean_env_base do
    # erlexec prepends $BINDIR (and $ROOTDIR/bin) to PATH for our VM. Inside a packaged
    # release those are the embedded ERTS dirs — drop them so the child finds the user's
    # own erl/elixir. In dev, ROOTDIR/bin IS the user's Erlang, so only BINDIR is dropped.
    bindir = System.get_env("BINDIR")
    rootdir = System.get_env("ROOTDIR")
    release? = System.get_env("RELEASE_ROOT") != nil
    drop = Enum.reject([bindir, if(release? and rootdir, do: rootdir <> "/bin")], &is_nil/1)

    path =
      (System.get_env("PATH") || "")
      |> String.split(":")
      |> Enum.reject(&(&1 == "" or &1 in drop))
      |> Enum.join(":")

    [
      {~c"PATH", String.to_charlist(path)},
      # Spec 51 §7.3 (R18): with stdin closed a git that wants credentials would
      # fail on a closed terminal anyway; saying so up front makes the error the
      # model reads ("could not read Username") immediate instead of timed out.
      {~c"GIT_TERMINAL_PROMPT", ~c"0"}
      | Enum.map(@release_env, &{String.to_charlist(&1), false})
    ]
  end

  # The model only ever needs the head and the tail of a long log; anything more
  # just eats the context window (and pushes runs into the turn limit).
  #
  # spec 67 G31: the buffer used to be 20 000 bytes, 15 000 of them head — `mix
  # test` with 40 failures came back as failure #1 and failure #40. Codex keeps
  # 1 MiB and budgets what it hands the model per call; this keeps 512 000 bytes
  # and hands over `max_output_chars` of them (160 000 by default).
  # spec 70 C2
  @cap 512_000
  @head_cap div(@cap, 2)
  @tail_cap div(@cap, 2)
  @min_output 2_000
  @default_output 160_000

  # Spec 13 §11 A-6: the whole accumulator used to be re-serialised on every
  # port chunk just to find the last line — quadratic in the number of chunks,
  # and the buffer itself grew without a bound. `buf` is a rolling 4 KB tail for
  # the progress line.
  #
  # Sakana task 16: the result buffer then kept only the NEWEST chunks, so a
  # long log lost the first diagnostics — exactly what head/tail truncation
  # promises to keep. Two bounded buffers now hold the true head (15,000 bytes,
  # immutable once full) and a rolling true tail (5,000 bytes), with one marker
  # in between when anything was dropped.
  @tail_bytes 4_096

  # spec 66 T1/T19: how the port is watched once the command itself is over.
  # The BEAM delivers `{:exit_status, …}` only at EOF on stdout, which needs
  # *every* writer to close it — a backgrounded grandchild inherits the pipe and
  # pins the op for the whole timeout, and `kill/1` then kills the server the
  # model started on purpose. So: poll for the shell being gone (the status file
  # first — a stat, not a `ps`), then drain for at most @drain_ms, cutting the
  # drain short after @quiet_ms of silence. A command with no survivor still
  # takes the `{:exit_status, …}` path microseconds later, unchanged.
  #
  # spec 67 B1: the poll used to live in the `after` clause alone, so it was
  # reached only after @poll_ms of *silence* — a survivor that keeps printing
  # (`npm run dev &`, `tail -f`, any watcher) delivered a chunk every few ms, so
  # the op sat there until the deadline and then killed the tree. The check now
  # runs on the data path too, throttled to one stat per @poll_ms, and the drain
  # is short: everything the command itself printed is already in the buffer.
  @poll_ms 250
  @quiet_ms 250
  @drain_ms 500
  @alive_every 4
  # spec 73 T101: the progress line is computed at most this often — it used
  # to split the 4 KB tail on every chunk, ahead of the operation's own 50 ms
  # write throttle.
  @progress_ms 50

  defp collect(port, watch, deadline, progress) do
    collect(port, new_buffers(), "", deadline, progress, watch)
  end

  # Everything the drain path needs once the command is gone: what to poll, what
  # to register, how much output to hand back and what to call the survivor.
  defp watch(args, ctx, rc_file, port) do
    %{
      os_pid: SwarmCode.Domain.OSProcess.port_pid(port),
      rc_file: rc_file,
      run_id: Map.get(ctx, :run_id),
      command: to_string(args["command"] || ""),
      limit: output_limit(args),
      gone_at: nil,
      quiet_since: nil,
      ticks: 0,
      last_check: System.monotonic_time(:millisecond),
      progress_at: System.monotonic_time(:millisecond) - @progress_ms,
      yield_at: System.monotonic_time(:millisecond) + yield_ms(args)
    }
  end

  # spec 67 G25: Codex's `yield_time_ms` — 10 s, with a floor so a model cannot
  # ask for a yield the command has no chance of beating. A yield later than the
  # command timeout never happens: the timeout branch fires first, as it always
  # did.
  @default_yield_ms 10_000
  @min_yield_ms 1_000

  defp yield_ms(args) do
    case args["yield_ms"] do
      n when is_integer(n) -> max(n, @min_yield_ms)
      _other -> @default_yield_ms
    end
  end

  defp output_limit(args) do
    case args["max_output_chars"] do
      n when is_integer(n) -> n |> max(@min_output) |> min(@cap)
      _other -> @default_output
    end
  end

  defp new_buffers, do: %{head: [], head_size: 0, tail: tail_new(), total: 0, lines: 0}

  defp collect(port, buffers, tail, deadline, progress, watch) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline - now, 0)
    wait = min(remaining, @poll_ms)

    receive do
      {^port, {:data, data}} ->
        now = System.monotonic_time(:millisecond)
        chunk = IO.iodata_to_binary(data)
        tail = rolling_tail(tail, chunk)
        watch = report(watch, tail, progress, now)
        buffers = push(buffers, chunk)
        watch = polled(%{watch | quiet_since: now}, now)

        # spec 67 B1: a chatty survivor never reaches the `after` clause, so the
        # drain has to be able to end here. spec 67 G25: neither does a command
        # that prints all the way to its yield (`mix phx.server`, `npm run dev`).
        cond do
          watch.gone_at && now - watch.gone_at >= @drain_ms ->
            drained(port, buffers, watch, now)

          is_nil(watch.gone_at) and now >= watch.yield_at ->
            yielded(port, buffers, watch)

          true ->
            collect(port, buffers, tail, deadline, progress, watch)
        end

      {^port, {:exit_status, status}} ->
        {:ok, status, output(buffers, watch.limit)}

      {:EXIT, ^port, _reason} ->
        collect(port, buffers, tail, deadline, progress, watch)

      # A *previous* command's port, closing after its `run/3` returned: the
      # process traps exits and never untraps, so the message can outlive the
      # call that made it. It is not our signal to stop.
      {:EXIT, other, _reason} when is_port(other) ->
        collect(port, buffers, tail, deadline, progress, watch)

      {:EXIT, _from, reason} ->
        kill(port)
        exit(reason)
    after
      wait ->
        tick(port, buffers, tail, deadline, progress, watch, remaining)
    end
  end

  defp tick(port, buffers, tail, deadline, progress, watch, remaining) do
    now = System.monotonic_time(:millisecond)
    watch = polled(watch, now, :always)

    cond do
      # spec 67 B2: the deadline was the *command's*. A status file that says 0
      # is not a timeout however long what it left behind goes on draining —
      # `remaining == 0` used to be tested first, so the exit code was thrown
      # away and `kill_tree/1` killed the survivor.
      watch.gone_at &&
          (now - watch.gone_at >= @drain_ms or now - watch.quiet_since >= @quiet_ms or
             remaining == 0) ->
        drained(port, buffers, watch, now)

      # spec 67 G25: still running when the yield passed. Tested before the
      # deadline, because a yield shorter than the command timeout is the whole
      # point of it; a yield longer than the timeout never fires.
      now >= watch.yield_at ->
        yielded(port, buffers, watch)

      remaining == 0 ->
        kill(port)
        {:timeout, output(buffers, watch.limit)}

      true ->
        collect(port, buffers, tail, deadline, progress, watch)
    end
  end

  # One `command_over?/1` per @poll_ms at most; `:always` on the timer path,
  # which is itself throttled to @poll_ms.
  defp polled(watch, now, mode \\ :throttled)

  defp polled(%{gone_at: gone} = watch, _now, _mode) when not is_nil(gone), do: watch

  defp polled(watch, now, mode) do
    if mode == :always or now - watch.last_check >= @poll_ms do
      watch = %{watch | last_check: now, ticks: watch.ticks + 1}
      if command_over?(watch), do: %{watch | gone_at: now, quiet_since: now}, else: watch
    else
      watch
    end
  end

  # spec 67 B1/G30: hand the port to a janitor instead of closing it — after
  # `Port.close/1` a survivor's next write gets EPIPE, which a shell ignores but
  # Node and Python die on. The janitor reads and discards until the last writer
  # closes the pipe; the registry is what lets Stop reach the survivor later.
  defp drained(port, buffers, watch, now) do
    pids = read_jobs(watch.rc_file)
    hand_over(port, watch, pids, [])
    {:drained, now - watch.gone_at, pids, output(buffers, watch.limit)}
  end

  # spec 67 G25: the yield. The command itself is still running, so the pid to
  # register and to report is the shell's own — killing it kills the whole tree,
  # which is what `stop: <os_pid>` promises. The status and job files are the
  # janitor's to remove: the script has not written them yet.
  defp yielded(port, buffers, watch) do
    os_pid = watch.os_pid || SwarmCode.Domain.OSProcess.port_pid(port)
    hand_over(port, watch, List.wrap(os_pid), [watch.rc_file, jobs_file(watch.rc_file)])
    {:yielded, os_pid, output(buffers, watch.limit)}
  end

  defp hand_over(port, watch, pids, tmp) do
    SwarmCode.Domain.Tools.BackgroundProcs.adopt(port, %{
      run_id: watch.run_id,
      os_pids: pids,
      command: watch.command,
      tmp: tmp
    })
  end

  # The status file appears the instant the command is over; `ps` is the
  # fallback for a command that never reached the handshake, and it runs once a
  # second rather than on every poll.
  defp command_over?(watch) do
    File.exists?(watch.rc_file) or
      (rem(watch.ticks, @alive_every) == 0 and watch.os_pid != nil and
         not SwarmCode.Domain.OSProcess.alive?(watch.os_pid))
  end

  # spec 73 T101
  defp report(watch, tail, progress, now) do
    if now - watch.progress_at >= @progress_ms do
      progress.(nil, last_line(tail))
      %{watch | progress_at: now}
    else
      watch
    end
  end

  defp rolling_tail(tail, chunk) do
    joined = tail <> chunk

    if byte_size(joined) > @tail_bytes,
      do: binary_part(joined, byte_size(joined) - @tail_bytes, @tail_bytes),
      else: joined
  end

  # The head fills once and never changes; everything after it rolls through the
  # tail buffer, so memory stays bounded whatever the command prints.
  defp push(buffers, chunk) do
    room = @head_cap - buffers.head_size
    take = min(room, byte_size(chunk))

    {head, head_size, rest} =
      if take > 0 do
        {[binary_part(chunk, 0, take) | buffers.head], buffers.head_size + take,
         binary_part(chunk, take, byte_size(chunk) - take)}
      else
        {buffers.head, buffers.head_size, chunk}
      end

    {tail, _dropped} = tail_push(buffers.tail, rest, @tail_cap)

    %{
      buffers
      | head: head,
        head_size: head_size,
        tail: tail,
        total: buffers.total + byte_size(chunk),
        # spec 67 G33: the middle is dropped as it streams, so the only moment
        # its lines can be counted is while it goes past.
        lines: buffers.lines + newlines(chunk)
    }
  end

  defp newlines(chunk), do: chunk |> :binary.matches("\n") |> length()

  # spec 73 T101: the rolling tail is a queue of whole chunks with a byte
  # count. `tail <> chunk` followed by `binary_part/3` handed the next append
  # a sub-binary, so every chunk copied the whole 256 KB tail again — a
  # command printing 100 MB in 4 KB chunks moved ~6 GB. Chunks are dropped
  # from the old end while the rest still covers the cap; the exact last
  # `cap` bytes are cut once, when the tail is read (`tail_binary/2`). The
  # background janitor's 64 KB ring (`BackgroundProcs`, spec 73 T98) shares
  # it, so the pair is public and `@doc false`.
  @doc false
  @spec tail_new() :: {:queue.queue(binary()), non_neg_integer()}
  def tail_new, do: {:queue.new(), 0}

  @doc false
  @spec tail_push({:queue.queue(binary()), non_neg_integer()}, binary(), pos_integer()) ::
          {{:queue.queue(binary()), non_neg_integer()}, non_neg_integer()}
  def tail_push(tail, "", _cap), do: {tail, 0}

  def tail_push({queue, size}, chunk, cap),
    do: drop_oldest({:queue.in(chunk, queue), size + byte_size(chunk)}, cap, 0)

  defp drop_oldest({queue, size} = tail, cap, dropped) do
    case :queue.peek(queue) do
      {:value, oldest} when size - byte_size(oldest) >= cap ->
        gone = byte_size(oldest)
        drop_oldest({:queue.drop(queue), size - gone}, cap, dropped + gone)

      _keep ->
        {tail, dropped}
    end
  end

  @doc false
  @spec tail_binary({:queue.queue(binary()), non_neg_integer()}, pos_integer()) :: binary()
  def tail_binary({queue, _size}, cap),
    do: queue |> :queue.to_list() |> IO.iodata_to_binary() |> clip(:tail, cap)

  # spec 67 G31: the buffer holds @cap bytes; what goes back to the model is
  # `limit` of them, half head and half tail, so a model that needs the whole
  # of a long log can ask for it with `max_output_chars` instead of re-running
  # the command through a filter.
  defp output(buffers, limit) do
    {head, tail} = budget(buffers, limit)
    omitted = buffers.total - byte_size(head) - byte_size(tail)

    if omitted > 0 do
      # spec 66 T19: the bare "…[output truncated]" never said how much was lost,
      # so the model could not tell a trimmed log from a short one. spec 67 G33:
      # nor could it tell 40 dropped lines from 40 000.
      lines = max(buffers.lines - newlines(head) - newlines(tail), 0)

      head <>
        "\n…[#{omitted} bytes omitted from the middle (#{lines} lines)]\n" <> tail
    else
      head <> tail
    end
  end

  # Half the budget each, but a side that does not need its half gives it up:
  # `seq 1 5000` fits in the head alone and must come back whole, not as its
  # first 20 000 bytes (`polish9_engine_test.exs:163`).
  defp budget(buffers, limit) do
    head = buffers.head |> Enum.reverse() |> IO.iodata_to_binary()
    tail = tail_binary(buffers.tail, @tail_cap)

    if byte_size(head) + byte_size(tail) <= limit do
      {head, tail}
    else
      tail_keep = min(byte_size(tail), div(limit, 2))
      head_keep = min(byte_size(head), limit - tail_keep)
      tail_keep = min(byte_size(tail), limit - head_keep)
      {clip(head, :head, head_keep), clip(tail, :tail, tail_keep)}
    end
  end

  defp clip(text, _end, room) when byte_size(text) <= room, do: text
  defp clip(text, :head, room), do: binary_part(text, 0, room)
  defp clip(text, :tail, room), do: binary_part(text, byte_size(text) - room, room)

  # Sakana task 17: `kill -9 <os_pid>` reached `/bin/sh` and left everything it
  # had started running — the timeout said "stopped" while the work went on.
  defp kill(port) do
    port |> SwarmCode.Domain.OSProcess.port_pid() |> SwarmCode.Domain.OSProcess.kill_tree()
    close(port)
  end

  # spec 66 T1: the drain path closes the port and stops there — whatever still
  # holds the pipe is what the model asked for and must survive.
  defp close(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp last_line(tail) when is_binary(tail) do
    tail
    |> String.replace_invalid()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> "running"
      line -> String.slice(line, 0, 120)
    end
  end
end
