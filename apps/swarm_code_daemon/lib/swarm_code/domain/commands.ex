defmodule SwarmCode.Domain.Commands do
  @moduledoc """
  Custom slash commands stored as Markdown files.

  Project commands live in `<root>/.swarm_code/commands/*.md`, global ones under
  the config dir. A file is optional front matter between `---` lines
  (`description`, `swarm`, `mode`) plus the message template; `$ARGUMENTS` is
  replaced by whatever the user typed after the command.
  """

  alias SwarmCode.Domain.Projects.Workspace

  @type t :: %{
          name: String.t(),
          description: String.t(),
          scope: :project | :global,
          swarm: boolean(),
          mode: String.t() | nil,
          body: String.t(),
          path: String.t()
        }

  @template """
  ---
  description: What this command does
  swarm: false
  ---
  Write the prompt the agent should receive here.

  Arguments typed after the command land here: $ARGUMENTS
  """

  @doc "Every command visible to `project`; project files override global ones."
  @spec list(map() | nil) :: [t()]
  def list(project \\ nil) do
    global = read_dir(Workspace.global_commands_dir(), :global)

    project_commands =
      case project do
        %{root_path: root} -> read_dir(Workspace.commands_dir(root), :project)
        _ -> []
      end

    (project_commands ++ global)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @spec get(map() | nil, String.t()) :: t() | nil
  def get(project, name) do
    name = name |> to_string() |> String.downcase()
    Enum.find(list(project), &(&1.name == name))
  end

  @doc "Fills `$ARGUMENTS` in the command body."
  @spec expand(t(), String.t()) :: String.t()
  def expand(command, arguments) do
    arguments = arguments |> to_string() |> String.trim()

    command.body
    |> String.replace("$ARGUMENTS", arguments)
    |> String.trim()
  end

  @doc "Creates a starter command file in the project (or global) commands folder."
  @spec create(map() | nil, :project | :global, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create(project, scope, name \\ "new-command") do
    dir = dir_for(project, scope)

    if dir do
      File.mkdir_p(dir)
      path = Path.join(dir, name <> ".md")

      if File.exists?(path) do
        {:ok, path}
      else
        case File.write(path, @template) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, to_string(reason)}
        end
      end
    else
      {:error, "no project selected"}
    end
  end

  @spec dir_for(map() | nil, :project | :global) :: String.t() | nil
  def dir_for(%{root_path: root}, :project), do: Workspace.commands_dir(root)
  def dir_for(_project, :project), do: nil
  def dir_for(_project, :global), do: Workspace.global_commands_dir()

  defp read_dir(dir, scope) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&parse_file(Path.join(dir, &1), scope))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_file(path, scope) do
    case File.read(path) do
      {:ok, text} ->
        name = path |> Path.basename(".md") |> String.downcase()
        {front, body} = split(text)

        %{
          name: name,
          description: front["description"] || name,
          scope: scope,
          swarm: truthy?(front["swarm"]),
          mode: mode(front["mode"]),
          body: String.trim(body),
          path: path
        }

      _ ->
        nil
    end
  end

  @doc false
  def split("---\n" <> rest) do
    case String.split(rest, ~r/^---\s*$/m, parts: 2) do
      [front, body] -> {parse_front(front), body}
      _ -> {%{}, "---\n" <> rest}
    end
  end

  def split(text), do: {%{}, text}

  defp parse_front(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] ->
          key = k |> String.trim() |> String.downcase()
          if key == "", do: [], else: [{key, String.trim(v)}]

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  defp truthy?(value),
    do: to_string(value) |> String.downcase() |> Kernel.in(["true", "yes", "1"])

  defp mode(value) do
    case value |> to_string() |> String.downcase() do
      "plan" -> "plan"
      "build" -> "build"
      _ -> nil
    end
  end
end
