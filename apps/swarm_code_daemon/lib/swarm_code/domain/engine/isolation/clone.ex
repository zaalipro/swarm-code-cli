defmodule SwarmCode.Domain.Engine.Isolation.Clone do
  # spec 72 D1
  @moduledoc """
  APFS copy-on-write clone backend.

  Uses `cp -c -R` to create a clone of the project directory. The `-c` flag
  requests APFS clonefile (copy-on-write); the kernel falls back to a regular
  copy on non-APFS volumes. This copies deps, _build.noindex, node_modules —
  the agent can run tests immediately.
  """

  @behaviour SwarmCode.Domain.Engine.Isolation.Backend

  alias SwarmCode.Domain.Engine.Isolation.Ownership
  alias SwarmCode.Domain.Git

  # spec 72 R1: the target lives under `<root>/.swarm_code/worktrees/`, so
  # `cp -R <root>/. <target>/` walked into the half-made clone and copied it
  # into itself until the path length ran out ("File name too long", exit 1)
  # — every isolated sub-agent failed to start under `auto` on APFS. Top-level
  # entries are copied one by one instead, and `.swarm_code` without the
  # subtrees that hold siblings' clones, delta patches and scratch files.
  @skip_swarm_code ~w(worktrees isolation tmp)

  # spec 74 ARCHITECTURE-19: `cp` had no deadline at all; a copy-on-write
  # clone of even a large tree takes seconds, a plain copy minutes.
  @copy_timeout_ms 600_000

  @impl true
  def create(project_root, target_path, opts) do
    # spec 73 T72 (F3): a clone always gets its branch — `start_isolation`
    # passes `work.branch`, and `finish_clone/2` no longer has a nil clause.
    branch = Keyword.fetch!(opts, :branch)

    # spec 73 T11: a linked worktree's `.git` is a file (`gitdir: …/worktrees/x`)
    # that the copy carried along verbatim, so `checkout -b` below moved the
    # user's own HEAD and the worker's `git add -A` rewrote the shared index.
    if main_checkout?(project_root) do
      do_create(project_root, target_path, branch)
    else
      {:error, "project's .git is a linked worktree; clone needs a main checkout"}
    end
  end

  @doc """
  True when `root` holds its own `.git` directory — a main checkout, which is
  the only kind of repository a clone may copy (spec 73 T11). A linked
  worktree carries a `.git` *file* and settles to the worktree backend.
  """
  @spec main_checkout?(String.t()) :: boolean()
  def main_checkout?(root), do: File.dir?(Path.join(root, ".git"))

  defp do_create(project_root, target_path, branch) do
    try do
      File.mkdir_p!(target_path)

      with :ok <-
             copy_entries(project_root, target_path, File.ls!(project_root) -- [".swarm_code"]),
           :ok <- copy_swarm_code(project_root, target_path) do
        # A lock the parent held at the instant of the copy is not ours to keep.
        File.rm(Path.join([target_path, ".git", "index.lock"]))
        finish_clone(target_path, branch)
      else
        {:error, reason} ->
          File.rm_rf(target_path)
          {:error, reason}
      end
    rescue
      error ->
        File.rm_rf(target_path)
        {:error, "clone failed: #{Exception.message(error)}"}
    end
  end

  defp copy_entries(_src_dir, _dst_dir, []), do: :ok

  defp copy_entries(src_dir, dst_dir, entries) do
    sources = Enum.map(entries, &Path.join(src_dir, &1))

    # spec 74 ARCHITECTURE-19: the shared bounded runner — a deadline, and
    # at most 64 KB of cp's messages kept (`:drain` reads past the bound
    # rather than killing a copy that only complains a lot).
    case SwarmCode.Domain.OSProcess.run("cp", ["-c", "-R", "--"] ++ sources ++ [dst_dir <> "/"],
           timeout: @copy_timeout_ms,
           max_bytes: 64 * 1024,
           on_cap: :drain
         ) do
      {:ok, 0, _out, _cut?} -> :ok
      {:ok, _code, out, _cut?} -> {:error, "clone failed: #{String.slice(out, 0, 500)}"}
      {:error, :timeout} -> {:error, "clone failed: cp timed out"}
      {:error, reason} -> {:error, "clone failed: #{inspect(reason)}"}
    end
  end

  defp copy_swarm_code(project_root, target_path) do
    src = Path.join(project_root, ".swarm_code")

    if File.dir?(src) do
      dst = Path.join(target_path, ".swarm_code")
      File.mkdir_p!(dst)
      copy_entries(src, dst, File.ls!(src) -- @skip_swarm_code)
    else
      :ok
    end
  end

  defp finish_clone(target_path, branch) when is_binary(branch) and branch != "" do
    with {:ok, _} <- Git.run(target_path, ["checkout", "-b", branch]),
         :ok <- drop_uncommitted(target_path) do
      base_sha = Git.head(target_path) || ""
      {:ok, %{root: target_path, branch: branch, base_sha: base_sha}}
    else
      {:error, reason} ->
        File.rm_rf(target_path)
        {:error, "could not create branch: #{reason}"}
    end
  end

  # spec 74 BUGS-59 (decision D1: reset to HEAD): the copy carries the user's
  # uncommitted work — modified and untracked files — and the agent's
  # `add -A` + commit put it on the agent's branch, so its diff stat, its delta
  # and its integration all carried the user's WIP. The clone starts at HEAD,
  # like a worktree does. `clean` never takes `-x`: ignored files (deps,
  # _build, node_modules — why a clone is used) stay, and so do `.swarm_code/`
  # and the ownership marker, named with `-e` so they survive even where
  # `Workspace.ensure!/1` has not put them in `.git/info/exclude` yet. A
  # repository with no commit yet has no HEAD to reset to; its copy stays as
  # it is.
  defp drop_uncommitted(target_path) do
    if Git.head(target_path) do
      keep = ["-e", "/.swarm_code/", "-e", "/" <> Ownership.marker_file()]

      with {:ok, _} <- Git.run(target_path, ["reset", "-q", "--hard", "HEAD"]),
           {:ok, _} <- Git.run(target_path, ["clean", "-q", "-f", "-d"] ++ keep) do
        :ok
      end
    else
      :ok
    end
  end

  # spec 73 T72 (F3): removal is `SwarmCode.Domain.Engine.Isolation.cleanup/3`'s —
  # the marker, the branch export and the prune go with it; a bare `rm_rf`
  # wrapper here was the third cleanup path.

  @doc """
  Fetches the clone's `branch` into `parent_root` under the same name, so the
  agent's commits survive the clone's removal and the project's merge path
  sees the branch exactly as it sees a worktree's. # spec 72 R2
  """
  @spec export_branch(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def export_branch(parent_root, clone_path, branch) when is_binary(branch) and branch != "" do
    case Git.run(parent_root, [
           "fetch",
           "--quiet",
           "--no-tags",
           "--",
           clone_path,
           branch <> ":" <> branch
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "True when `path` is a clone (its own `.git` directory) rather than a worktree (a `.git` file)."
  @spec clone_dir?(String.t()) :: boolean()
  def clone_dir?(path), do: File.dir?(Path.join(path, ".git"))

  @doc """
  Returns true if the filesystem at `path` supports APFS clones.

  spec 73 T70: the probe file is written on the project's own volume — under
  `<root>/.swarm_code/tmp` when the workspace exists, else in the root — and
  the answer is cached in `:persistent_term` per expanded root. It used to
  probe the system tmp dir and cache one answer for every project, so a
  project on an exFAT, NTFS or SMB volume passed and every sub-agent start
  byte-copied `deps/`, `_build/` and `node_modules/`.
  """
  @spec supported?(String.t()) :: boolean()
  def supported?(path) do
    root = Path.expand(path)
    key = {__MODULE__, :clone_supported, root}

    case :persistent_term.get(key, :unprobed) do
      :unprobed ->
        result = probe_clone(root)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  @doc false
  def forget_probe(path),
    do: :persistent_term.erase({__MODULE__, :clone_supported, Path.expand(path)})

  defp probe_clone(root) do
    dir = probe_dir(root)
    src = Path.join(dir, ".swarm_code_clone_probe_#{System.unique_integer([:positive])}")
    dst = src <> "_dst"

    try do
      File.write!(src, "probe")

      case SwarmCode.Domain.OSProcess.run("cp", ["-c", src, dst],
             timeout: 10_000,
             max_bytes: 4_096
           ) do
        {:ok, 0, _out, _cut?} -> true
        _ -> false
      end
    rescue
      _ -> false
    after
      File.rm(src)
      File.rm(dst)
    end
  end

  defp probe_dir(root) do
    workspace = SwarmCode.Domain.Projects.Workspace.dir(root)

    if File.dir?(workspace) do
      tmp = Path.join(workspace, "tmp")
      File.mkdir_p!(tmp)
      tmp
    else
      root
    end
  end
end
