defmodule SwarmCode.Domain.Tools.ListDir do
  @moduledoc "List files and directories of the project."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.Path

  @max_entries 500
  @max_count 5_000

  @impl true
  def name, do: "list_dir"

  @impl true
  # Spec 54 §5 (54c H9): the 500-entry stop was invisible from the old text.
  def description,
    do:
      "List the files and directories under a path in the project; directories end with \"/\". " <>
        "depth 1 is the directory itself, up to 3 recurses that many levels. The usual ignored " <>
        "directories are skipped, and the listing stops at 500 entries, so a large tree comes " <>
        "back truncated — narrow the path or use grep when you are looking for something " <>
        "specific. It returns names, not file contents or sizes."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path relative to the project root (default \".\")"
        },
        "depth" => %{"type" => "integer", "description" => "Recursion depth 1-3 (default 1)"}
      },
      "required" => []
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "list " <> (args["path"] || ".")

  @impl true
  def run(args, ctx, progress) do
    with {:ok, abs} <- Path.resolve(ctx.project_root, args["path"] || ".") do
      rel = Path.relative(ctx.project_root, abs)

      if File.dir?(abs) do
        depth = (args["depth"] || 1) |> max(1) |> min(3)
        progress.(50, "listing")
        {lines, emitted, counted} = walk(abs, "", 1, depth, [], 0, 0, root_pair(ctx))
        lines = Enum.reverse(lines)
        extra = counted - emitted

        out =
          cond do
            emitted == 0 -> "(empty)"
            extra > 0 -> Enum.join(lines, "\n") <> "\n…[+#{extra} more]"
            true -> Enum.join(lines, "\n")
          end

        progress.(100, "#{emitted} entries")
        {:ok, out}
      else
        {:error, "not a directory: #{rel}"}
      end
    end
  end

  # Spec 51 §7.1 (E3): the root's symlinks were re-resolved once per entry.
  # `real_path/1` runs once per op now and travels down the walk.
  defp root_pair(ctx) do
    root = Elixir.Path.expand(ctx.project_root)

    case Path.real_path(root) do
      {:ok, real_root} -> {real_root, root}
      _error -> {root, root}
    end
  end

  # Sakana task 2/3: `File.ls/1` happily follows a symlinked directory, so a
  # link pointing outside the project used to list — and recurse into — the
  # target's children. Every entry is confined before it is named or entered:
  # `Path.entries/4` is the same pruned, confined listing `Path.walk/3` is
  # built on (spec 51 §7.1).
  defp walk(dir, prefix, level, depth, lines, emitted, counted, {real_root, root} = roots) do
    {dirs, files} =
      real_root
      |> Path.entries(root, dir)
      |> Enum.split_with(fn {_name, type, _full, _real} -> type == :directory end)

    Enum.reduce(dirs ++ files, {lines, emitted, counted}, fn {name, type, full, _real},
                                                             {lines, emitted, counted} ->
      if counted >= @max_count do
        {lines, emitted, counted}
      else
        is_dir = type == :directory
        text = if is_dir, do: "#{prefix}#{name}/", else: "#{prefix}#{name}"

        {lines, emitted} =
          if emitted < @max_entries, do: {[text | lines], emitted + 1}, else: {lines, emitted}

        counted = counted + 1

        if is_dir and level < depth do
          walk(full, prefix <> name <> "/", level + 1, depth, lines, emitted, counted, roots)
        else
          {lines, emitted, counted}
        end
      end
    end)
  end
end
