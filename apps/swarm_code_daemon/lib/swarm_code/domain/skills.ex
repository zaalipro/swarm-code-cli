defmodule SwarmCode.Domain.Skills do
  @moduledoc """
  Skills: a folder with a `SKILL.md` and whatever assets it needs, injected into
  one agent's system prompt (spec 25 §1).

  Discovery, scope precedence and the builtin cache are the same shape as
  `SwarmCode.Domain.Workflows` on purpose — project shadows user shadows builtin — so
  there is one set of rules to learn for both.
  """

  alias SwarmCode.Domain.Projects.Workspace
  alias SwarmCode.Domain.Skills.Skill

  # A skill is prompt text, and prompt text is the scarcest thing an agent has.
  @asset_cap 24_000
  @prompt_cap 80_000

  @doc "Every skill visible in `project`, shadowed names removed."
  @spec list(map() | nil) :: [Skill.t()]
  def list(project \\ nil) do
    (builtins() ++ scope_list(user_dir(), "user") ++ scope_list(project_dir(project), "project"))
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc "The skill `name` resolves to in `project`, or nil."
  @spec get(map() | nil, String.t()) :: Skill.t() | nil
  def get(project \\ nil, name) do
    name = to_string(name)

    # spec 60 T23: only the named skill is read, project → user → builtin (the
    # precedence `list/1` gives), and the name cannot leave the skills dir.
    if name =~ ~r/^[A-Za-z0-9._-]+$/ do
      Enum.find_value([{project_dir(project), "project"}, {user_dir(), "user"}], fn {dir, scope} ->
        is_binary(dir) and read(Path.join(dir, name), scope)
      end) || Enum.find(builtins(), &(&1.name == name))
    else
      nil
    end
  end

  @doc "The built-in skills, parsed once and cached in `:persistent_term`."
  @spec builtins() :: [Skill.t()]
  def builtins do
    case :persistent_term.get({__MODULE__, :builtins}, nil) do
      nil ->
        parsed = scope_list(builtin_dir(), "builtin")
        :persistent_term.put({__MODULE__, :builtins}, parsed)
        parsed

      parsed ->
        parsed
    end
  end

  @doc false
  def reset_builtins, do: :persistent_term.erase({__MODULE__, :builtins})

  def builtin_dir, do: Path.join(:code.priv_dir(:swarm_code_daemon), "skills")

  def user_dir, do: Path.join(Workspace.global_dir(), "skills")

  def project_dir(nil), do: nil
  def project_dir(%{root_path: root}), do: Path.join([root, ".swarm_code", "skills"])
  def project_dir(root) when is_binary(root), do: Path.join([root, ".swarm_code", "skills"])

  @doc """
  The skill as one block of prompt text: `SKILL.md` first, then every asset
  under its own heading. Capped, because a skill competes with the actual task.
  """
  @spec prompt(Skill.t() | nil) :: String.t()
  def prompt(nil), do: ""

  def prompt(%Skill{} = skill) do
    assets =
      Enum.map_join(skill.assets, "\n\n", fn asset ->
        "----- #{skill.name}/#{asset.name} -----\n#{asset.body}"
      end)

    ["# Skill: #{skill.name}", skill.body, assets]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> cap(@prompt_cap)
  end

  @spec asset_cap() :: pos_integer()
  def asset_cap, do: @asset_cap

  @spec prompt_cap() :: pos_integer()
  def prompt_cap, do: @prompt_cap

  # ------------------------------------------------------------------ private

  defp scope_list(nil, _scope), do: []

  defp scope_list(dir, scope) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&read(&1, scope))
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp read(dir, scope) do
    case read_capped(Path.join(dir, "SKILL.md"), @asset_cap) do
      {:ok, text} ->
        %Skill{
          name: Path.basename(dir),
          scope: scope,
          path: dir,
          description: description(text),
          body: cap(String.trim(text), @asset_cap),
          assets: assets(dir)
        }

      _other ->
        nil
    end
  end

  # The first non-blank line that is not the `# title`.
  defp description(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> List.first()
    |> case do
      nil -> ""
      line -> String.slice(line, 0, 160)
    end
  end

  defp assets(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        for name <- Enum.sort(entries),
            name != "SKILL.md",
            path = Path.join(dir, name),
            File.regular?(path),
            {:ok, body} <- [read_capped(path, @asset_cap)],
            do: %{name: name, body: cap(body, @asset_cap)}

      _other ->
        []
    end
  end

  # spec 60 T23: at most `4 × limit + 4` bytes of a file — `cap/2` counts
  # characters, and a character is at most four bytes, so nothing under the cap
  # changes and a huge asset is never read whole.
  defp read_capped(path, limit) do
    max = 4 * limit + 4

    with {:ok, %File.Stat{size: size}} <- File.stat(path) do
      if size <= max do
        File.read(path)
      else
        case File.open(path, [:read, :binary], &IO.binread(&1, max)) do
          {:ok, data} when is_binary(data) -> {:ok, data}
          {:ok, _} -> {:error, :eio}
          err -> err
        end
      end
    end
  end

  defp cap(text, limit) do
    if String.length(text) > limit,
      do: String.slice(text, 0, limit) <> "\n…[truncated]",
      else: text
  end
end
