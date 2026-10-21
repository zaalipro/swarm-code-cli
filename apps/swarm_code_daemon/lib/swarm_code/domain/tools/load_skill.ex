defmodule SwarmCode.Domain.Tools.LoadSkill do
  @moduledoc """
  pass 77 C-FEAT-2: lets an agent list the skills available in the project and
  load one on demand. A skill (a folder with `SKILL.md`) was only ever injected
  into the system prompt by the user's choice (`SwarmCode.Domain.Skills`); this reads
  the same files, with the same scope precedence, and returns the capped prompt
  text. Read-only.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Skills

  @max_listed 50
  @desc_chars 160

  @impl true
  def name, do: "load_skill"

  @impl true
  def description,
    do:
      "Load a skill — a folder of instructions (SKILL.md) saved in this project " <>
        "(.swarm_code/skills), for you in Settings → Library, or shipped with ncode. Call it " <>
        "with no name to list the skills available here; call it with a name to get that " <>
        "skill's instructions, then follow them."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "The skill's name; leave it out to list the available skills"
        }
      },
      "required" => []
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def parallel?, do: true

  @impl true
  def title(args) do
    case args["name"] do
      name when is_binary(name) and name != "" ->
        "load skill " <> SwarmCode.Domain.Tools.arg_text(name)

      _ ->
        "list skills"
    end
  end

  @impl true
  def run(args, ctx, _progress) do
    root = ctx[:project_root]

    case args["name"] do
      name when is_binary(name) and name != "" -> load(root, String.trim(name))
      _ -> list(root)
    end
  end

  defp list(root) do
    case Skills.list(root) do
      [] ->
        {:ok,
         "No skills are installed. Skills are folders with a SKILL.md in .swarm_code/skills " <>
           "of the project or in Settings → Library."}

      skills ->
        {shown, rest} = Enum.split(skills, @max_listed)

        lines =
          Enum.map(shown, fn skill ->
            "- #{skill.name} — #{String.slice(skill.description, 0, @desc_chars)}"
          end)

        more = if rest == [], do: [], else: ["…[+#{length(rest)} more]"]
        {:ok, Enum.join(lines ++ more, "\n")}
    end
  end

  defp load(root, name) do
    case Skills.get(root, name) do
      nil ->
        {:error, "no skill named #{name} — call load_skill without a name to list them"}

      skill ->
        {:ok, Skills.prompt(skill)}
    end
  end
end
