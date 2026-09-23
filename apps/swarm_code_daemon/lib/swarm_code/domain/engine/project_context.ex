defmodule SwarmCode.Domain.Engine.ProjectContext do
  @moduledoc """
  The per-run project context every agent of a run shares: the project's
  instructions file (AGENTS.md and friends) and the memory files.

  Built once when a run starts and passed to the RunServer, so the assistant, the
  lead and every sub-agent see exactly the same text.
  """

  alias SwarmCode.Domain.Projects.Workspace

  # spec 66 T15: the candidates of **one directory**, most specific first
  # (Codex's `AGENTS.override.md` in front of today's three). The instructions
  # of a project are now every directory's first hit, root first, not the root's
  # alone — in a monorepo the package conventions the agent is about to violate
  # used to be invisible.
  @instruction_files ~w(AGENTS.override.md AGENTS.md SWARMCODE.md CLAUDE.md)
  # The file the editor writes. `AGENTS.override.md` is deliberately not here:
  # an override is written by hand, and the editor still edits the normal file.
  @editable_files ~w(AGENTS.md SWARMCODE.md CLAUDE.md)
  @instructions_cap 32_000
  # How far below the root a package's own file is still loaded, and how many
  # files in total (Codex: root→cwd; SwarmCode has no cwd, so it is a depth).
  @instructions_depth 3
  @instructions_files_cap 12
  @memory_cap 16_000

  @type t :: %{
          instructions: String.t() | nil,
          memory: String.t() | nil,
          goal: String.t() | nil,
          goals: [String.t()],
          mode: String.t(),
          project_config: SwarmCode.Domain.ProjectConfig.t() | nil
        }

  @spec build(map() | nil, map() | nil) :: t()
  def build(project, conversation \\ nil) do
    # spec 70 D1: load per-project config from .swarm_code/config.json
    {:ok, project_config} =
      SwarmCode.Domain.ProjectConfig.load(project && Map.get(project, :root_path))

    %{
      instructions: instructions(project),
      memory: memory(project),
      goal: conversation && Map.get(conversation, :goal),
      goals: goals(conversation),
      mode: (conversation && Map.get(conversation, :mode)) || "build",
      project_config: project_config
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
    Enum.find_value(@editable_files, Path.join(root, "AGENTS.md"), fn name ->
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

  @doc """
  The project's instruction files, root first and shallowest first, head-capped
  at 32 000 characters in total (spec 66 T15).

  One file per directory (the first of `@instruction_files` that is there), down
  to three directories below the root and twelve files. A single file reads
  exactly as it always did — the `--- <path> ---` headers only appear once there
  is more than one file to tell apart.
  """
  @spec instructions(map() | nil) :: String.t() | nil
  def instructions(nil), do: nil

  # spec 67 T31 (G44): an untrusted project's instructions reach no prompt.
  # Adding `~/Downloads/some-repo` used to put that repository's AGENTS.md —
  # written by whoever published it — in the system prompt of the first turn,
  # before the user had agreed to anything. Codex skips it for the same reason
  # (`core/src/agents_md.rs:61-63`).
  def instructions(%{trusted_at: nil}), do: ""

  def instructions(%{root_path: root}) do
    case collect_instructions(root) do
      [] -> nil
      [{_rel, text}] -> head(text, @instructions_cap)
      files -> layered(files, @instructions_cap, [])
    end
  end

  def instructions(_), do: nil

  # Every directory's first candidate, in prompt order. The walk is bounded by
  # `@instructions_depth` on purpose: `Tools.Path.walk/3` over a whole
  # repository costs ~500 ms (spec 51 §7.1's own measurement) and this runs at
  # every run start.
  defp collect_instructions(root) do
    root = Path.expand(root)

    case SwarmCode.Domain.Tools.Path.real_path(root) do
      {:ok, real_root} -> descend(real_root, root, [{root, 0}], [])
      _error -> []
    end
    |> Enum.sort_by(fn {depth, rel, _abs} -> {depth, rel} end)
    |> Enum.take(@instructions_files_cap)
    |> Enum.flat_map(fn {_depth, rel, abs} ->
      case File.read(abs) do
        {:ok, text} -> if String.trim(text) == "", do: [], else: [{rel, text}]
        _error -> []
      end
    end)
  end

  defp descend(_real_root, _root, [], acc), do: acc

  defp descend(real_root, root, [{dir, depth} | rest], acc) do
    # `entries/4` already drops `_build*`, `deps`, `node_modules`, `.git` and
    # every nested checkout, and confines each entry against the real root, so
    # a symlinked AGENTS.md pointing outside the project is never listed.
    entries = SwarmCode.Domain.Tools.Path.entries(real_root, root, dir, false)

    acc =
      case pick(entries) do
        nil -> acc
        abs -> [{depth, SwarmCode.Domain.Tools.Path.relative(root, abs), abs} | acc]
      end

    queue =
      if depth < @instructions_depth do
        for {_name, :directory, abs, _real} <- entries, do: {abs, depth + 1}
      else
        []
      end

    descend(real_root, root, rest ++ queue, acc)
  end

  defp pick(entries) do
    Enum.find_value(@instruction_files, fn name ->
      Enum.find_value(entries, fn
        {^name, :regular, abs, _real} -> abs
        _other -> nil
      end)
    end)
  end

  # Root first, each behind its own header, sharing one 32 000-character budget.
  defp layered([], _left, acc), do: join(acc, [])

  defp layered([{rel, text} | rest], left, acc) do
    header = "--- " <> rel <> " ---\n"
    room = left - String.length(header) - 1

    cond do
      room < 200 ->
        join(acc, [rel | Enum.map(rest, &elem(&1, 0))])

      String.length(text) > room ->
        join(
          [header <> String.slice(text, 0, room) <> "\n…[truncated]" | acc],
          Enum.map(rest, &elem(&1, 0))
        )

      true ->
        layered(rest, room - String.length(text), [header <> text | acc])
    end
  end

  defp join(acc, omitted) do
    text = acc |> Enum.reverse() |> Enum.join("\n")

    case omitted do
      [] ->
        text

      paths ->
        text <>
          "\n…[#{length(paths)} more instruction files omitted: #{Enum.join(paths, ", ")}]"
    end
  end

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
