defmodule SwarmCode.Daemon.Service.Settings.Library do
  @moduledoc """
  The library in settings (pass 74 §3.5.7): custom commands, agent
  definitions (three tiers, shadowing by name), skills and workflows as
  records whose `ref` the Files handler opens, new files from the desktop's
  templates in 0700 tier folders, and the workflow smoke lint as a task.
  Built-in and bundled files are read-only. AT12.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.{Files, Kit}
  alias SwarmCode.Domain.{Agents, AtomicFile, Commands, Projects, Skills, Workflows}
  alias SwarmCode.Domain.Workflows.Smoke

  @smoke_ms 30_000
  @max_listed 200
  @builtin_commands ~w(settings config prefs)
  @tier_order %{"project" => 0, "user" => 1, "bundled" => 2, "builtin" => 2}

  @command_template """
  ---
  description: What this command does
  swarm: false
  ---
  Write the prompt the agent should receive here.
  Arguments typed after the command land here: $ARGUMENTS
  """

  @doc false
  def actions, do: ~w(workflow.smoke)

  @doc false
  def views,
    do: [
      {"records", "commands"},
      {"records", "agent_defs"},
      {"records", "skills"},
      {"records", "workflows"}
    ]

  @doc false
  def cache_reads("records:workflows"), do: [{"workflow.smoke", :all}]
  def cache_reads(_other), do: []

  ## ------------------------------------------------------------ queries

  @doc false
  def query("records", kind, params, ctx)
      when kind in ~w(commands agent_defs skills workflows) do
    project = project(params, ctx)

    {record_kind, items} =
      case kind do
        "commands" -> {"command", commands(project)}
        "agent_defs" -> {"agent_def", agent_defs(project)}
        "skills" -> {"skill", skills(project)}
        "workflows" -> {"workflow", workflows(project, ctx)}
      end

    records = Enum.map(items, &Kit.record(record_kind, &1["ref"], &1))
    {:ok, Kit.records_body(record_kind, records, params)}
  end

  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  defp project(params, ctx) do
    case Kit.get(Kit.options(params), "project_id") do
      id when is_binary(id) ->
        Projects.get(id)

      _ ->
        case Kit.ctx(ctx, :project) do
          %{id: id} -> Projects.get(id)
          _ -> nil
        end
    end
  end

  defp pid(nil), do: nil
  defp pid(project), do: project.id

  # -- commands ---------------------------------------------------------------

  @doc false
  def commands(project) do
    global = MapSet.new(Commands.list(nil), & &1.name)

    for command <- Commands.list(project) do
      scope = Atom.to_string(command.scope)
      name = Path.basename(command.path, ".md")

      %{
        "ref" => Files.ref("command", scope, if(scope == "project", do: pid(project)), name),
        "name" => command.name,
        "scope" => scope,
        "description" => command.description,
        "swarm" => command.swarm,
        "mode" => command.mode,
        "overrides_global" => scope == "project" and MapSet.member?(global, command.name),
        "shadowed_by_builtin" => command.name in @builtin_commands,
        "path" => Kit.tilde(command.path)
      }
    end
    |> Enum.take(@max_listed)
  end

  # -- agent definitions ------------------------------------------------------

  @doc false
  def agent_defs(project) do
    tiers =
      [{"project", project}, {"user", nil}, {"bundled", nil}]
      |> Enum.reject(fn {tier, p} -> tier == "project" and is_nil(p) end)

    entries =
      for {tier, p} <- tiers,
          dir = Files.agents_dir(tier, p),
          file <- md_files(dir) do
        agent_entry(tier, p, dir, file)
      end

    # shadowing: project > user > bundled, by case-insensitive name
    by_name = Enum.group_by(entries, &String.downcase(&1["name"] || ""))

    entries
    |> Enum.map(fn entry ->
      same =
        by_name
        |> Map.get(String.downcase(entry["name"] || ""), [])
        |> Enum.sort_by(&@tier_order[&1["tier"]])

      [first | rest] = same

      if first["ref"] == entry["ref"] do
        Map.merge(entry, %{"shadowed" => false, "shadows" => rest |> List.first() |> tier_of()})
      else
        Map.merge(entry, %{"shadowed" => true, "shadows" => nil})
      end
    end)
    |> Enum.sort_by(&{String.downcase(&1["name"] || ""), @tier_order[&1["tier"]]})
    |> Enum.take(@max_listed)
  end

  defp tier_of(nil), do: nil
  defp tier_of(entry), do: entry["tier"]

  defp md_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") and not String.starts_with?(&1, ".")))
        |> Enum.filter(&File.regular?(Path.join(dir, &1)))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp agent_entry(tier, project, dir, file) do
    path = Path.join(dir, file)
    stem = Path.rootname(file)

    {definition, error} =
      case AtomicFile.read(dir, path) do
        {:ok, text} ->
          case Agents.parse(text) do
            {:ok, definition} -> {definition, nil}
            {:error, reason} -> {nil, reason}
          end

        {:error, reason} ->
          {nil, AtomicFile.format_error(reason)}
      end

    name = (definition && definition.name) || stem

    %{
      "ref" => Files.ref("agent", tier, if(tier == "project", do: pid(project)), stem),
      "name" => name,
      "tier" => tier,
      "description" => definition && definition.description,
      "tools_label" => definition && tools_label(definition.tools),
      "model" => definition && definition.model,
      "effort" => definition && definition.effort,
      "prewalk" => (definition && definition.prewalk) == true,
      "max_turns" => definition && definition.max_turns,
      "parse_error" => error,
      "path" => Kit.tilde(path)
    }
  end

  defp tools_label(nil), do: "all tools"
  defp tools_label([]), do: "no tools"
  defp tools_label(tools), do: Enum.join(tools, ", ")

  # -- skills -----------------------------------------------------------------

  @doc false
  def skills(project) do
    tiers =
      [{"project", Skills.project_dir(project)}, {"user", Skills.user_dir()}]
      |> Enum.reject(fn {_tier, dir} -> is_nil(dir) end)

    on_disk =
      for {tier, dir} <- tiers, name <- skill_dirs(dir) do
        skill_entry(tier, project, dir, name)
      end

    builtins =
      for skill <- Skills.builtins() do
        dir = Path.dirname(skill.path)
        entry = skill_entry("builtin", project, dir, skill.name)
        %{entry | "description" => skill.description}
      end

    entries = on_disk ++ builtins
    by_name = Enum.group_by(entries, & &1["name"])

    entries
    |> Enum.map(fn entry ->
      [first | _] = Enum.sort_by(by_name[entry["name"]], &@tier_order[&1["scope"]])
      Map.put(entry, "shadowed", first["ref"] != entry["ref"])
    end)
    |> Enum.sort_by(&{&1["name"], @tier_order[&1["scope"]]})
    |> Enum.take(@max_listed)
  end

  defp skill_dirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/, &1))
        |> Enum.filter(&File.regular?(Path.join([dir, &1, "SKILL.md"])))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp skill_entry(scope, project, dir, name) do
    folder = Path.join(dir, name)
    {files, bytes} = folder_size(folder)

    description =
      case AtomicFile.read(dir, Path.join(folder, "SKILL.md")) do
        {:ok, text} -> first_line(text)
        _ -> nil
      end

    %{
      "ref" => Files.ref("skill", scope, if(scope == "project", do: pid(project)), name),
      "name" => name,
      "scope" => scope,
      "description" => description,
      "files" => files,
      "bytes" => bytes,
      "path" => Kit.tilde(Path.join(folder, "SKILL.md"))
    }
  end

  defp first_line(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))
  end

  # regular files below a skill folder (at most 256 looked at)
  defp folder_size(folder) do
    folder
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.take(256)
    |> Enum.reduce({0, 0}, fn path, {n, bytes} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} -> {n + 1, bytes + size}
        _ -> {n, bytes}
      end
    end)
  end

  # -- workflows --------------------------------------------------------------

  @doc false
  def workflows(project, ctx) do
    smoked = smoke_results(ctx)

    for definition <- Workflows.list_all(project) do
      scope = definition.scope

      ref =
        Files.ref("workflow", scope, if(scope == "project", do: pid(project)), definition.name)

      %{
        "ref" => ref,
        "name" => definition.name,
        "scope" => scope,
        "path" => Kit.tilde(definition.path),
        "smoke" => Map.get(smoked, ref)
      }
    end
    |> Enum.sort_by(&{&1["name"], @tier_order[&1["scope"]]})
    |> Enum.take(@max_listed)
  end

  # ref → the smoke text of the newest `workflow.smoke` that checked it
  defp smoke_results(ctx) do
    ctx
    |> Kit.task_entries("workflow.smoke")
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn entry, acc ->
      rows =
        case entry.result do
          %{} = result -> Kit.get(result, "rows") || []
          _ -> []
        end

      Enum.reduce(rows, acc, fn row, acc ->
        Map.put(acc, Kit.get(row, "ref"), Kit.get(row, "smoke"))
      end)
    end)
  end

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: "workflow.smoke"} = cmd, ctx) do
    ref = Kit.get(Kit.cmd(cmd, :target), "ref")

    targets =
      cond do
        is_binary(ref) ->
          case Files.resolve(ref) do
            {:ok, %{kind: "workflow"} = file} ->
              if File.regular?(file.path),
                do: {:ok, [file]},
                else: Kit.error(:not_found, "That workflow is not there.")

            _ ->
              Kit.error(:not_found, "That workflow is not there.")
          end

        true ->
          {:ok, every_workflow(project(%{}, ctx))}
      end

    with {:ok, files} <- targets do
      Kit.task(
        action: "workflow.smoke",
        key: ref || "all",
        timeout_ms: @smoke_ms,
        cancellable?: true,
        kind: :plain,
        run: fn report -> {:ok, smoke(files, report)} end,
        summary: &Map.delete(&1, "rows"),
        redact: []
      )
    end
  end

  def command(_cmd, _ctx), do: Kit.unsupported()

  # every user and project workflow, resolved
  defp every_workflow(project) do
    for definition <- Workflows.list_all(project),
        definition.scope in ["project", "user"],
        {:ok, file} <- [Files.resolve(workflow_ref(definition, project))],
        do: file
  end

  defp workflow_ref(definition, project) do
    pid = if definition.scope == "project", do: pid(project)
    Files.ref("workflow", definition.scope, pid, definition.name)
  end

  @doc false
  def smoke(files, report) do
    total = length(files)

    rows =
      files
      |> Enum.with_index(1)
      |> Enum.map(fn {file, i} ->
        row = %{"ref" => file.ref, "name" => file.name, "smoke" => smoke_one(file)}
        report.(%{"done" => i, "total" => total})
        row
      end)

    %{
      "rows" => rows,
      "checked" => total,
      "failed" => Enum.count(rows, &(&1["smoke"] != "ok"))
    }
  end

  defp smoke_one(file) do
    with {:ok, source} <- AtomicFile.read(file.root, file.path),
         {:ok, definition} <- Workflows.parse(source, file.scope, file.path) do
      case definition.problems ++ Smoke.errors(definition) do
        [] -> "ok"
        problems -> problems |> Enum.join("; ") |> Kit.cut()
      end
    else
      {:error, problems} when is_list(problems) -> problems |> Enum.join("; ") |> Kit.cut()
      {:error, reason} -> AtomicFile.format_error(reason)
    end
  end

  ## ------------------------------------------------------------ create (file.create)

  @doc false
  # `file.create` (routed to Files): a new command, agent or skill from the
  # template, in its tier folder (made 0700 when new).
  def create(cmd, ctx) do
    target = Kit.cmd(cmd, :target)
    kind = Kit.get(target, "kind")
    scope = Kit.get(target, "scope")
    name = target |> Kit.get("name") |> to_string() |> String.trim()
    project_id = Kit.get(target, "project_id") || pid(project(%{}, ctx))

    with {:ok, scopes, rule, message} <- create_rules(kind),
         true <- scope in scopes || Kit.error(:invalid, "scope: #{Enum.join(scopes, " or ")}"),
         true <-
           Regex.match?(rule, name) ||
             Kit.error(:invalid, "name: #{message}", [Kit.field_error("name", message)]),
         {:ok, file} <- resolve_new(kind, scope, project_id, name),
         true <-
           not File.exists?(file.path) ||
             Kit.error(:invalid, "name: already exists", [
               Kit.field_error("name", "already exists")
             ]),
         true <- not name_taken?(kind, scope, project_id, name) || already() do
      if Map.get(cmd, :dry_run) do
        Kit.ok()
      else
        write_new(file, template(kind, name))
      end
    end
  end

  defp create_rules("command"),
    do:
      {:ok, ["project", "global"], ~r/^[a-z0-9_-][a-z0-9._-]{0,63}$/,
       "lowercase letters, digits, ., _ or - (64 max)"}

  defp create_rules("agent"),
    do:
      {:ok, ["project", "user"], ~r/^[a-z0-9][a-z0-9_-]{0,23}$/,
       "lowercase letters, digits, - or _ (24 max)"}

  defp create_rules("skill"),
    do:
      {:ok, ["project", "user"], ~r/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$/,
       "letters, digits, ., _ or - (64 max)"}

  defp create_rules(_kind), do: Kit.error(:invalid, "kind: command, agent or skill")

  defp already,
    do: Kit.error(:invalid, "name: already exists", [Kit.field_error("name", "already exists")])

  # a command name differs only by case from an existing file (`Review.md`)
  defp name_taken?("command", scope, project_id, name) do
    dir = Files.ref("command", scope, project_id, name) |> Files.resolve()

    case dir do
      {:ok, file} ->
        file.path
        |> Path.dirname()
        |> md_files()
        |> Enum.any?(&(String.downcase(Path.rootname(&1)) == name))

      :error ->
        false
    end
  end

  defp name_taken?(_kind, _scope, _project_id, _name), do: false

  defp resolve_new(kind, scope, project_id, name) do
    pid = if scope == "project", do: project_id

    cond do
      scope == "project" and is_nil(pid) ->
        Kit.error(:invalid, "open a project first")

      true ->
        case Files.resolve(Files.ref(kind, scope, pid, name)) do
          {:ok, file} -> {:ok, file}
          :error -> Kit.error(:not_found, "no such project")
        end
    end
  end

  defp template("command", _name), do: @command_template

  defp template("agent", name),
    do:
      "---\nname: #{name}\ndescription: What this agent is for\ntools: read_file,grep,find_files\neffort: medium\nmax_turns: 30\n---\nWrite the instructions this agent adds to its system prompt here.\n"

  defp template("skill", name),
    do: "# #{name}\n\nDescribe what this skill does in the first line.\n"

  defp write_new(file, content) do
    tier = tier_dir(file)
    parent = Path.dirname(file.path)

    with :ok <- make_dir(tier),
         :ok <- if(parent != tier, do: make_dir(parent), else: :ok),
         :ok <- AtomicFile.replace(file.root, file.path, content) do
      Kit.ok(record: Files.record(file), message: "#{file.name} created")
    else
      {:error, reason} ->
        Kit.error(
          :invalid,
          "Couldn't create #{Kit.tilde(file.path)}: #{AtomicFile.format_error(reason)}"
        )
    end
  end

  defp tier_dir(%{kind: "skill", path: path}), do: path |> Path.dirname() |> Path.dirname()
  defp tier_dir(%{path: path}), do: Path.dirname(path)

  # a new tier folder is private (0700); an existing one keeps its mode
  defp make_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  ## ------------------------------------------------------------ attention

  @doc "AT12 (§2.1): a user or project agent definition that does not parse."
  @spec attention(map()) :: [map()]
  def attention(ctx) do
    project = project(%{}, ctx)

    for entry <- agent_defs(project),
        entry["tier"] in ["user", "project"],
        is_binary(entry["parse_error"]) do
      %{
        id: "AT12",
        severity: "warning",
        section: "library",
        target: %{"kind" => "agent_def", "id" => entry["ref"]},
        title: "#{Path.basename(entry["path"])}: #{entry["parse_error"]}",
        reason: "agent definition not read"
      }
    end
  end
end
