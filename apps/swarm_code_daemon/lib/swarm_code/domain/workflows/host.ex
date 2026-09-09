defmodule SwarmCode.Domain.Workflows.Host do
  @moduledoc """
  The deterministic host helpers a workflow program may call (spec 09 §3,
  spec 11 §7.1, `host/2`). Every result is journaled, so a replay never re-reads
  the world.

  They are the **only** way a definition may touch the file system: every path
  is resolved against the project root (the BEAM's cwd is something else
  entirely) and can never leave it, and every result is a plain, JSON-encodable
  value that survives a journal replay unchanged (`normalize/2` puts the atom
  keys back).
  """

  alias SwarmCode.Domain.Git

  @cap 200_000
  @max_entries 5_000
  @max_matches 200

  @ops ~w(changed_files git_diff git_log glob files subdirs read_file list_dir
          exists? dir? grep now)a

  @doc "The operations `host/2` accepts."
  def ops, do: @ops

  @doc """
  True when the op only reads the world. Read-only ops run for real in the
  smoke check (spec 11 §7.2); today every host op is read-only.
  """
  @spec read_only?(atom()) :: boolean()
  def read_only?(op), do: op in @ops

  @doc """
  Runs one host op inside `root`. Returns the value the script sees.
  """
  @spec run(atom(), keyword() | map(), String.t()) :: term()
  def run(op, opts, root) do
    opts = Map.new(opts)
    path = to_string(Map.get(opts, :path) || ".")

    case op do
      :changed_files -> changed_files(root, to_string(Map.get(opts, :base) || ""))
      :git_diff -> git_diff(root, opts)
      :git_log -> git_log(root, opts)
      :glob -> glob(root, pattern(opts, "**"), :all)
      :files -> glob(root, pattern(opts, "**"), :files)
      :subdirs -> subdirs(root, path)
      :read_file -> read_file(root, path)
      :list_dir -> list_dir(root, path)
      :exists? -> with_path(root, path, false, &File.exists?/1)
      :dir? -> with_path(root, path, false, &File.dir?/1)
      :grep -> grep(root, pattern(opts, ""), path)
      :now -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    end
  end

  @doc """
  Puts the atom keys of a host result back after a journal replay (a replayed
  value comes back from JSON with string keys, and a script must not see a
  different shape than it did live).
  """
  @spec normalize(atom(), term()) :: term()
  def normalize(:list_dir, entries) when is_list(entries),
    do: Enum.map(entries, &entry(&1, [:name, :path, :dir?]))

  def normalize(:grep, matches) when is_list(matches),
    do: Enum.map(matches, &entry(&1, [:file, :line, :text]))

  def normalize(:git_log, commits) when is_list(commits),
    do: Enum.map(commits, &entry(&1, [:sha, :date, :subject]))

  def normalize(_op, value), do: value

  defp entry(map, keys) when is_map(map) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> Map.put(acc, key, Map.get(map, to_string(key)))
      end
    end)
  end

  defp entry(other, _keys), do: other

  defp pattern(opts, default) do
    to_string(Map.get(opts, :pattern) || Map.get(opts, :glob) || Map.get(opts, :path) || default)
  end

  # ------------------------------------------------------------------ git

  defp changed_files(root, base) do
    case revision_args(base) do
      {:ok, revision} ->
        tracked = git(root, ["diff", "--name-only"] ++ revision)
        untracked = git(root, ["ls-files", "--others", "--exclude-standard"])

        (tracked ++ untracked)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, message} ->
        message
    end
  end

  defp git_diff(root, opts) do
    base = to_string(Map.get(opts, :base) || "")
    paths = Map.get(opts, :paths) || []

    case revision_args(base) do
      {:ok, revision} ->
        args =
          ["diff"] ++
            revision ++
            if(paths == [], do: [], else: ["--" | Enum.map(paths, &to_string/1)])

        root |> git_raw(args) |> String.slice(0, @cap)

      {:error, message} ->
        message
    end
  end

  defp git_log(root, opts) do
    n = opts |> Map.get(:n, Map.get(opts, :count, 20)) |> to_int(20) |> min(500) |> max(1)
    path = to_string(Map.get(opts, :path) || "")

    case safe_join(root, path) do
      {:ok, _} ->
        args =
          ["log", "-n", to_string(n), "--pretty=format:%h\t%ad\t%s", "--date=short"] ++
            if path in ["", "."], do: [], else: ["--", path]

        root
        |> git(args)
        |> Enum.map(fn line ->
          case String.split(line, "\t", parts: 3) do
            [sha, date, subject] -> %{sha: sha, date: date, subject: subject}
            [sha, date] -> %{sha: sha, date: date, subject: ""}
            _ -> %{sha: String.trim(line), date: "", subject: ""}
          end
        end)

      {:error, :outside_root} ->
        []
    end
  end

  # ------------------------------------------------------------------ files

  # Spec 51 §7.1 (E3): `Path.wildcard/2` walked `_build.noindex` and every entry
  # was then confined with a fresh `real_path(root)`. `Tools.Path.walk/3` prunes
  # the build and vendor directories before entering them, resolves the root
  # once and matches the same glob shapes (`**`, `*`, `?`, `{a,b}`, `[…]`).
  defp glob(root, pattern, kind) do
    SwarmCode.Domain.Tools.Path.walk(root, root, glob: pattern, dirs: kind == :all, dot: false)
    |> Enum.map(&relative(&1, root))
    |> Enum.sort()
    |> Enum.take(@max_entries)
  end

  defp subdirs(root, path) do
    with {:ok, dir} <- safe_join(root, path),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.filter(&File.dir?(Path.join(dir, &1)))
      |> Enum.map(&relative(Path.join(dir, &1), root))
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp read_file(root, path) do
    case safe_join(root, path) do
      {:ok, full} ->
        case File.read(full) do
          {:ok, text} -> String.slice(text, 0, @cap)
          {:error, reason} -> "Error: #{:file.format_error(reason)}"
        end

      {:error, :outside_root} ->
        "path is outside the project root: #{path}"
    end
  end

  defp list_dir(root, path) do
    with {:ok, dir} <- safe_join(root, path),
         {:ok, entries} <- File.ls(dir) do
      entries
      |> Enum.sort()
      |> Enum.take(@max_entries)
      |> Enum.map(fn name ->
        full = Path.join(dir, name)
        %{name: name, path: relative(full, root), dir?: File.dir?(full)}
      end)
    else
      _ -> []
    end
  end

  # `git grep` when the project is a repo (fast, respects .gitignore), a plain
  # scan otherwise. Both return the same shape.
  defp grep(_root, "", _path), do: []

  defp grep(root, pattern, path) do
    case safe_join(root, path) do
      {:error, :outside_root} ->
        []

      {:ok, _} ->
        scope = if path in ["", "."], do: [], else: ["--", path]

        if Git.repo?(root) do
          git(
            root,
            ["grep", "-n", "-I", "-F", "--untracked", "--no-color", "-e", pattern] ++ scope
          )
          |> Enum.take(@max_matches)
          |> Enum.map(fn line ->
            case String.split(line, ":", parts: 3) do
              [file, no, text] ->
                %{file: file, line: to_int(no, 0), text: String.slice(String.trim(text), 0, 300)}

              _ ->
                %{file: String.trim(line), line: 0, text: ""}
            end
          end)
        else
          scan(root, pattern, path)
        end
    end
  end

  # Spec 51 §7.1 (E3): the same pruned, confined walk as `glob/3` above — a
  # workflow's `host(:grep, …)` no longer reads the build directory.
  defp scan(root, pattern, path) do
    {:ok, base} = safe_join(root, path)

    files =
      if File.dir?(base),
        do: SwarmCode.Domain.Tools.Path.walk(root, base, dot: false),
        else: [base]

    files
    |> Enum.flat_map(fn file ->
      case File.read(file) do
        {:ok, text} ->
          text
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _i} -> String.contains?(line, pattern) end)
          |> Enum.map(fn {line, i} ->
            %{
              file: relative(file, root),
              line: i,
              text: String.slice(String.trim(line), 0, 300)
            }
          end)

        _ ->
          []
      end
    end)
    |> Enum.take(@max_matches)
  end

  # ------------------------------------------------------------------ paths

  # Every path is root-relative and can never escape the project.
  # Spec 13 §11 A-11: symlinks are resolved before the prefix test, so a link
  # inside the repo cannot walk a workflow script out of the project.
  defp safe_join(root, path) do
    case SwarmCode.Domain.Tools.Path.resolve(root, path) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _message} -> {:error, :outside_root}
    end
  end

  defp with_path(root, path, fallback, fun) do
    case safe_join(root, path) do
      {:ok, resolved} -> fun.(resolved)
      {:error, :outside_root} -> fallback
    end
  end

  defp relative(path, root), do: Path.relative_to(Path.expand(path), Path.expand(root))

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp git(root, args), do: root |> git_raw(args) |> String.split("\n", trim: true)

  defp git_raw(root, args) do
    if Git.repo?(root) do
      case Git.run(root, args) do
        {:ok, out} -> out
        {:error, out} -> if String.contains?(out, "fatal:"), do: "", else: out
      end
    else
      ""
    end
  end

  defp revision_args(""), do: {:ok, []}

  defp revision_args(revision) do
    case Git.validate_revision(revision) do
      {:ok, revision} -> {:ok, [revision]}
      {:error, message} -> {:error, message}
    end
  end
end
