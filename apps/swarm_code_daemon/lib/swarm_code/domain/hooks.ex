defmodule SwarmCode.Domain.Hooks do
  @moduledoc """
  Runs lifecycle hooks declared in a project's `.swarm_code/config.json`.

  Hook events:
  - `session_start` — fires once when a chat turn starts; output is
    appended to the system context as extra project instructions.
  - `pre_tool_use` — fires before a tool runs (after approval); exit 2
    blocks the tool call, stderr is the reason.
  - `post_tool_use` — fires after a tool returns; informational only.

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

  @type event :: :session_start | :pre_tool_use | :post_tool_use
  @type result :: :ok | {:block, String.t()} | {:inject, String.t()}

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

  defp trusted?(_context, root) do
    root = root |> owner_root() |> Path.expand()

    SwarmCode.Domain.Cache.fetch({:project, {:trusted_root, root}}, fn ->
      case Repo.one(from(p in Project, where: p.root_path == ^root, select: p.trusted_at)) do
        %DateTime{} -> true
        _none -> false
      end
    end)
  end

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
    # nothing.
    env =
      [
        {"SWARMCODE_EVENT", Atom.to_string(event)},
        {"SWARMCODE_PROJECT", root}
      ] ++
        case context[:tool_name] do
          tool when is_binary(tool) -> [{"SWARMCODE_TOOL", tool}]
          _none -> []
        end

    results =
      Enum.reduce_while(hooks, [], fn hook, acc ->
        case run_one(hook, root, env) do
          {:block, reason} when event == :pre_tool_use ->
            {:halt, {:blocked, reason}}

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
        if event == :pre_tool_use do
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
