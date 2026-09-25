defmodule SwarmCode.Daemon.Service.Settings.Files do
  @moduledoc """
  Memory, instructions and library files in settings (pass 74 §3.5.7): a file
  is named by a `ref` (`<file_kind>:<scope>:<project_id or ->:<name>`, §3.4.5)
  that the service resolves and confines to its tier root — the client never
  sends a path. Reads carry a sha256 fingerprint; every write is a
  compare-and-set on it and an atomic same-directory replacement, and a
  conflict answers the fresh fingerprint only (no content, D33). A trusted
  project's `config.json` asks before a new hook command is saved (D14).
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Domain.{AtomicFile, Memory, Projects, Skills, Workflows}
  alias SwarmCode.Domain.Engine.ProjectContext
  alias SwarmCode.Domain.Projects.Workspace

  @compile {:no_warn_undefined, [SwarmCode.Daemon.Service.Settings.Library]}

  @library SwarmCode.Daemon.Service.Settings.Library
  @max_content 262_144
  @in_place 16_384
  @max_ref 512
  @hook_events ~w(session_start pre_tool_use post_tool_use)

  # kind → {scopes, name rule}
  @kinds %{
    "memory_project" => {["project"], {:one_of, ["MEMORY"]}},
    "memory_global" => {["global"], {:one_of, ["MEMORY"]}},
    "instructions" => {["project"], {:one_of, ["AGENTS", "SWARMCODE", "CLAUDE"]}},
    "project_config" => {["project"], {:one_of, ["config"]}},
    "command" => {["project", "global"], :command},
    "agent" => {["project", "user", "bundled"], :file_name},
    "skill" => {["project", "user", "builtin"], :file_name},
    "workflow" => {["project", "user", "builtin"], :workflow}
  }

  @doc false
  def actions, do: ~w(file.save file.create file.delete file.clear)

  @doc false
  def views, do: [{"file", nil}, {"records", "memory_files"}]

  @doc false
  def cache_reads(_action_or_view), do: []

  ## ------------------------------------------------------------ refs

  @doc "A ref string for its parts."
  @spec ref(String.t(), String.t(), String.t() | nil, String.t()) :: String.t()
  def ref(kind, scope, project_id, name), do: "#{kind}:#{scope}:#{project_id || "-"}:#{name}"

  @doc """
  A ref resolved: `%{ref, kind, scope, name, project, root, path, read_only?}`,
  or `:error` for any form that is not a file of its tier (unknown kind or
  scope, a bad name, a missing project, a path that leaves its root).
  """
  @spec resolve(term()) :: {:ok, map()} | :error
  def resolve(ref) when is_binary(ref) and byte_size(ref) <= @max_ref do
    with [kind, scope, pid, name] <- String.split(ref, ":"),
         {scopes, rule} <- Map.get(@kinds, kind, :error),
         true <- scope in scopes,
         true <- name?(rule, name),
         {:ok, project} <- project(scope, pid),
         {root, path} when is_binary(root) and is_binary(path) <-
           place(kind, scope, project, name),
         {:ok, _real} <- AtomicFile.target(root, path) do
      {:ok,
       %{
         ref: ref,
         kind: kind,
         scope: scope,
         name: name,
         project: project,
         root: root,
         path: path,
         read_only?: scope in ["bundled", "builtin"]
       }}
    else
      _ -> :error
    end
  end

  def resolve(_ref), do: :error

  defp name?({:one_of, names}, name), do: name in names
  defp name?(:workflow, name), do: Workflows.valid_name?(name)
  defp name?(:command, name), do: Regex.match?(~r/^[a-z0-9_-][a-z0-9._-]{0,63}$/, name)
  defp name?(:file_name, name), do: Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/, name)

  defp project("project", pid) do
    case Projects.get(pid) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  defp project(_scope, "-"), do: {:ok, nil}
  defp project(_scope, _pid), do: :error

  defp place("memory_project", _scope, project, _name),
    do: {project.root_path, Memory.file(:project, project.root_path)}

  defp place("memory_global", _scope, _project, _name),
    do: {Workspace.global_dir(), Memory.file(:global, nil)}

  defp place("instructions", _scope, project, _name),
    do: {project.root_path, ProjectContext.instructions_path(project)}

  defp place("project_config", _scope, project, _name),
    do: {project.root_path, Path.join([project.root_path, ".swarm_code", "config.json"])}

  defp place("command", scope, project, name) do
    dir =
      if scope == "project",
        do: Workspace.commands_dir(project.root_path),
        else: Workspace.global_commands_dir()

    {dir, Path.join(dir, name <> ".md")}
  end

  defp place("agent", scope, project, name) do
    dir = agents_dir(scope, project)
    {dir, Path.join(dir, name <> ".md")}
  end

  defp place("skill", scope, project, name) do
    dir =
      case scope do
        "project" -> Skills.project_dir(project)
        "user" -> Skills.user_dir()
        "builtin" -> Skills.builtin_dir()
      end

    {dir, Path.join([dir, name, "SKILL.md"])}
  end

  defp place("workflow", scope, project, name) do
    dir = Workflows.scope_dir(project, scope)
    {dir, dir && Path.join(dir, name <> ".exs")}
  end

  @doc "The directory of an agent tier."
  @spec agents_dir(String.t(), map() | nil) :: String.t()
  def agents_dir("project", project), do: Path.join([project.root_path, ".swarm_code", "agents"])
  def agents_dir("user", _project), do: user_agents_dir()
  def agents_dir("bundled", _project), do: Application.app_dir(:swarm_code_daemon, "priv/agents")

  @doc "`~/.swarm_code/agents` (the app's `:settings_user_agents_dir` in tests)."
  @spec user_agents_dir() :: String.t()
  def user_agents_dir do
    Application.get_env(:swarm_code_daemon, :settings_user_agents_dir) ||
      Path.join([Kit.home() || System.user_home!(), ".swarm_code", "agents"])
  end

  ## ------------------------------------------------------------ meta

  @doc """
  What a file weighs without its content: `exists`, `bytes`, `lines` and
  the fingerprint (`{"sha256", "size"}` or `{"missing": true}`), streamed.
  """
  @spec info(map()) :: map()
  def info(%{root: root, path: path}) do
    with {:ok, real} <- AtomicFile.target(root, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(real) do
      {sha, lines} = digest(real)

      %{
        exists: true,
        bytes: size,
        lines: lines,
        fingerprint: %{"sha256" => sha, "size" => size}
      }
    else
      _ -> %{exists: false, bytes: 0, lines: 0, fingerprint: %{"missing" => true}}
    end
  end

  defp digest(path) do
    {hash, newlines, last} =
      path
      |> File.stream!(65_536)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0, nil}, fn chunk, {h, n, _} ->
        {:crypto.hash_update(h, chunk), n + count_newlines(chunk), :binary.last(chunk)}
      end)

    lines = if last in [nil, ?\n], do: newlines, else: newlines + 1
    {hash |> :crypto.hash_final() |> Base.encode16(case: :lower), lines}
  end

  defp count_newlines(chunk), do: length(:binary.matches(chunk, "\n"))

  @doc "The fingerprint of content in memory."
  @spec fingerprint(binary()) :: map()
  def fingerprint(content),
    do: %{
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      "size" => byte_size(content)
    }

  @doc "A resolved file's `file` record fields (no content)."
  @spec fields(map(), map()) :: map()
  def fields(file, info) do
    base = %{
      "file_kind" => file.kind,
      "ref" => file.ref,
      "name" => file.name,
      "scope" => file.scope,
      "path" => Kit.tilde(file.path),
      "bytes" => info.bytes,
      "lines" => info.lines,
      "fingerprint" => info.fingerprint,
      "editable_in_place" => not file.read_only? and info.bytes <= @in_place,
      "too_large" => info.bytes > @max_content,
      "exists" => info.exists
    }

    if file.kind == "instructions" do
      Map.merge(base, %{
        "winner" => Path.basename(file.path),
        "trusted" => file.project.trusted_at != nil
      })
    else
      base
    end
  end

  @doc "A resolved file's record (no content)."
  @spec record(map()) :: map()
  def record(file), do: Kit.record("file", file.ref, fields(file, info(file)))

  ## ------------------------------------------------------------ queries

  @doc false
  def query("file", nil, params, _ctx) do
    ref = Kit.get(params, "id") || Kit.get(params, "ref")

    case resolve(ref) do
      {:ok, file} ->
        info = info(file)

        content =
          if info.exists and info.bytes <= @max_content do
            case AtomicFile.read(file.root, file.path) do
              {:ok, text} -> text
              _ -> nil
            end
          end

        {:ok,
         %{
           "file" => Kit.record("file", file.ref, Map.put(fields(file, info), "content", content))
         }}

      :error ->
        not_found()
    end
  end

  def query("records", "memory_files", params, ctx) do
    pid = Kit.get(Kit.options(params), "project_id") || page_project_id(ctx)
    project = pid && Projects.get(pid)

    refs =
      if project do
        [
          ref("memory_project", "project", project.id, "MEMORY"),
          ref("memory_global", "global", nil, "MEMORY"),
          ref("instructions", "project", project.id, instructions_name(project))
        ]
      else
        [ref("memory_global", "global", nil, "MEMORY")]
      end

    items =
      for ref <- refs, {:ok, file} <- [resolve(ref)], do: record(file)

    {:ok, Kit.records_body("file", items, params)}
  end

  def query(view, kind, params, ctx) do
    if library?() and {view, kind} in @library.views(),
      do: @library.query(view, kind, params, ctx),
      else: Kit.unsupported()
  end

  defp instructions_name(project) do
    project |> ProjectContext.instructions_path() |> Path.basename(".md")
  end

  defp page_project_id(ctx) do
    case Kit.ctx(ctx, :project) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp library?, do: Code.ensure_loaded?(@library)

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: "file.save"} = cmd, _ctx), do: save(cmd)
  def command(%{action: "file.delete"} = cmd, _ctx), do: delete(cmd)
  def command(%{action: "file.clear"} = cmd, _ctx), do: clear(cmd)

  def command(%{action: "file.create"} = cmd, ctx) do
    if library?(), do: @library.create(cmd, ctx), else: Kit.unsupported()
  end

  def command(_cmd, _ctx), do: Kit.unsupported()

  # -- save -------------------------------------------------------------------

  defp save(cmd) do
    attrs = Kit.cmd(cmd, :attributes)
    content = Kit.get(attrs, "content")

    with {:ok, file} <- target(cmd),
         true <- not file.read_only? || read_only(),
         true <- is_binary(content) || Kit.error(:invalid, "content: the file's text"),
         true <-
           byte_size(content) <= @max_content ||
             Kit.error(:invalid, "That is too long to save here (content)"),
         true <- String.valid?(content) || Kit.error(:invalid, "content: not UTF-8 text"),
         {:ok, expected} <- expected_fingerprint(cmd),
         :ok <- still(file, expected) do
      confirm = hooks_to_confirm(file, content, Kit.get(attrs, "confirmed_hooks") == true)

      cond do
        confirm != [] ->
          Kit.ok(:needs_confirmation,
            confirm: %{kind: "hooks", items: Enum.take(confirm, 32)},
            record: record(file),
            message:
              "#{length(confirm)} new hook #{plural(confirm, "command")} will run in #{file.project.name}"
          )

        info(file).exists and read_text(file) == content ->
          Kit.ok(:unchanged, record: record(file))

        Map.get(cmd, :dry_run) ->
          Kit.ok(record: record(file))

        true ->
          case write(file, content, expected) do
            :ok ->
              if file.kind == "project_config", do: Projects.broadcast()
              record = record(file)
              parse = parse(file, content)

              Kit.ok(
                record: put_in(record, ["fields", "parse"], parse),
                message: saved_message(file, parse)
              )

            {:conflict, current} ->
              conflict(file, current)

            {:error, message} ->
              Kit.error(:invalid, message)
          end
      end
    end
  end

  defp plural([_], word), do: word
  defp plural(_, word), do: word <> "s"

  defp saved_message(file, "ok"), do: "#{Path.basename(file.path)} saved"
  defp saved_message(file, parse), do: "#{Path.basename(file.path)} saved · #{parse}"

  # The kind's own writer; the fingerprint is compared again right before it.
  defp write(file, content, expected) do
    case file.kind do
      "memory_project" ->
        guarded(file, expected, fn -> Memory.write(:project, file.project.root_path, content) end)

      "memory_global" ->
        guarded(file, expected, fn -> Memory.write(:global, nil, content) end)

      "workflow" ->
        guarded(file, expected, fn ->
          case Workflows.save(file.project, file.scope, file.name, content) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, to_string(reason)}
          end
        end)

      _ ->
        replace(file, content, expected)
    end
  end

  defp guarded(file, expected, fun) do
    current = info(file).fingerprint
    if Kit.same?(expected, current), do: fun.(), else: {:conflict, current}
  end

  # AtomicFile.update re-reads the file and compares it in the same call as
  # the rename; a missing file is created only while it is still missing.
  defp replace(file, content, expected) do
    File.mkdir_p(Path.dirname(file.path))

    result =
      if expected == %{"missing" => true} do
        if File.exists?(file.path),
          do: {:error, :changed},
          else: AtomicFile.replace(file.root, file.path, content)
      else
        AtomicFile.update(file.root, file.path, fn current ->
          if Kit.same?(expected, fingerprint(current)),
            do: {:ok, content},
            else: {:error, "changed"}
        end)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} when reason in [:changed, "changed", :enoent] ->
        {:conflict, info(file).fingerprint}

      {:error, reason} ->
        {:error, "Couldn't save #{Kit.tilde(file.path)}: #{AtomicFile.format_error(reason)}"}
    end
  end

  defp parse(%{kind: "agent"}, content) do
    case SwarmCode.Domain.Agents.parse(content) do
      {:ok, _} -> "ok"
      {:error, reason} -> reason
    end
  end

  defp parse(%{kind: "project_config"}, content) do
    case Jason.decode(content) do
      {:ok, map} when is_map(map) -> "ok"
      {:ok, _} -> "line 1, column 1: the file must hold one JSON object"
      {:error, %Jason.DecodeError{position: p}} -> json_error(content, p)
    end
  end

  defp parse(_file, _content), do: "ok"

  @doc false
  # `line L, column C: <reason>` for a JSON decode error at byte `position`.
  def json_error(text, position) do
    before = binary_part(text, 0, min(position, byte_size(text)))
    lines = String.split(before, "\n")
    reason = if position >= byte_size(text), do: "unexpected end", else: "unexpected character"
    "line #{length(lines)}, column #{String.length(List.last(lines)) + 1}: #{reason}"
  end

  # D14: in a trusted project, a hook command that is new or changed in the
  # new text runs only after the user says so.
  defp hooks_to_confirm(
         %{kind: "project_config", project: %{trusted_at: at}} = file,
         content,
         false
       )
       when not is_nil(at) do
    old = hook_commands(read_text(file) || "")
    new = hook_commands(content)
    for {event, command} <- new, {event, command} not in old, do: "#{event}: #{command}"
  end

  defp hooks_to_confirm(_file, _content, _confirmed), do: []

  defp hook_commands(text) do
    with {:ok, %{"hooks" => hooks}} when is_map(hooks) <- Jason.decode(text) do
      for event <- @hook_events,
          entry <- List.wrap(hooks[event]),
          is_map(entry),
          command = entry["command"],
          is_binary(command) and String.trim(command) != "",
          uniq: true,
          do: {event, String.trim(command)}
    else
      _ -> []
    end
  end

  defp read_text(file) do
    case AtomicFile.read(file.root, file.path) do
      {:ok, text} -> text
      _ -> nil
    end
  end

  # -- delete and clear ---------------------------------------------------------

  defp delete(cmd) do
    with {:ok, file} <- target(cmd),
         true <-
           not file.read_only? ||
             Kit.ok(:rejected,
               message: "a built-in file cannot be deleted; make a user copy to override it"
             ),
         true <-
           file.kind != "instructions" ||
             Kit.ok(:rejected,
               message: "edit it instead; delete the file yourself if you mean to"
             ),
         {:ok, expected} <- expected_fingerprint(cmd),
         :ok <- still(file, expected) do
      cond do
        not info(file).exists ->
          Kit.ok(:unchanged, message: "#{Path.basename(file.path)} is already gone")

        Map.get(cmd, :dry_run) ->
          Kit.ok()

        true ->
          remove(file)
      end
    end
  end

  defp remove(%{kind: "workflow"} = file) do
    case Workflows.delete(file.project, file.scope, file.name) do
      :ok -> Kit.ok(message: "#{file.name} deleted")
      {:error, reason} -> Kit.error(:invalid, to_string(reason))
    end
  end

  defp remove(%{kind: "skill"} = file) do
    dir = Path.dirname(file.path)

    with {:ok, real} <- AtomicFile.target(file.root, dir),
         {:ok, entries} <- File.ls(real),
         true <- length(entries) <= 32 and Enum.all?(entries, &plain_file?(real, &1)) do
      Enum.each(entries, &File.rm(Path.join(real, &1)))

      case File.rmdir(real) do
        :ok ->
          Kit.ok(message: "#{file.name} deleted")

        {:error, reason} ->
          Kit.error(:invalid, "Couldn't delete #{Kit.tilde(dir)}: #{:file.format_error(reason)}")
      end
    else
      _ ->
        Kit.ok(:rejected,
          message:
            "this skill folder holds more than skill files; remove it yourself: #{Kit.tilde(dir)}"
        )
    end
  end

  defp remove(file) do
    case AtomicFile.remove(file.root, file.path) do
      :ok ->
        if file.kind == "project_config", do: Projects.broadcast()
        Kit.ok(message: "#{Path.basename(file.path)} deleted")

      {:error, reason} ->
        Kit.error(
          :invalid,
          "Couldn't delete #{Kit.tilde(file.path)}: #{AtomicFile.format_error(reason)}"
        )
    end
  end

  defp plain_file?(dir, name) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(dir, name)))
  end

  defp clear(cmd) do
    with {:ok, file} <- target(cmd),
         true <-
           file.kind in ["memory_project", "memory_global"] ||
             Kit.error(:invalid, "only memory files are cleared"),
         {:ok, expected} <- expected_fingerprint(cmd),
         :ok <- still(file, expected) do
      cond do
        (read_text(file) || "") == "" ->
          Kit.ok(:unchanged, record: record(file))

        Map.get(cmd, :dry_run) ->
          Kit.ok(record: record(file))

        true ->
          case write(file, "", expected) do
            :ok -> Kit.ok(record: record(file), message: "#{Path.basename(file.path)} cleared")
            {:conflict, current} -> conflict(file, current)
            {:error, message} -> Kit.error(:invalid, message)
          end
      end
    end
  end

  ## ------------------------------------------------------------ shared

  defp target(cmd) do
    case resolve(Kit.get(Kit.cmd(cmd, :target), "ref")) do
      {:ok, file} -> {:ok, file}
      :error -> not_found()
    end
  end

  defp expected_fingerprint(cmd) do
    case Kit.expected(cmd, "fingerprint") do
      {:ok, %{} = fp} -> {:ok, fp}
      {:ok, _} -> Kit.error(:invalid, "expected is missing for fingerprint")
      error -> error
    end
  end

  # :ok when the file still has the fingerprint the writer read, else the
  # conflict answer (the fresh fingerprint only — never content, D33)
  defp still(file, expected) do
    current = info(file).fingerprint

    if Kit.same?(expected, current),
      do: :ok,
      else: conflict(file, current)
  end

  defp conflict(file, current) do
    Kit.ok(:conflict,
      results: [Kit.row("fingerprint", :conflict, current: current)],
      record: record(file),
      message: "#{Path.basename(file.path)} changed on disk since you opened it."
    )
  end

  defp read_only,
    do:
      Kit.ok(:rejected,
        message: "a built-in file cannot be edited; make a user copy to override it"
      )

  defp not_found, do: Kit.error(:not_found, "That file is not there.")
end
