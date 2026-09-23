defmodule SwarmCode.Domain.Git do
  @moduledoc """
  Thin, safe wrapper around the `git` CLI.

  Every call runs with the release environment scrubbed (`RunCommand.clean_env/0`),
  a 60 s timeout and output capped at 200 000 characters. Nothing here raises.
  """

  require Logger

  alias SwarmCode.Domain.Tools.RunCommand

  @timeout 60_000
  @cap 200_000
  @collect_bytes 1_000_000

  @spec validate_revision(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_revision(revision) when is_binary(revision) do
    if revision != "" and not String.starts_with?(revision, "-") and
         Regex.match?(~r/^[A-Za-z0-9._\/^~@{}-]+$/, revision) do
      {:ok, revision}
    else
      {:error, "invalid git revision: " <> revision}
    end
  end

  @doc "True when `root` is inside a git work tree."
  @spec repo?(String.t() | nil) :: boolean()
  def repo?(nil), do: false

  def repo?(root) do
    case run(root, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, out} -> String.trim(out) == "true"
      _ -> false
    end
  end

  @doc """
  Runs `git args` in `root`. Returns `{:ok, output}` on exit code 0.

  `:timeout` (default 60 s) and `:executable` (default `"git"`, used by tests
  that need a shim) are the only options.
  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(root, args, opts \\ []) do
    timeout = opts[:timeout] || @timeout

    # spec 72 R4: a caller that reads a whole patch (`Isolation.Delta`,
    # `Isolation.Baseline`) raises the bound; the default stays the 200 000
    # character cap every other caller has always had.
    caps =
      case opts[:max_bytes] do
        n when is_integer(n) and n > 0 -> {n, n}
        _default -> {@collect_bytes, @cap}
      end

    if not is_binary(root) or not File.dir?(root) do
      {:error, "not a directory: #{inspect(root)}"}
    else
      do_run(root, args, timeout, opts[:executable] || "git", caps)
    end
  end

  @truncation_trailer "\n…[truncated]"

  @doc "True when `out` was cut by the output cap of `run/3`."
  @spec truncated?(term()) :: boolean()
  def truncated?(out) when is_binary(out), do: String.ends_with?(out, @truncation_trailer)
  def truncated?(_out), do: false

  # Sakana task 17: this used to run `System.cmd/3` inside a Task and kill only
  # the Task on timeout — the git process (and whatever it had spawned) kept
  # running, sometimes holding the index lock. A Port gives us the OS pid, so the
  # whole tree is reaped. The env, cwd, exit/output contract and cap are the same.
  defp do_run(root, args, timeout, git, {max_bytes, max_chars}) do
    executable = System.find_executable(git)

    if is_nil(executable) do
      {:error, "git failed: command not found: #{git}"}
    else
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          cd: String.to_charlist(root),
          env: RunCommand.clean_env()
        ])

      deadline = System.monotonic_time(:millisecond) + timeout

      case collect(port, [], 0, deadline, max_bytes, false) do
        {:ok, 0, out, cut?} -> {:ok, cap(out, max_chars, cut?)}
        {:ok, _code, out, cut?} -> {:error, cap(out, max_chars, cut?)}
        :timeout -> {:error, "git timed out after #{timeout} ms"}
      end
    end
  rescue
    e -> {:error, "git failed: " <> Exception.message(e)}
  end

  # spec 73 T74: `cut?` records that bytes past `max_bytes` were dropped, so
  # a caller that raised the bound (`max_bytes:`) still gets the trailer — the
  # character cap alone could never bite once `byte_size(out) <= max_chars`,
  # and a 12 MB diff came back as a silently cut 10 MB "patch".
  defp collect(port, acc, bytes, deadline, max_bytes, cut?) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        keep = min(byte_size(data), max(max_bytes - bytes, 0))
        acc = if keep > 0, do: [binary_part(data, 0, keep) | acc], else: acc
        collect(port, acc, bytes + keep, deadline, max_bytes, cut? or keep < byte_size(data))

      {^port, {:exit_status, status}} ->
        out = acc |> Enum.reverse() |> IO.iodata_to_binary() |> valid_utf8_head(3)
        {:ok, status, out, cut?}
    after
      remaining ->
        port |> SwarmCode.Domain.OSProcess.port_pid() |> SwarmCode.Domain.OSProcess.kill_tree()

        try do
          Port.close(port)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        :timeout
    end
  end

  defp valid_utf8_head(binary, attempts) when attempts > 0 do
    if String.valid?(binary) do
      binary
    else
      valid_utf8_head(binary_part(binary, 0, byte_size(binary) - 1), attempts - 1)
    end
  end

  defp valid_utf8_head(binary, _attempts), do: binary

  # spec 73 T74: `byte_size(out) <= max_chars` is the fast path — a text of
  # that many bytes has at most that many characters, so the grapheme walk
  # over every git output (up to 1 MB per call) only runs when it can matter.
  defp cap(out, max_chars, cut?) do
    out = to_string(out)

    cond do
      byte_size(out) <= max_chars -> if cut?, do: out <> @truncation_trailer, else: out
      String.length(out) > max_chars -> String.slice(out, 0, max_chars) <> @truncation_trailer
      cut? -> out <> @truncation_trailer
      true -> out
    end
  end

  @doc """
  What git ignores under `root`, relative to it, whole directories collapsed
  (spec 67 T27 / G36).

  `ls-files --others --ignored --exclude-standard --directory` rather than the
  spec's `check-ignore --stdin`: an Erlang port cannot half-close a child's
  stdin, so `--stdin` would need a shell wrapper, and this is **one** call for a
  whole walk instead of one per directory — `deps/` and `_build.noindex/` come
  back as two entries the walk can prune before it enters them (18 ms and 87
  bytes in this repository). A path that is *tracked* is never reported, which
  is what a file tool wants: a checked-in file is part of the project whatever
  `.gitignore` says about its name.

  `[]` for a directory that is not a git work tree at all — `ls-files` exits
  non-zero there, and "nothing is ignored" is the same answer.
  """
  @spec ignored_paths(String.t()) :: [String.t()]
  def ignored_paths(root) do
    args = [
      "ls-files",
      "-z",
      "--others",
      "--ignored",
      "--exclude-standard",
      "--directory",
      "--no-empty-directory"
    ]

    case run(root, args, timeout: 10_000) do
      {:ok, out} ->
        out
        |> String.split(<<0>>, trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing("/")))
        # A listing long enough to hit `cap/1` ends with the marker after the
        # last NUL; a partial ignore set is still better than none.
        |> Enum.reject(&(&1 == "" or String.contains?(&1, "…[truncated]")))

      {:error, _reason} ->
        []
    end
  end

  @spec head(String.t()) :: String.t() | nil
  def head(root) do
    case run(root, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> String.trim(sha)
      _ -> nil
    end
  end

  @spec current_branch(String.t()) :: String.t() | nil
  def current_branch(root) do
    case run(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, name} -> String.trim(name)
      _ -> nil
    end
  end

  @doc "The repository's default branch (origin/HEAD, else main/master, else nil)."
  @spec default_branch(String.t()) :: String.t() | nil
  def default_branch(root) do
    case run(root, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) do
      {:ok, ref} ->
        ref |> String.trim() |> String.replace_prefix("origin/", "")

      _ ->
        Enum.find(["main", "master"], fn b ->
          match?({:ok, _}, run(root, ["rev-parse", "--verify", "--quiet", b]))
        end)
    end
  end

  @doc """
  Porcelain v1 status as structs:
  `%{path, x, y, staged?, untracked?}` (x = index status, y = work tree status).
  """
  @spec status(String.t()) :: [map()]
  def status(root) do
    case run(root, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, out} ->
        out
        |> String.split("\n")
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.map(&parse_status_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_status_line(line) do
    case line do
      <<x::binary-size(1), y::binary-size(1), " ", rest::binary>> ->
        path = rest |> String.trim() |> unquote_path()
        # spec 60 T25: only a rename or copy carries "old -> new".
        path = if x in ["R", "C"] or y in ["R", "C"], do: rename_target(path), else: path

        %{
          path: path,
          x: x,
          y: y,
          staged?: x not in [" ", "?"],
          untracked?: x == "?" and y == "?"
        }

      _ ->
        nil
    end
  end

  # "old -> new" for renames: the new path is what the UI cares about.
  defp rename_target(path) do
    case String.split(path, " -> ", parts: 2) do
      [_old, new] -> unquote_path(new)
      _ -> path
    end
  end

  defp unquote_path(<<"\"", _::binary>> = quoted) do
    case Jason.decode(quoted) do
      {:ok, path} when is_binary(path) -> path
      _ -> quoted
    end
  end

  defp unquote_path(path), do: path

  @doc """
  A unified diff. Options: `:paths` (list), `:staged` (boolean), `:base` (a rev to
  diff against). Untracked files are included via `--no-index` fallbacks are not
  attempted; use `:paths` for those.
  """
  @spec diff(String.t(), keyword()) :: String.t()
  def diff(root, opts \\ []) do
    args =
      ["diff", "--no-color"] ++
        if(opts[:staged], do: ["--cached"], else: []) ++
        if(opts[:base], do: [opts[:base]], else: []) ++
        case opts[:paths] do
          nil -> []
          [] -> []
          paths -> ["--"] ++ List.wrap(paths)
        end

    case run(root, args) do
      {:ok, out} -> out
      {:error, out} -> out
    end
  end

  @doc """
  `{summary, files}` where summary looks like `"3 files changed, +40 −2"` and
  files is `[%{path, added, removed}]`. `opts` accepts `:base`.
  """
  @spec diff_stat(String.t(), keyword()) :: {String.t(), [map()]}
  def diff_stat(root, opts \\ []) do
    args =
      ["diff", "--numstat"] ++
        if(opts[:staged], do: ["--cached"], else: []) ++
        if(opts[:base], do: [opts[:base]], else: []) ++
        case opts[:paths] do
          nil -> []
          [] -> []
          paths -> ["--"] ++ List.wrap(paths)
        end

    out =
      case run(root, args) do
        {:ok, out} -> out
        {:error, _} -> ""
      end

    files =
      out
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(fn line ->
        case String.split(line, "\t") do
          [a, r, path] -> %{path: path, added: int(a), removed: int(r)}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    added = files |> Enum.map(& &1.added) |> Enum.sum()
    removed = files |> Enum.map(& &1.removed) |> Enum.sum()
    n = length(files)

    summary =
      if n == 0,
        do: "",
        else: "#{n} file#{if n == 1, do: "", else: "s"} changed, +#{added} −#{removed}"

    {summary, files}
  end

  defp int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc "Commits `paths` (or everything when `:all`) with `message`."
  @spec commit(String.t(), String.t(), [String.t()] | :all) ::
          {:ok, String.t()} | {:error, String.t()}
  def commit(root, message, paths \\ :all)

  def commit(root, message, :all) do
    with {:ok, _} <- run(root, ["add", "-A"]) do
      run(root, ["commit", "-m", message])
    end
  end

  # The UI's "commit what is staged".
  def commit(root, message, []), do: run(root, ["commit", "-m", message])

  # spec 60 T24: `--only` commits exactly these paths and leaves whatever else
  # is staged in the index; a path that could read as an option is refused.
  def commit(root, message, list) when is_list(list) do
    if Enum.any?(
         list,
         &(&1 == "" or String.starts_with?(&1, "-") or String.starts_with?(&1, ":"))
       ) do
      {:error, "invalid path"}
    else
      with {:ok, _} <- run(root, ["add", "--"] ++ list) do
        run(root, ["commit", "--only", "-m", message, "--"] ++ list)
      end
    end
  end

  @spec log(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def log(root, n \\ 20) do
    run(root, ["log", "--oneline", "--decorate", "-n", to_string(n)])
  end

  @spec worktree_add(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def worktree_add(root, path, branch) do
    File.mkdir_p(Path.dirname(path))
    run(root, ["worktree", "add", "-b", branch, path, "HEAD"])
  end

  @spec worktree_remove(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def worktree_remove(root, path), do: run(root, ["worktree", "remove", "--force", path])

  @spec worktree_prune(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def worktree_prune(root), do: run(root, ["worktree", "prune"])

  @doc """
  Spec 51 §5.3: how many commits `branch` carries over `base` — `{:ok, 0}` is a
  branch nothing ever landed on. `{:error, _}` reads as "unknown, keep".
  """
  @spec commits_ahead(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def commits_ahead(root, base, branch) do
    with {:ok, base} <- validate_revision(base),
         {:ok, branch} <- validate_revision(branch),
         {:ok, out} <- run(root, ["rev-list", "--count", "#{base}..#{branch}"]) do
      case Integer.parse(String.trim(out)) do
        {n, ""} when n >= 0 -> {:ok, n}
        _other -> {:error, "unexpected rev-list output: " <> String.slice(out, 0, 80)}
      end
    end
  end

  @spec branch_delete(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def branch_delete(root, branch) do
    with {:ok, branch} <- validate_revision(branch) do
      run(root, ["branch", "-D", "--", branch])
    end
  end

  @doc """
  Merges `branch` into the current branch of `root` (`--no-ff --no-edit`). On a
  conflict the merge is aborted and `{:error, {:conflicts, paths}}` is returned.
  """
  @spec merge(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t() | {:conflicts, [String.t()]}}
  def merge(root, branch) do
    with {:ok, branch} <- validate_revision(branch) do
      do_merge(root, branch)
    end
  end

  defp do_merge(root, branch) do
    case run(root, ["merge", "--no-ff", "--no-edit", "--", branch]) do
      {:ok, out} ->
        {:ok, out}

      {:error, out} ->
        conflicts = conflicted(root)
        run(root, ["merge", "--abort"])

        if conflicts == [], do: {:error, out}, else: {:error, {:conflicts, conflicts}}
    end
  end

  defp conflicted(root) do
    case run(root, ["diff", "--name-only", "--diff-filter=U"]) do
      {:ok, out} -> out |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))
      _ -> []
    end
  end

  # spec 72 D2: staged diff (cached changes).
  @spec diff_staged(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def diff_staged(root, opts \\ []) do
    args = ["diff", "--cached", "--binary"]
    run(root, args, opts)
  end

  # spec 72 D2: unstaged diff (working-tree changes not in the index).
  @spec diff_unstaged(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def diff_unstaged(root, opts \\ []) do
    args = ["diff", "--binary"]
    run(root, args, opts)
  end

  # spec 72 D3: list untracked files (not ignored).
  @spec ls_untracked(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def ls_untracked(root) do
    case run(root, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, out} -> {:ok, String.split(out, "\n", trim: true)}
      error -> error
    end
  end

  # spec 72 D4: apply a unified diff patch, optionally with --3way.
  @spec apply_patch(String.t(), binary(), keyword()) ::
          :ok | {:error, :conflicts | :already_applied | String.t()}
  def apply_patch(root, patch, opts \\ []) do
    three_way? = Keyword.get(opts, :three_way, true)
    tmp_dir = Path.join(root, ".swarm_code/tmp")
    File.mkdir_p!(tmp_dir)
    tmp_path = Path.join(tmp_dir, "delta_#{System.unique_integer([:positive])}.patch")

    try do
      File.write!(tmp_path, patch)

      # Idempotency check: if the reverse patch applies cleanly, it's already in.
      case run(root, ["apply", "--reverse", "--check", "--", tmp_path]) do
        {:ok, _} ->
          {:error, :already_applied}

        {:error, _} ->
          # spec 72 R3: `--3way` is not atomic — on a hunk it cannot merge it
          # writes conflict markers into the working tree and leaves the paths
          # unmerged in the index (exit 1), and `--3way --check` says
          # "Applied … with conflicts" with exit 0. A plain dry run first, so a
          # patch that does not apply never touches the caller's tree.
          args = ["apply"] ++ if(three_way?, do: ["--3way"], else: []) ++ ["--", tmp_path]

          with {:ok, _} <- run(root, ["apply", "--check", "--", tmp_path]),
               {:ok, _} <- run(root, args, timeout: 60_000) do
            :ok
          else
            {:error, msg} ->
              if String.contains?(msg, "conflict") or String.contains?(msg, "does not apply") or
                   String.contains?(msg, "patch failed"),
                 do: {:error, :conflicts},
                 else: {:error, msg}
          end
      end
    after
      File.rm(tmp_path)
    end
  end

  @doc """
  Adds `line` to the repository's `info/exclude` when it is not there yet.

  spec 73 T13: the file is resolved through `git rev-parse --git-path`, which
  answers the common dir's `info/exclude` for a linked worktree — the old
  `<root>/.git/info/exclude` guess wrote nothing when `.git` was a file, so a
  project rooted in a worktree never excluded `.swarm_code/` or the ownership
  marker (spec 72 R5) and every worker committed the marker.
  """
  @spec exclude!(String.t(), String.t()) :: :ok
  def exclude!(root, line) do
    case run(root, ["rev-parse", "--git-path", "info/exclude"]) do
      {:ok, out} -> add_exclude_line(Path.expand(String.trim(out), root), line)
      {:error, _not_a_repo} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp add_exclude_line(file, line) do
    File.mkdir_p(Path.dirname(file))

    current =
      case File.read(file) do
        {:ok, text} -> text
        _ -> ""
      end

    unless line in String.split(current, "\n") do
      prefix = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"
      File.write(file, current <> prefix <> line <> "\n")
    end

    :ok
  end
end
