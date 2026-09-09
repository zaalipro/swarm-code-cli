defmodule SwarmCode.Domain.Engine.ProjectContext do
  @moduledoc """
  The per-run project context every agent of a run shares: the project's
  instructions file (AGENTS.md and friends) and the memory files.

  Built once when a run starts and passed to the RunServer, so the assistant, the
  lead and every sub-agent see exactly the same text.
  """

  alias SwarmCode.Domain.Projects.Workspace

  @instruction_files ~w(AGENTS.md SWARMCODE.md CLAUDE.md)
  @instructions_cap 32_000
  @memory_cap 16_000

  @type t :: %{
          instructions: String.t() | nil,
          memory: String.t() | nil,
          goal: String.t() | nil,
          goals: [String.t()],
          mode: String.t()
        }

  @spec build(map() | nil, map() | nil) :: t()
  def build(project, conversation \\ nil) do
    %{
      instructions: instructions(project),
      memory: memory(project),
      goal: conversation && Map.get(conversation, :goal),
      goals: goals(conversation),
      mode: (conversation && Map.get(conversation, :mode)) || "build"
    }
  end

  # Every goal the conversation is pursuing right now (spec 10 §19). A run
  # pursues one of them; the others are context.
  defp goals(nil), do: []

  defp goals(conversation) do
    case Map.get(conversation, :id) do
      id when is_binary(id) ->
        id |> SwarmCode.Domain.Conversations.open_goals() |> Enum.map(& &1.text)

      _ ->
        []
    end
  end

  @doc """
  The instructions file to edit: the first of AGENTS.md / SWARMCODE.md / CLAUDE.md
  that exists, else `<root>/AGENTS.md` (created on save).
  """
  @spec instructions_path(map()) :: String.t()
  def instructions_path(%{root_path: root}) do
    # Sakana task 3: an existing candidate that is a symlink out of the project
    # is ignored, so the editor cannot become an outside-root write primitive.
    # The fallback stays `<root>/AGENTS.md` so saving creates the normal file.
    Enum.find_value(@instruction_files, Path.join(root, "AGENTS.md"), fn name ->
      case safe_project_file(root, name) do
        {:ok, path} -> if File.regular?(path), do: path
        :error -> nil
      end
    end)
  end

  @doc """
  `name` resolved against `root`, but only when it stays inside the project once
  every symlink is followed. `:error` for anything that escapes or loops.
  """
  @spec safe_project_file(String.t(), String.t()) :: {:ok, String.t()} | :error
  def safe_project_file(root, name) do
    case SwarmCode.Domain.Tools.Path.resolve(root, name) do
      {:ok, path} -> {:ok, path}
      {:error, _} -> :error
    end
  end

  @doc "The instruction file names, most specific first."
  def instruction_files, do: @instruction_files

  @doc "The first of AGENTS.md / SWARMCODE.md / CLAUDE.md that exists, head-capped."
  @spec instructions(map() | nil) :: String.t() | nil
  def instructions(nil), do: nil

  def instructions(%{root_path: root}) do
    Enum.find_value(@instruction_files, fn name ->
      with {:ok, path} <- safe_project_file(root, name),
           true <- File.regular?(path),
           {:ok, text} <- File.read(path) do
        if String.trim(text) == "", do: nil, else: head(text, @instructions_cap)
      else
        _ -> nil
      end
    end)
  end

  def instructions(_), do: nil

  @doc "Project memory then global memory, each tail-capped."
  @spec memory(map() | nil) :: String.t() | nil
  def memory(project) do
    # Project memory is a project file and is confined like one; global memory
    # is intentionally global and keeps its own path.
    project_mem = project && read_project_memory(project.root_path)
    global_mem = read_tail(Workspace.global_memory_file())

    [
      project_mem && "Project memory:\n" <> project_mem,
      global_mem && "Global memory:\n" <> global_mem
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  @spec instructions_cap() :: pos_integer()
  def instructions_cap, do: @instructions_cap

  @doc "The prompt options this context contributes (see `Prompts.suffix/1`)."
  @spec to_opts(t() | nil) :: keyword()
  def to_opts(nil), do: []

  def to_opts(ctx) do
    [instructions: ctx[:instructions], memory: ctx[:memory]]
  end

  defp read_project_memory(root) do
    case safe_project_file(root, Workspace.memory_file(root)) do
      {:ok, path} -> read_tail(path)
      :error -> nil
    end
  end

  defp read_tail(path) do
    case File.read(path) do
      {:ok, text} ->
        trimmed = String.trim(text)
        if trimmed == "", do: nil, else: tail(trimmed, @memory_cap)

      _ ->
        nil
    end
  end

  defp head(text, cap) do
    if String.length(text) > cap,
      do: String.slice(text, 0, cap) <> "\n…[truncated]",
      else: text
  end

  defp tail(text, cap) do
    if String.length(text) > cap,
      do: "…[truncated]\n" <> String.slice(text, -cap, cap),
      else: text
  end
end
