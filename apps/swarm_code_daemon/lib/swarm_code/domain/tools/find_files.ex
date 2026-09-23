defmodule SwarmCode.Domain.Tools.FindFiles do
  @moduledoc """
  Find a file by name (spec 67 T27 / G36).

  There was no way to ask "where is `run_command.ex`". `list_dir` recurses three
  levels and stops at 500 entries, `grep` searches *contents*, and the model's
  fallback was `run_command` with `find` — a command, so an approval in every
  mode that asks for one, and one that walks `node_modules` because `find` has
  never heard of `.gitignore`. Codex ships the same tool over `ignore::
  WalkBuilder` (`file-search/src/lib.rs:431-446`).
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.Path
  alias SwarmCode.Domain.Tools.Ripgrep

  @max_results 200
  @default_results 50

  @impl true
  def name, do: "find_files"

  @impl true
  def description,
    do:
      "Find files by name or path. pattern is a glob (\"*.ex\", \"lib/**/*_test.exs\") or, " <>
        "when it has no glob character, a case-insensitive substring of the path " <>
        "(\"run_command\" finds lib/swarm_code/tools/run_command.ex). Returns paths relative " <>
        "to the project root, shortest first, at most max_results of them (1-200, default 50). " <>
        "What .gitignore ignores is skipped — pass include_ignored: true to search it too. " <>
        "Use grep to search file contents."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" =>
            "Glob (\"*.ex\", \"lib/**/*_test.exs\") or a substring of the path (\"run_command\")"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory to search under, relative to the project root (default \".\")"
        },
        "max_results" => %{
          "type" => "integer",
          "description" => "1-200, default 50"
        },
        "include_ignored" => %{
          "type" => "boolean",
          "description" => "Search what .gitignore ignores as well (default false)"
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "find " <> String.slice(to_string(args["pattern"] || ""), 0, 60)

  @impl true
  def run(args, ctx, progress) do
    pattern = String.trim(to_string(args["pattern"] || ""))

    if pattern == "" do
      {:error, "find_files needs a pattern — a glob like \"*.ex\" or a substring of the path"}
    else
      search(pattern, args, ctx, progress)
    end
  end

  defp search(pattern, args, ctx, progress) do
    with {:ok, start} <- Path.resolve(ctx.project_root, args["path"] || ".") do
      if File.dir?(start) do
        progress.(50, "searching")
        root = ctx.project_root
        limit = limit(args)

        # spec 70 C4: use rg --files when available.
        matches =
          if Ripgrep.available?() do
            case rg_find(pattern, start, root, args) do
              {:ok, paths} -> paths |> filter(pattern) |> sort()
              :fallback -> elixir_find(pattern, start, root, args)
            end
          else
            elixir_find(pattern, start, root, args)
          end

        progress.(100, "#{length(matches)} matches")
        {:ok, render(matches, limit, pattern)}
      else
        {:error, "not a directory: #{Path.relative(ctx.project_root, start)}"}
      end
    end
  end

  # spec 70 C4: the original Elixir-based Path.walk, extracted for fallback.
  defp elixir_find(pattern, start, root, args) do
    root
    |> Path.walk(start, walk_opts(pattern, args))
    |> Enum.map(&Path.relative(root, &1))
    |> filter(pattern)
    |> sort()
  end

  # spec 70 C4: rg --files based file search.
  # We do NOT pass the glob to rg because rg's gitignore-style glob matching
  # differs from Path.walk's glob matching (anchoring, ** semantics). Instead
  # rg lists all files and we apply the same glob/substring filter in Elixir.
  @ignored_globs ~w(_build* .git deps node_modules .elixir_ls .superpowers .DS_Store cover doc)

  defp rg_find(_pattern, start, root, args) do
    rg = Ripgrep.rg_path()
    include_ignored = args["include_ignored"] == true

    base_args = ["--files", "--no-follow", "--color", "never", "--hidden"]

    # spec 73 T99: the skip globs apply either way — `include_ignored` adds
    # the .gitignore'd files on top, as the description says and as the
    # Elixir walk does; it used to drop the globs, so `*.beam` with
    # include_ignored listed _build and deps.
    skip = Enum.flat_map(@ignored_globs, &["--glob", "!#{&1}"])
    ignore_args = if include_ignored, do: ["--no-ignore"], else: []
    all_args = base_args ++ skip ++ ignore_args ++ [start]

    case System.cmd(rg, all_args,
           cd: root,
           env: [{"HOME", System.user_home!()}],
           stderr_to_stdout: true
         ) do
      {output, code} when code in [0, 1] ->
        paths =
          output
          |> String.split("\n", trim: true)
          |> Enum.reduce([], fn line, acc ->
            abs = Elixir.Path.expand(line)

            if String.starts_with?(abs, root <> "/") or abs == root do
              [Path.relative(root, abs) | acc]
            else
              acc
            end
          end)
          |> Enum.reverse()

        {:ok, paths}

      _ ->
        :fallback
    end
  rescue
    _ -> :fallback
  end

  # A pattern with a glob character is a glob and `Path.walk/3` matches it while
  # it walks; anything else is a substring of the path, which is what a model
  # that half-remembers a file name actually has.
  defp glob?(pattern), do: String.match?(pattern, ~r/[*?\[\]{}]/)

  defp walk_opts(pattern, args) do
    [dot: true, ignored: args["include_ignored"] == true] ++
      if glob?(pattern), do: [glob: pattern], else: []
  end

  defp filter(paths, pattern) do
    if glob?(pattern) do
      # spec 70 C4: for the rg path, glob filtering happens here rather than
      # during the walk. Path.walk applies globs during the walk; rg --files
      # does not, so we match here. The Elixir path's walker already filtered,
      # but re-filtering is a no-op (all paths match).
      matcher = compile_glob(pattern)

      Enum.filter(paths, fn path ->
        name = Elixir.Path.basename(path)
        glob_match?(matcher, path, name)
      end)
    else
      needle = String.downcase(pattern)
      Enum.filter(paths, &String.contains?(String.downcase(&1), needle))
    end
  end

  # spec 70 C4: compile a glob to a regex matcher, same logic as Path.walk.
  defp compile_glob(glob) do
    re =
      case Regex.compile("^" <> glob_source(glob) <> "$") do
        {:ok, re} -> re
        {:error, _} -> Regex.compile!("^" <> Regex.escape(glob) <> "$")
      end

    if String.contains?(glob, "/"), do: {:path, re}, else: {:base, re}
  end

  defp glob_match?({:base, re}, _path, name), do: Regex.match?(re, name)
  defp glob_match?({:path, re}, path, _name), do: Regex.match?(re, path)

  defp glob_source(""), do: ""
  defp glob_source("**/" <> rest), do: "(?:[^/]+/)*" <> glob_source(rest)
  defp glob_source("**" <> rest), do: ".*" <> glob_source(rest)
  defp glob_source("*" <> rest), do: "[^/]*" <> glob_source(rest)
  defp glob_source("?" <> rest), do: "[^/]" <> glob_source(rest)

  defp glob_source("{" <> rest) do
    case String.split(rest, "}", parts: 2) do
      [alternatives, tail] ->
        body = alternatives |> String.split(",") |> Enum.map_join("|", &Regex.escape/1)
        "(?:" <> body <> ")" <> glob_source(tail)

      _no_close ->
        Regex.escape("{") <> glob_source(rest)
    end
  end

  defp glob_source("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [set, tail] when set != "" ->
        set =
          if String.starts_with?(set, "!"),
            do: "^" <> binary_part(set, 1, byte_size(set) - 1),
            else: set

        "[" <> set <> "]" <> glob_source(tail)

      _no_close ->
        Regex.escape("[") <> glob_source(rest)
    end
  end

  defp glob_source(<<c::utf8, rest::binary>>), do: Regex.escape(<<c::utf8>>) <> glob_source(rest)

  # Shortest first: the file the model means is almost always the shallow one
  # (`lib/app/user.ex` before `test/support/fixtures/user.ex`), and a tie is
  # broken alphabetically so the list is stable between calls.
  defp sort(paths) do
    Enum.sort_by(paths, &{length(Elixir.Path.split(&1)), byte_size(&1), &1})
  end

  defp limit(args) do
    case args["max_results"] do
      n when is_integer(n) -> n |> max(1) |> min(@max_results)
      _other -> @default_results
    end
  end

  defp render([], _limit, pattern), do: "no file matches #{pattern}"

  defp render(matches, limit, _pattern) do
    shown = Enum.take(matches, limit)
    extra = length(matches) - length(shown)
    text = Enum.join(shown, "\n")

    if extra > 0,
      do: text <> "\n…[#{extra} more matches — narrow the pattern or raise max_results]",
      else: text
  end
end
