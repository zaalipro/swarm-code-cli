defmodule SwarmCode.Domain.Tools.Path do
  @moduledoc "Path confinement helpers: the only place model-supplied paths become absolute."

  # Spec 51 §7.1: `cover` and `doc` are Mix's and ExDoc's outputs — the same
  # class as `_build`, and 7 MB of HTML in this checkout (Blockers → A 44).
  @ignored ~w(.git _build deps node_modules .elixir_ls .superpowers .DS_Store cover doc)

  def resolve(root, path) do
    path = to_string(path || "")
    root = Elixir.Path.expand(root)
    expanded = Elixir.Path.expand(path, root)

    # Spec 13 §11 A-11: the prefix test used to run on the expanded string
    # alone, so a symlink inside the repo (`ln -s / esc`) let every path tool
    # read and write anywhere. The second test resolves the symlinks of the
    # deepest existing ancestor; the path handed back is still the plain one,
    # so nothing downstream has to know about `/tmp` vs `/private/tmp`.
    #
    # Sakana task 1: a link cycle (`ln -s a a`) used to recurse forever. Real
    # path resolution now fails explicitly and a failure is an escape.
    with true <- inside?(root, expanded),
         {:ok, real_root} <- real_path(root),
         {:ok, real} <- real_path(expanded),
         true <- inside?(real_root, real) do
      {:ok, expanded}
    else
      _ -> {:error, "path is outside the project root: " <> path}
    end
  end

  @doc """
  `path` with every symlink of its deepest existing ancestor resolved. A path
  that does not exist yet keeps the not-yet-created tail (the parent decides
  where a `write_file` lands).

  Returns `{:error, :symlink_cycle}` when the links loop instead of recursing
  until the scheduler gives up.
  """
  @spec real_path(String.t()) :: {:ok, String.t()} | {:error, :symlink_cycle}
  def real_path(path) do
    expanded = Elixir.Path.expand(path)
    do_real(expanded, [], MapSet.new())
  end

  @doc """
  True only when `path` is inside `root` both as a plain path and after every
  symlink is resolved. Any resolution failure (a cycle, an unreadable parent)
  is false — enumerators use this to skip a candidate.
  """
  @spec confined?(String.t(), String.t()) :: boolean()
  def confined?(root, path) do
    root = Elixir.Path.expand(root)

    case real_path(root) do
      {:ok, real_root} -> confined?(real_root, root, path)
      _error -> false
    end
  end

  @doc """
  `confined?/2` with the root's real path already resolved (spec 51 §7.1, E3).

  An enumerator resolves the root **once** and pays one `real_path/1` per
  candidate instead of two; `confined?/2` is that same call with the root
  resolved on the spot, for the callers that only ever look at one path.
  """
  @spec confined?(String.t(), String.t(), String.t()) :: boolean()
  def confined?(real_root, root, path),
    do: match?({:ok, _real}, real_confined(real_root, Elixir.Path.expand(root), path))

  # `{:ok, real}` when `path` is inside `root` as a plain path AND its real
  # path is inside `real_root`; `:error` for every failure. `root` is already
  # expanded.
  defp real_confined(real_root, root, path) do
    expanded = Elixir.Path.expand(path, root)

    with true <- inside?(root, expanded),
         {:ok, real} <- real_path(expanded),
         true <- inside?(real_root, real) do
      {:ok, real}
    else
      _ -> :error
    end
  end

  defp do_real("/", tail, _seen), do: {:ok, Elixir.Path.join(["/" | tail])}

  defp do_real(path, tail, seen) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        if MapSet.member?(seen, path) do
          {:error, :symlink_cycle}
        else
          target = List.to_string(target)

          target =
            if Elixir.Path.type(target) == :absolute,
              do: target,
              else: Elixir.Path.expand(target, Elixir.Path.dirname(path))

          # A link may point at another link; resolve from the top again.
          do_real(Elixir.Path.expand(target), tail, MapSet.put(seen, path))
        end

      {:error, _reason} ->
        # An existing entry that is not a link (`:einval`), or one that cannot
        # be read at all: its parent may still be a link.
        parent = Elixir.Path.dirname(path)
        base = Elixir.Path.basename(path)

        if parent == path,
          do: {:ok, join_tail(path, tail)},
          else: do_real(parent, [base | tail], seen)
    end
  end

  defp join_tail(path, []), do: path
  defp join_tail(path, tail), do: Elixir.Path.join([path | tail])

  @doc "True when `path` sits inside `root` (both already real paths)."
  @spec inside?(String.t(), String.t()) :: boolean()
  def inside?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  def relative(root, abs) do
    root = Elixir.Path.expand(root)

    if abs == root do
      "."
    else
      Elixir.Path.relative_to(abs, root)
    end
  end

  @doc """
  True for a name no file tool ever descends into or reports.

  Spec 51 §7.1 (E3): the list held `_build`, but this project builds into
  `_build.noindex` — 13 770 of the 20 017 entries one `grep` used to walk. Every
  `_build*` directory is ignored now, whatever the suffix.
  """
  @spec ignored_dir?(String.t()) :: boolean()
  def ignored_dir?(name), do: name in @ignored or String.starts_with?(name, "_build")

  @doc """
  The children of `dir` a file tool may see: ignored names dropped first, every
  survivor confined against `real_root` with **one** `real_path/1` call, sorted
  case-insensitively. Each entry is `{name, :directory | :regular, abs, real}`.

  `real_root` is `real_path(root)`, resolved once by the caller (spec 51 §7.1).
  With `dot?` false the dot entries are dropped too (`Path.wildcard/2`'s
  `match_dot: false`).
  """
  @spec entries(String.t(), String.t(), String.t(), boolean()) :: [
          {String.t(), :directory | :regular, String.t(), String.t()}
        ]
  def entries(real_root, root, dir, dot? \\ true) do
    case real_path(dir) do
      {:ok, real_dir} -> entries(real_root, Elixir.Path.expand(root), dir, real_dir, dot?)
      _error -> []
    end
  end

  defp entries(real_root, root, dir, real_dir, dot?) do
    if inside?(real_root, real_dir) do
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end
      |> Enum.reject(&ignored_dir?/1)
      |> Enum.reject(&(not dot? and String.starts_with?(&1, ".")))
      |> Enum.sort_by(&String.downcase/1)
      |> Enum.flat_map(&child(real_root, root, dir, real_dir, &1))
    else
      []
    end
  end

  # One `lstat` per entry, and that is the whole cost. The parent's real path is
  # already resolved, so an entry that is not itself a link needs no walk back
  # up to `/` — that walk was ~12 `read_link_all` calls *per entry* and most of
  # what E3 measured (spec 51 §7.1). Only a symlink pays the full resolution,
  # and only a symlink can point out of the project.
  defp child(real_root, root, dir, real_dir, name) do
    full = Elixir.Path.join(dir, name)

    case File.lstat(full, time: :posix) do
      {:ok, %{type: type}} when type in [:directory, :regular] ->
        keep_unless_checkout(name, type, full, Elixir.Path.join(real_dir, name))

      {:ok, %{type: :symlink}} ->
        with {:ok, real} <- real_confined(real_root, root, full),
             {:ok, %{type: type}} when type in [:directory, :regular] <-
               File.stat(full, time: :posix) do
          keep_unless_checkout(name, type, full, real)
        else
          _ -> []
        end

      _other ->
        []
    end
  end

  # A directory that is itself a git checkout — a worktree under
  # `.claude/worktrees/`, a submodule, a vendored clone — is another project,
  # not part of this one: it is never entered (spec 51 §7.1, Blockers → A 44).
  # One `exists?` per directory entry; files pay nothing.
  defp keep_unless_checkout(name, :directory, full, real) do
    if File.exists?(Elixir.Path.join(full, ".git")),
      do: [],
      else: [{name, :directory, full, real}]
  end

  defp keep_unless_checkout(name, type, full, real), do: [{name, type, full, real}]

  @doc """
  Every regular file under `start` (itself inside `root`), sorted, with the
  build and vendor directories pruned **before** they are entered.

  Spec 51 §7.1 (E3): `Path.wildcard("**/*")` listed 20 017 entries of this
  repository and `confined?/2` re-resolved the root's symlinks for every one of
  them — 7.7 s before a single byte was read. The walk is iterative and
  depth-first, `real_path(root)` is resolved once, and a directory is entered
  once per *real* path (so a link cycle is entered once and a link to `/etc`
  never, because confinement is checked before entry).

  Options:

    * `:glob` — a shell glob. Without a `/` it is matched against the base name
      (`"*.ex"`), with one against the path relative to `start`
      (`"lib/**/*.ex"`). `*` and `?` stop at `/`, `**` does not, `{a,b}` and
      `[...]` behave as in `Path.wildcard/2`; everything else is literal.
    * `:dirs` — also return the directories that match (default `false`).
    * `:dot` — descend into and return dot entries (default `true`).
  """
  @spec walk(String.t(), String.t(), keyword()) :: [String.t()]
  def walk(root, start, opts \\ []) do
    root = Elixir.Path.expand(root)
    start = Elixir.Path.expand(to_string(start || "."), root)
    glob = opts[:glob]
    matcher = if glob in [nil, ""], do: nil, else: compile_glob(to_string(glob))

    with {:ok, real_root} <- real_path(root),
         {:ok, real_start} <- real_confined(real_root, root, start),
         true <- File.dir?(start) do
      cfg = {real_root, root, start, matcher, opts[:dirs] == true, Keyword.get(opts, :dot, true)}

      [{start, real_start}]
      |> do_walk(MapSet.new([real_start]), cfg, [])
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp do_walk([], _seen, _cfg, acc), do: acc

  defp do_walk([{dir, real_dir} | rest], seen, cfg, acc) do
    {real_root, root, start, matcher, dirs?, dot?} = cfg

    {queue, seen, acc} =
      real_root
      |> entries(root, dir, real_dir, dot?)
      |> Enum.reduce({rest, seen, acc}, fn {name, type, full, real}, {queue, seen, acc} ->
        keep? = matches?(matcher, start, full, name)

        case type do
          :regular ->
            {queue, seen, if(keep?, do: [full | acc], else: acc)}

          :directory ->
            acc = if dirs? and keep?, do: [full | acc], else: acc

            if MapSet.member?(seen, real),
              do: {queue, seen, acc},
              else: {[{full, real} | queue], MapSet.put(seen, real), acc}
        end
      end)

    do_walk(queue, seen, cfg, acc)
  end

  defp matches?(nil, _start, _full, _name), do: true
  defp matches?({:base, re}, _start, _full, name), do: Regex.match?(re, name)
  defp matches?({:path, re}, start, full, _name), do: Regex.match?(re, relative(start, full))

  # A glob is a pattern, not a regex: a stray bracket must stay a bracket rather
  # than raise, so a source that will not compile falls back to the literal.
  defp compile_glob(glob) do
    re =
      case Regex.compile("^" <> glob_source(glob) <> "$") do
        {:ok, re} -> re
        {:error, _reason} -> Regex.compile!("^" <> Regex.escape(glob) <> "$")
      end

    if String.contains?(glob, "/"), do: {:path, re}, else: {:base, re}
  end

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
end
