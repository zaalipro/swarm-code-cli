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

  # spec 74 BUGS-8: every git call runs with these overrides, so neither the
  # user's nor the repository's own config decides what SwarmCode's git does:
  # a repo-local `core.fsmonitor` ran on every conversation open (status,
  # numstat), and `diff.noprefix`/`diff.mnemonicPrefix`/`diff.relative`
  # produced patches `git apply` refuses. `core.quotePath=false` keeps
  # non-ASCII paths readable (BUGS-72 moves the parsers to `-z`).
  @hardening [
    "-c",
    "core.fsmonitor=false",
    "-c",
    "color.ui=false",
    "-c",
    "diff.noprefix=false",
    "-c",
    "diff.mnemonicPrefix=false",
    "-c",
    "diff.relative=false",
    "-c",
    "core.quotePath=false"
  ]

  # spec 74 BUGS-8: `diff.external` and textconv drivers cannot be switched off
  # by `-c`, only by these options — which every subcommand that prints a diff
  # takes. Inserted after the subcommand, so no caller can forget them
  # (`Isolation.Delta`'s committed diff included).
  @diff_commands ~w(diff log show)
  @diff_hardening ["--no-ext-diff", "--no-textconv"]

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

  spec 74 BUGS-8: every call carries the `@hardening` config overrides, a
  diff-printing subcommand gets `--no-ext-diff --no-textconv`, and
  `hooks: false` adds `core.hooksPath=/dev/null`.
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

    # spec 74 BUGS-13: `raw: true` (patches) returns the bytes as git wrote
    # them — no UTF-8 repair, and only the byte bound, never a character cut.
    caps = if opts[:raw] == true, do: {elem(caps, 0), :bytes}, else: caps

    if not is_binary(root) or not File.dir?(root) do
      {:error, "not a directory: #{inspect(root)}"}
    else
      config = if opts[:hooks] == false, do: ["-c", "core.hooksPath=/dev/null"], else: []
      do_run(root, config ++ harden(args), timeout, opts[:executable] || "git", caps)
    end
  end

  defp harden([sub | rest]) when sub in @diff_commands,
    do: @hardening ++ [sub | @diff_hardening] ++ rest

  defp harden(args), do: @hardening ++ args

  @truncation_trailer "\n…[truncated]"

  @doc "True when `out` was cut by the output cap of `run/3`."
  @spec truncated?(term()) :: boolean()
  def truncated?(out) when is_binary(out), do: String.ends_with?(out, @truncation_trailer)
  def truncated?(_out), do: false

  # Sakana task 17: this used to run `System.cmd/3` inside a Task and kill only
  # the Task on timeout — the git process (and whatever it had spawned) kept
  # running, sometimes holding the index lock. A Port gives us the OS pid, so the
  # whole tree is reaped. The env, cwd, exit/output contract and cap are the same.
  # spec 74 ARCHITECTURE-19: a thin wrapper over the shared bounded runner,
  # `OSProcess.run/3`; `on_cap: :drain` keeps git's contract (the bytes past
  # the bound are dropped while it runs to its exit code).
  defp do_run(root, args, timeout, git, {max_bytes, max_chars}) do
    executable = System.find_executable(git)

    if is_nil(executable) do
      {:error, "git failed: command not found: #{git}"}
    else
      case SwarmCode.Domain.OSProcess.run(executable, args,
             cd: root,
             env: RunCommand.clean_env(),
             timeout: timeout,
             max_bytes: max_bytes,
             on_cap: :drain
           ) do
        {:ok, 0, out, cut?} -> {:ok, finish(out, max_chars, cut?)}
        {:ok, _code, out, cut?} -> {:error, finish(out, max_chars, cut?)}
        {:error, :timeout} -> {:error, "git timed out after #{timeout} ms"}
        {:error, reason} -> {:error, "git failed: #{inspect(reason)}"}
      end
    end
  rescue
    e -> {:error, "git failed: " <> Exception.message(e)}
  end

  # spec 74 BUGS-13: the output used to lose up to 3 trailing bytes whenever
  # it was not valid UTF-8 *anywhere* — a Latin-1 line in the middle of a diff
  # cost the patch its last bytes, and `git apply` called it corrupt. Only a
  # cut can split a character, so only a cut output is repaired, and only its
  # incomplete trailing sequence is dropped. A raw read is never touched.
  defp finish(out, :bytes, cut?), do: if(cut?, do: out <> @truncation_trailer, else: out)
  defp finish(out, max_chars, true), do: out |> drop_partial_tail() |> cap(max_chars, true)
  defp finish(out, max_chars, false), do: cap(out, max_chars, false)

  # The last 1–3 bytes when they are the start of a UTF-8 sequence whose
  # continuation bytes were cut off.
  defp drop_partial_tail(out) do
    size = byte_size(out)

    Enum.find_value(1..min(3, size)//1, out, fn back ->
      <<byte>> = binary_part(out, size - back, 1)

      cond do
        # A continuation byte: keep looking for the lead.
        Bitwise.band(byte, 0xC0) == 0x80 -> nil
        # A lead byte that needs more continuations than it got.
        lead_length(byte) > back -> binary_part(out, 0, size - back)
        true -> out
      end
    end)
  end

  defp lead_length(byte) when Bitwise.band(byte, 0xE0) == 0xC0, do: 2
  defp lead_length(byte) when Bitwise.band(byte, 0xF0) == 0xE0, do: 3
  defp lead_length(byte) when Bitwise.band(byte, 0xF8) == 0xF0, do: 4
  defp lead_length(_byte), do: 1

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

  spec 74 BUGS-72: only the project's files, with paths relative to `root` —
  a project rooted in a repository's subdirectory listed the whole repository
  with repo-root paths (`sub/lib/a.txt`), which then named nothing when joined
  to the root. NUL-separated (`-z`), so a name with a quote, a newline or
  non-ASCII (`café.md` came back as `"caf\\303\\251.md"`) is the real name;
  a rename or copy is its new path (the source is the record after it).
  """
  @spec status(String.t()) :: [map()]
  def status(root) do
    case run(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."]) do
      {:ok, out} -> out |> records() |> parse_status(prefix(root), [])
      _ -> []
    end
  end

  # NUL-terminated records; a record the output cap cut is dropped whole.
  defp records(out) do
    fields = String.split(out, <<0>>)
    fields = if truncated?(out), do: Enum.drop(fields, -1), else: fields
    Enum.reject(fields, &(&1 == ""))
  end

  defp parse_status(
         [<<x::binary-size(1), y::binary-size(1), " ", path::binary>> | rest],
         prefix,
         acc
       ) do
    # spec 60 T25: only a rename or copy carries a source, the next record.
    rest = if x in ["R", "C"] or y in ["R", "C"], do: Enum.drop(rest, 1), else: rest

    entry = %{
      # spec 74 BUGS-13: a display field — a non-UTF-8 name is shown, not raised on.
      path: path |> relative(prefix) |> String.replace_invalid(),
      x: x,
      y: y,
      staged?: x not in [" ", "?"],
      untracked?: x == "?" and y == "?"
    }

    parse_status(rest, prefix, [entry | acc])
  end

  defp parse_status([_other | rest], prefix, acc), do: parse_status(rest, prefix, acc)
  defp parse_status([], _prefix, acc), do: Enum.reverse(acc)

  defp relative(path, ""), do: path
  defp relative(path, prefix), do: String.replace_prefix(path, prefix, "")

  # spec 74 BUGS-72: where `root` sits in its repository — `"sub/"`, or `""`
  # at the top — from `rev-parse --show-prefix`, cached per root under the
  # `:project` tag (dropped with every project change). Only an answer is
  # cached: a folder that becomes a repository later is asked again.
  defp prefix(root) do
    key = {:project, {:git_prefix, Path.expand(root)}}

    case SwarmCode.Domain.Cache.get(key) do
      prefix when is_binary(prefix) ->
        prefix

      nil ->
        case run(root, ["rev-parse", "--show-prefix"]) do
          {:ok, out} ->
            prefix = String.trim_trailing(out, "\n")
            SwarmCode.Domain.Cache.put(key, prefix)
            prefix

          {:error, _not_a_repo} ->
            ""
        end
    end
  end

  @doc """
  A unified diff. Options: `:paths` (list), `:staged` (boolean), `:base` (a rev to
  diff against). Untracked files are included via `--no-index` fallbacks are not
  attempted; use `:paths` for those.

  spec 74 BUGS-72: `--relative` — only the project's files, with paths relative
  to `root` in the headers, as `:paths` (cwd-relative pathspecs) name them.
  """
  @spec diff(String.t(), keyword()) :: String.t()
  def diff(root, opts \\ []) do
    args =
      ["diff", "--no-color", "--relative"] ++
        if(opts[:staged], do: ["--cached"], else: []) ++
        if(opts[:base], do: [opts[:base]], else: []) ++
        case opts[:paths] do
          nil -> []
          [] -> []
          paths -> ["--"] ++ List.wrap(paths)
        end

    # spec 74 BUGS-13: the Changes view renders this text — a Latin-1 line
    # becomes U+FFFD here instead of crashing the template.
    case run(root, args) do
      {:ok, out} -> String.replace_invalid(out)
      {:error, out} -> String.replace_invalid(out)
    end
  end

  @doc """
  `{summary, files}` where summary looks like `"3 files changed, +40 −2"` and
  files is `[%{path, added, removed}]`. `opts` accepts `:base`.

  spec 74 BUGS-72: `--relative -z` — the project's files only, relative to
  `root`, by their real names; a rename is its new path.
  """
  @spec diff_stat(String.t(), keyword()) :: {String.t(), [map()]}
  def diff_stat(root, opts \\ []) do
    args =
      ["diff", "--numstat", "-z", "--relative"] ++
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

    files = out |> records() |> parse_numstat([])

    added = files |> Enum.map(& &1.added) |> Enum.sum()
    removed = files |> Enum.map(& &1.removed) |> Enum.sum()
    n = length(files)

    summary =
      if n == 0,
        do: "",
        else: "#{n} file#{if n == 1, do: "", else: "s"} changed, +#{added} −#{removed}"

    {summary, files}
  end

  # `added\tremoved\tpath`, or for a rename `added\tremoved\t` followed by
  # the old and the new path as records of their own.
  defp parse_numstat([record | rest], acc) do
    case String.split(record, "\t", parts: 3) do
      [a, r, ""] ->
        case rest do
          [_old, new | rest] -> parse_numstat(rest, [numstat(a, r, new) | acc])
          _cut -> Enum.reverse(acc)
        end

      [a, r, path] ->
        parse_numstat(rest, [numstat(a, r, path) | acc])

      _other ->
        parse_numstat(rest, acc)
    end
  end

  defp parse_numstat([], acc), do: Enum.reverse(acc)

  defp numstat(a, r, path),
    do: %{path: String.replace_invalid(path), added: int(a), removed: int(r)}

  defp int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc "Commits `paths` (or everything when `:all`) with `message`."
  @spec commit(String.t(), String.t(), [String.t()] | :all, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  #
  # spec 74 BUGS-8: in a project the user has not trusted, git's own hooks do
  # not run either — a repo-configured `core.hooksPath` (husky's `.husky/`)
  # is committed code. `trusted?:` answers the question; without it the
  # project is looked up by root (`Hooks.trusted_root?/1`, cached).
  def commit(root, message, paths \\ :all, opts \\ [])

  # spec 74 BUGS-72: `-- .` — in a project rooted in a repository's
  # subdirectory, `add -A` staged and committed the whole repository.
  def commit(root, message, :all, opts) do
    with {:ok, _} <- run(root, ["add", "-A", "--", "."]) do
      run(root, ["commit", "-m", message, "--", "."], hooks_opts(root, opts))
    end
  end

  # The UI's "commit what is staged".
  def commit(root, message, [], opts),
    do: run(root, ["commit", "-m", message], hooks_opts(root, opts))

  # spec 60 T24: `--only` commits exactly these paths and leaves whatever else
  # is staged in the index; a path that could read as an option is refused.
  #
  # spec 74 BUGS-72: nor one outside the project — `../other/x` was a valid
  # pathspec into the rest of the repository.
  def commit(root, message, list, opts) when is_list(list) do
    if Enum.any?(
         list,
         &(not is_binary(&1) or &1 == "" or String.starts_with?(&1, "-") or
             String.starts_with?(&1, ":") or outside?(root, &1))
       ) do
      {:error, "invalid path"}
    else
      with {:ok, _} <- run(root, ["add", "--"] ++ list) do
        run(root, ["commit", "--only", "-m", message, "--"] ++ list, hooks_opts(root, opts))
      end
    end
  end

  defp outside?(root, path) do
    root = Path.expand(root)
    full = Path.expand(path, root)
    full != root and not String.starts_with?(full, root <> "/")
  end

  defp hooks_opts(root, opts) do
    trusted? =
      case Keyword.fetch(opts, :trusted?) do
        {:ok, value} -> value == true
        :error -> trusted_root?(root)
      end

    if trusted?, do: [], else: [hooks: false]
  end

  # No project row (or no database, e.g. a test without a sandbox) is "not
  # trusted": the hooks are skipped, which is the safe side.
  defp trusted_root?(root) do
    SwarmCode.Domain.Hooks.trusted_root?(root)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  @spec log(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def log(root, n \\ 20) do
    with {:ok, out} <- run(root, ["log", "--oneline", "--decorate", "-n", to_string(n)]),
         do: {:ok, String.replace_invalid(out)}
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
  @spec merge(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t() | {:conflicts, [String.t()]}}
  def merge(root, branch, opts \\ []) do
    with {:ok, branch} <- validate_revision(branch) do
      do_merge(root, branch, hooks_opts(root, opts))
    end
  end

  defp do_merge(root, branch, run_opts) do
    case run(root, ["merge", "--no-ff", "--no-edit", "--", branch], run_opts) do
      {:ok, out} ->
        {:ok, out}

      {:error, out} ->
        conflicts = conflicted(root)
        run(root, ["merge", "--abort"], run_opts)

        if conflicts == [], do: {:error, out}, else: {:error, {:conflicts, conflicts}}
    end
  end

  # spec 74 BUGS-72: real names (`-z`), not quoted ones.
  defp conflicted(root) do
    case run(root, ["diff", "--name-only", "-z", "--diff-filter=U"]) do
      {:ok, out} -> out |> records() |> Enum.map(&String.replace_invalid/1)
      _ -> []
    end
  end

  # spec 72 D2: staged diff (cached changes).
  @spec diff_staged(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def diff_staged(root, opts \\ []) do
    args = ["diff", "--cached", "--binary"]
    run(root, args, Keyword.put(opts, :raw, true))
  end

  # spec 72 D2: unstaged diff (working-tree changes not in the index).
  @spec diff_unstaged(String.t(), keyword()) :: {:ok, binary()} | {:error, String.t()}
  def diff_unstaged(root, opts \\ []) do
    args = ["diff", "--binary"]
    run(root, args, Keyword.put(opts, :raw, true))
  end

  # spec 72 D3: list untracked files (not ignored).
  @spec ls_untracked(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  #
  # spec 74 BUGS-72: `-z`, so a name with a quote or a newline is the real name.
  def ls_untracked(root) do
    case run(root, ["ls-files", "-z", "--others", "--exclude-standard"]) do
      {:ok, out} -> {:ok, records(out)}
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
