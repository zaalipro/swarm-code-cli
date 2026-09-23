defmodule SwarmCode.Domain.Agents do
  @moduledoc """
  Declarative agent definitions from markdown files with frontmatter.

  Agents are discovered from three tiers (project > user > bundled), each a
  directory of `.md` files. The frontmatter declares name, tools, model, effort,
  prewalk and max_turns; the markdown body becomes the system prompt addition.

  # spec 72 A1
  """

  require Logger

  alias SwarmCode.Domain.Agents.AgentDef

  @max_name_length 24

  # ---------------------------------------------------------------------- parse

  @doc "Parse a markdown file with frontmatter into an AgentDef."
  @spec parse(String.t()) :: {:ok, AgentDef.t()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    case extract_frontmatter(content) do
      {:ok, kv, body} ->
        build_def(kv, body)

      :no_frontmatter ->
        # No frontmatter: the whole content is the system_prompt_addition;
        # the name must be set by the caller from the filename.
        {:ok, %AgentDef{system_prompt_addition: String.trim(content)}}
    end
  end

  # spec 73 T46: a definition saved with CRLF line endings used to yield
  # `"---\r"`, read as no frontmatter, and its `tools:`/`model:` lines became
  # the system prompt body.
  defp extract_frontmatter(content) do
    lines = content |> String.split(~r/\r?\n/) |> Enum.map(&String.trim_trailing/1)

    case lines do
      ["---" | rest] ->
        case Enum.split_while(rest, &(&1 != "---")) do
          {_fm_lines, []} ->
            # No closing ---: treat as no frontmatter
            :no_frontmatter

          {fm_lines, ["---" | body_lines]} ->
            kv = parse_frontmatter_lines(fm_lines)
            body = body_lines |> Enum.join("\n") |> String.trim()
            {:ok, kv, body}
        end

      _ ->
        :no_frontmatter
    end
  end

  defp parse_frontmatter_lines(lines) do
    for line <- lines,
        String.contains?(line, ":"),
        [key | val_parts] = String.split(line, ":", parts: 2),
        key = String.trim(key),
        key != "",
        into: %{} do
      {key, String.trim(Enum.join(val_parts, ":"))}
    end
  end

  defp build_def(kv, body) do
    name = Map.get(kv, "name", "")
    name = String.slice(name, 0, @max_name_length)

    if name == "" do
      {:error, "agent definition missing name"}
    else
      {:ok,
       %AgentDef{
         name: name,
         description: Map.get(kv, "description"),
         tools: parse_tools(Map.get(kv, "tools")),
         model: non_empty(Map.get(kv, "model")),
         effort: parse_effort(Map.get(kv, "effort")),
         prewalk: Map.get(kv, "prewalk") == "true",
         max_turns: parse_int(Map.get(kv, "max_turns")),
         system_prompt_addition: if(body == "", do: nil, else: body)
       }}
    end
  end

  defp parse_tools(nil), do: nil
  defp parse_tools(""), do: nil

  defp parse_tools(csv) do
    csv
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_effort(nil), do: nil
  defp parse_effort(""), do: nil

  defp parse_effort(value) do
    if value in ~w(low medium high xhigh max), do: value, else: nil
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  # ----------------------------------------------------------------- discovery

  # spec 73 T47: `list/1` used to list and re-parse every tier on each call —
  # from `SpawnAgent.description/0` on every `Tools.builtin_ref/1`, i.e. inside
  # the RunServer's start_agent call, from `resolve/2` in every spawn op and
  # from the Settings page per render. The bundled tier never changes at
  # runtime and is parsed once per VM; the user and project tiers are memoised
  # per directory for #{@tier_ttl_ms} ms and until the directory's mtime moves
  # (a file added, removed or renamed is seen at once; an edit in place inside
  # the window is the only stale case).
  @tier_ttl_ms 2_000

  @doc "Discover agents from three tiers, project > user > bundled."
  @spec list(String.t() | nil) :: [AgentDef.t()]
  def list(project_root) do
    project =
      if project_root,
        do: tier_cached(Path.join([project_root, ".swarm_code", "agents"]), :project),
        else: []

    dedupe(project ++ tier_cached(user_agents_dir(), :user) ++ bundled())
  end

  @doc "The bundled tier (`priv/agents`), parsed once per VM (spec 73 T47)."
  @spec bundled() :: [AgentDef.t()]
  def bundled do
    key = {__MODULE__, :bundled}

    case :persistent_term.get(key, nil) do
      nil ->
        defs = read_tier(bundled_agents_dir(), :bundled)
        :persistent_term.put(key, defs)
        defs

      defs ->
        defs
    end
  end

  defp tier_cached(dir, source) do
    key = {:agents, dir}
    now = System.monotonic_time(:millisecond)
    mtime = dir_mtime(dir)

    case SwarmCode.Domain.Cache.get(key) do
      %{defs: defs, mtime: ^mtime, at: at} when now - at < @tier_ttl_ms ->
        defs

      _stale ->
        defs = read_tier(dir, source)
        SwarmCode.Domain.Cache.put(key, %{defs: defs, mtime: mtime, at: now})
        defs
    end
  end

  defp dir_mtime(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: mtime}} -> mtime
      _other -> nil
    end
  end

  # First name wins, case-insensitively, in tier order.
  defp dedupe(defs) do
    defs
    |> Enum.reduce({[], MapSet.new()}, fn def_, {acc, seen} ->
      lower = String.downcase(def_.name)

      if MapSet.member?(seen, lower),
        do: {acc, seen},
        else: {[def_ | acc], MapSet.put(seen, lower)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp read_tier(dir, source) do
    if dir && File.dir?(dir) do
      dir
      |> ls_md()
      |> Enum.flat_map(fn filename ->
        path = Path.join(dir, filename)

        case File.read(path) do
          {:ok, content} ->
            case parse(content) do
              {:ok, def_} ->
                # If no name was in frontmatter, use the filename
                def_ =
                  if def_.name == nil or def_.name == "",
                    do: %{def_ | name: Path.rootname(filename)},
                    else: def_

                [%{def_ | source: source}]

              {:error, reason} ->
                Logger.warning("Skipping agent #{path}: #{reason}")
                []
            end

          {:error, reason} ->
            Logger.warning("Cannot read agent #{path}: #{inspect(reason)}")
            []
        end
      end)
    else
      []
    end
  end

  @doc "Resolve a single agent by name (case-insensitive)."
  @spec resolve(String.t(), String.t() | nil) :: AgentDef.t() | nil
  def resolve(name, project_root) do
    lower = String.downcase(name)
    Enum.find(list(project_root), fn d -> String.downcase(d.name) == lower end)
  end

  # spec 73 T46: `File.ls!/1` raised on an unreadable directory — under
  # `SpawnAgent.description/0` that was inside the RunServer's start_agent
  # call, and the run died with it. An unreadable tier is logged and empty.
  defp ls_md(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries |> Enum.filter(&String.ends_with?(&1, ".md")) |> Enum.sort()

      {:error, reason} ->
        Logger.warning("Cannot list agents in #{dir}: #{inspect(reason)}")
        []
    end
  end

  defp user_agents_dir do
    Path.join([System.user_home!(), ".swarm_code", "agents"])
  end

  defp bundled_agents_dir do
    Application.app_dir(:swarm_code_daemon, "priv/agents")
  end
end
