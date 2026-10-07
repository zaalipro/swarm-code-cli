defmodule SwarmCode.Domain.Hooks do
  @moduledoc """
  Runs lifecycle hooks declared in a project's `.swarm_code/config.json`.

  Hook events:
  - `session_start` — fires once when a chat turn starts; output is
    appended to the system context as extra project instructions.
  - `pre_tool_use` — fires before a tool runs (after approval); exit 2
    blocks the tool call, stderr is the reason.
  - `post_tool_use` — fires after a tool returns; informational only.

  pass 72 F9 (CLI 0.2.0, competitors-10):
  - `stop` — a run finished (`NCODE_STATUS`, `NCODE_RUN_ID`); informational.
  - `notification` — a run waits for the user (`NCODE_KIND` = `approval` or
    `question`, `NCODE_RUN_ID`); informational.
  - `user_prompt_submit` — before a chat turn starts (`NCODE_PROMPT`, the
    first 8 KB); exit 2 refuses the send, stderr is the reason.
  - `pre_compact` — a compaction starts (`NCODE_RUN_ID`); informational.
  - `session_end` — the app quits; informational, bounded (`SwarmCode.Domain.Quit`).

  The informational events run in `SwarmCode.Domain.Hooks.TaskSupervisor`
  (`run_async/3`), never in a state owner's callback.

  spec 73 T16: a hook is a committed shell command, so it only runs for a
  project the user has trusted (`SwarmCode.Domain.Projects.trusted?/1`, the spec 67
  T31 gate), with the scrubbed environment `run_command` uses, stdin closed,
  its output bounded while it is read, and its whole process tree reaped on
  timeout (`SwarmCode.Domain.OSProcess.kill_tree/1`).
  """

  # spec 70 D2

  require Logger

  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Domain.ProjectConfig
  alias SwarmCode.Domain.Projects.Project
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Tools.RunCommand

  @type event ::
          :session_start
          | :pre_tool_use
          | :post_tool_use
          | :stop
          | :notification
          | :user_prompt_submit
          | :pre_compact
          | :session_end
  @type result :: :ok | {:block, String.t()} | {:inject, String.t()}

  # pass 72 F9: the events whose exit 2 refuses what fired them, and the ones
  # whose stdout becomes context. Every other event is informational.
  @blocking [:pre_tool_use, :user_prompt_submit]
  @injecting [:session_start, :post_tool_use]

  # pass 72 F9: what an event's context may export, and how much of the prompt.
  @context_env [run_id: "NCODE_RUN_ID", status: "NCODE_STATUS", kind: "NCODE_KIND"]
  @prompt_env_bytes 8_192

  @doc """
  pass 72 F9: `run/3` as owned work under `SwarmCode.Domain.Hooks.TaskSupervisor`,
  for the informational events — the config read and the hook itself never
  run in the caller (a RunServer callback, a LiveView). Returns `:ok` at once.
  """
  @spec run_async(event(), map(), String.t() | nil) :: :ok
  def run_async(_event, _context, nil), do: :ok

  def run_async(event, context, root) do
    Task.Supervisor.start_child(SwarmCode.Domain.Hooks.TaskSupervisor, fn ->
      run(event, context, root)
    end)

    :ok
  end

  @doc """
  pass 72 F9: `run/3` for a blocking event, in a task under
  `SwarmCode.Domain.Hooks.TaskSupervisor` so the hook's port and its messages never
  touch the caller's mailbox. The caller waits for the answer, at most
  `timeout` ms (then `:ok`: a hook that cannot answer does not block).
  """
  @spec run_supervised(event(), map(), String.t() | nil, timeout()) :: result()
  def run_supervised(event, context, root, timeout \\ 60_000)
  def run_supervised(_event, _context, nil, _timeout), do: :ok

  def run_supervised(event, context, root, timeout) do
    task =
      Task.Supervisor.async_nolink(SwarmCode.Domain.Hooks.TaskSupervisor, fn ->
        run(event, context, root)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _exit_or_timeout -> :ok
    end
  end

  @doc """
  Runs every hook for `event` whose matcher (if any) matches `tool_name`.
  Returns `:ok`, `{:block, reason}`, or `{:inject, text}`.

  For `:pre_tool_use`: the first hook that exits 2 blocks the call;
  its stderr (capped) is the reason. Other non-zero exits are logged
  and ignored — a broken hook must not crash a run.

  For `:session_start` and `:post_tool_use`: stdout of all hooks is
  concatenated and returned as `{:inject, text}` when non-empty.

  When `root` is nil (no project), or the project at `root` is not trusted,
  returns `:ok` immediately. `context[:project]` (a project struct or map
  with `trusted_at`) answers the trust question without a lookup.
  """
  @spec run(event(), map(), String.t() | nil) :: result()
  def run(_event, _context, nil), do: :ok

  def run(event, context, root) do
    case cached_config(owner_root(root)) do
      %{hooks: hooks} ->
        hooks
        |> Map.get(event, [])
        |> Enum.filter(&matches_tool?(&1, context[:tool_name]))
        |> run_if_trusted(event, context, root)

      _none ->
        :ok
    end
  end

  # spec 73 T95: the project's config.json is read and parsed once per
  # (mtime, size) — `ProjectConfig.load/1` ran a File.read + Jason.decode for
  # every event, twice per tool call. One stat per event; the parsed config
  # sits in `SwarmCode.Domain.Cache` under the `:project` tag. The project root is
  # the source for an isolation directory too (its copy is the same file at
  # clone time, and a worktree carries none).
  @doc """
  pass 72 F10: the parsed `.swarm_code/config.json` of `root` (an isolation
  directory answers for its project), cached per (mtime, size) like the
  hooks' own read; nil when there is none. No trust check — callers that act
  on it check `trusted_root?/1` first (`SwarmCode.Domain.Engine.Rules.for_root/1`).
  """
  @spec project_config(String.t()) :: ProjectConfig.t() | nil
  def project_config(root) when is_binary(root), do: cached_config(owner_root(root))

  defp cached_config(root) do
    path = Path.join(root, ".swarm_code/config.json")

    stamp =
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
        _missing -> :none
      end

    key = {:project, {:config, root}}

    case SwarmCode.Domain.Cache.get(key) do
      {^stamp, config} ->
        config

      _stale_or_missing ->
        {:ok, config} = ProjectConfig.load(root)
        SwarmCode.Domain.Cache.put(key, {stamp, config})
        config
    end
  end

  # -- private ---------------------------------------------------------------

  defp run_if_trusted([], _event, _context, _root), do: :ok

  defp run_if_trusted(hooks, event, context, root) do
    if trusted?(context, root) do
      run_hooks(hooks, event, context, root)
    else
      Logger.info("hooks skipped for #{event}: the project at #{root} is not trusted")
      :ok
    end
  end

  # spec 73 T16: the trust gate. A caller that already holds the project
  # passes it; otherwise the row is looked up by root — an isolation
  # directory (`<root>/.swarm_code/worktrees/<name>`) answers for its project,
  # whose config.json it carries. Cached under the `:project` tag, which every
  # project write (`Projects.broadcast/0`, including `trust/1`) drops.
  defp trusted?(%{project: %{trusted_at: _} = project}, _root),
    do: SwarmCode.Domain.Projects.trusted?(project)

  defp trusted?(_context, root), do: trusted_root?(root)

  @doc """
  True when the project rooted at `root` — or owning the isolation directory
  `root` — is trusted. Cached under the `:project` tag.

  spec 74 BUGS-8: `SwarmCode.Domain.Git` asks this before a commit or merge, so an
  untrusted project's `core.hooksPath` scripts do not run.
  """
  @spec trusted_root?(String.t()) :: boolean()
  def trusted_root?(root) when is_binary(root) do
    root = root |> owner_root() |> Path.expand()

    SwarmCode.Domain.Cache.fetch({:project, {:trusted_root, root}}, fn ->
      case Repo.one(from(p in Project, where: p.root_path == ^root, select: p.trusted_at)) do
        %DateTime{} -> true
        _none -> false
      end
    end)
  end

  def trusted_root?(_root), do: false

  defp owner_root(root) do
    case root |> Path.split() |> Enum.reverse() do
      [_name, "worktrees", ".swarm_code" | up] -> up |> Enum.reverse() |> Path.join()
      _plain -> root
    end
  end

  defp matches_tool?(_hook, nil), do: true
  defp matches_tool?(%{matcher: nil}, _tool_name), do: true

  defp matches_tool?(%{matcher: pattern}, tool_name) do
    case Regex.compile(pattern) do
      {:ok, re} -> Regex.match?(re, tool_name)
      {:error, _} -> false
    end
  end

  defp run_hooks(hooks, event, context, root) do
    # spec 73 T95: the tool that fired, for every hook of a tool event — the
    # matcher's regex used to be exported instead, and a hook without one saw
    # nothing. Pass 75 (the ncode rename): every value goes out as `NCODE_*`
    # and, deprecated but kept for existing hook scripts, as `SWARMCODE_*`.
    event_name = Atom.to_string(event)

    env =
      [
        {"NCODE_EVENT", event_name},
        {"NCODE_PROJECT", root},
        {"SWARMCODE_EVENT", event_name},
        {"SWARMCODE_PROJECT", root}
      ] ++
        case context[:tool_name] do
          tool when is_binary(tool) -> [{"NCODE_TOOL", tool}, {"SWARMCODE_TOOL", tool}]
          _none -> []
        end ++ context_env(context)

    cap_ms = context[:timeout_cap_ms]

    results =
      Enum.reduce_while(hooks, [], fn hook, acc ->
        hook =
          if is_integer(cap_ms) and cap_ms > 0,
            do: %{hook | timeout_ms: min(hook.timeout_ms, cap_ms)},
            else: hook

        case run_one(hook, root, env) do
          {:block, reason} when event in @blocking ->
            {:halt, {:blocked, reason}}

          # pass 72 F9: exit 2 of an informational event (and of
          # `session_start`, which raised a CaseClauseError here) blocks nothing.
          {:block, _reason} ->
            {:cont, acc}

          {:ok, output} ->
            {:cont, [output | acc]}

          :skip ->
            {:cont, acc}
        end
      end)

    case results do
      {:blocked, reason} ->
        {:block, reason}

      outputs when is_list(outputs) ->
        # pre_tool_use: exit 0 means :ok (no inject); only session_start and
        # post_tool_use collect stdout as injectable context.
        if event not in @injecting do
          :ok
        else
          text =
            outputs
            |> Enum.reverse()
            |> Enum.join("\n")
            |> String.trim()

          if text == "", do: :ok, else: {:inject, text}
        end
    end
  end

  # pass 72 F9: the event's facts as `NCODE_*` variables. Only short plain
  # values go out (a port refuses a NUL byte in its environment), and the
  # prompt is cut to its first 8 KB on a character boundary.
  defp context_env(context) do
    facts =
      for {key, name} <- @context_env,
          value = context[key],
          is_binary(value) and Regex.match?(~r/\A[\w.:-]{1,128}\z/, value),
          do: {name, value}

    prompt =
      case context[:prompt] do
        text when is_binary(text) and text != "" ->
          text = text |> String.replace_invalid() |> String.replace(<<0>>, "")

          text =
            if byte_size(text) > @prompt_env_bytes,
              do: text |> binary_part(0, @prompt_env_bytes) |> String.replace_invalid(""),
              else: text

          [{"NCODE_PROMPT", text}]

        _none ->
          []
      end

    facts ++ prompt
  end

  # spec 73 T16: a Port instead of `Task.async` + `System.cmd`: the OS pid is
  # known, so a timeout reaps the whole tree (brutal_kill only closed the pipe
  # and left `sh` and its children running); the environment is the scrubbed
  # one every `run_command` gets (`ANTHROPIC_API_KEY` & co. were inherited);
  # stdin is closed up front like `RunCommand.script/2`; and the output is
  # bounded while it is read rather than after `System.cmd` accumulated it.
  defp run_one(hook, root, env) do
    timeout = hook.timeout_ms
    cap = hook.output_cap

    case open_port(hook.command, root, env) do
      {:ok, port} ->
        deadline = System.monotonic_time(:millisecond) + timeout

        case collect(port, [], 0, cap, deadline) do
          {:ok, 0, output} ->
            {:ok, output}

          {:ok, 2, output} ->
            {:block, output}

          {:ok, code, _output} ->
            Logger.warning("hook #{inspect(hook.command)} exited #{code}, ignoring")
            :skip

          :timeout ->
            Logger.warning("hook #{inspect(hook.command)} timed out after #{timeout}ms")
            :skip
        end

      {:error, reason} ->
        Logger.warning("hook command failed: #{reason}")
        :skip
    end
  end

  defp open_port(command, root, env) do
    case System.find_executable("sh") do
      nil ->
        {:error, "command not found: sh"}

      sh ->
        port_env =
          RunCommand.clean_env() ++
            Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

        port =
          Port.open({:spawn_executable, sh}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: ["-c", RunCommand.umask_prefix() <> "exec </dev/null\n" <> command],
            cd: String.to_charlist(root),
            env: port_env
          ])

        {:ok, port}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The first `cap` bytes are kept; everything past them is dropped as it
  # streams, so a chatty hook costs its cap and no more.
  defp collect(port, acc, bytes, cap, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        keep = min(byte_size(data), max(cap - bytes, 0))
        acc = if keep > 0, do: [binary_part(data, 0, keep) | acc], else: acc
        collect(port, acc, bytes + keep, cap, deadline)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {:EXIT, ^port, _reason} ->
        collect(port, acc, bytes, cap, deadline)
    after
      remaining ->
        port |> SwarmCode.Domain.OSProcess.port_pid() |> SwarmCode.Domain.OSProcess.kill_tree()
        close(port)
        flush(port)
        :timeout
    end
  end

  defp close(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Whatever the killed port still delivered must not sit in the caller's
  # mailbox: the operation task and the hook supervisor's children are
  # short-lived, but a stray `{port, …}` is never anyone's message.
  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
      {:EXIT, ^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
