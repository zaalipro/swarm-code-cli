defmodule SwarmCode.Domain.Engine.Isolation do
  @moduledoc """
  The on-disk contract between the RunServer (which writes an isolated
  agent's delta patch) and `integrate_agent` (which reads it) — one place for
  the short id and the `.swarm_code/isolation/<short>` layout that four
  call sites used to spell out by hand. # spec 73 T60
  """

  @doc "The eight-character, dash-free prefix of a run or node id."
  @spec short_id(String.t()) :: String.t()
  def short_id(id), do: id |> to_string() |> String.replace("-", "") |> String.slice(0, 8)

  @doc """
  spec 74 ARCHITECTURE-6: removes the `.swarm_code/isolation/<short>` delta
  dirs (up to 10 MB each) that nothing will read any more — no node row has
  that short id, or every node that has it is finished and integrated. A dir
  whose node is still running, or finished and not integrated (the user may
  still integrate it), stays. The boot sweep runs it; it answers the count.
  """
  @spec sweep_deltas(String.t()) :: non_neg_integer()
  def sweep_deltas(project_root) do
    root = Path.join([project_root, ".swarm_code", "isolation"])

    case File.ls(root) do
      {:ok, entries} ->
        Enum.count(entries, fn short ->
          dir = Path.join(root, short)

          if Regex.match?(~r/\A[0-9a-f]{8}\z/, short) and File.dir?(dir) and spent_delta?(short) do
            File.rm_rf(dir)
            true
          else
            false
          end
        end)

      {:error, _} ->
        0
    end
  end

  # `short_id/1` is the node id's first group (8 hex characters, no dash).
  defp spent_delta?(short) do
    import Ecto.Query

    SwarmCode.Domain.Repo.all(
      from(n in SwarmCode.Domain.Conversations.Node,
        where: like(n.id, ^(short <> "-%")),
        select: {n.status, n.integrated}
      )
    )
    |> Enum.all?(fn {status, integrated} ->
      status in ~w(done failed stopped) and integrated == true
    end)
  end

  @doc "Where an agent's delta patch lives: `<root>/.swarm_code/isolation/<short>`."
  @spec delta_dir(String.t(), String.t()) :: String.t()
  def delta_dir(project_root, node_id),
    do: Path.join([project_root, ".swarm_code", "isolation", short_id(node_id)])

  @doc """
  Removes an isolated agent's directory, whichever backend made it. # spec 73 T72

  The one cleanup path: the ownership marker goes first (spec 72 D5); a
  clone's branch is fetched into the project before its directory is removed
  (spec 72 R2) and a clone whose fetch fails is kept, with the reason (spec 73
  T73); a worktree is removed through git; the worktree list is pruned either
  way. `git` is the RunServer's adapter seam.
  """
  #
  # spec 74 BUGS-4: `require_clean: true` (the run-end and boot-sweep paths,
  # after their safety commit) keeps a tree that still has uncommitted work —
  # directory, marker, branch and delta — and answers `{:error, :dirty}`.
  # `git worktree remove --force` and `File.rm_rf` used to delete the only copy
  # of a worker's work whenever its commit had failed. `IntegrateAgent`'s
  # cleanup leaves the option off: right after a delta apply a tree can
  # legitimately be dirty.
  @spec cleanup(String.t(), map(), module(), keyword()) :: :ok | {:error, term()}
  def cleanup(project_root, node, git \\ SwarmCode.Domain.Git, opts \\ [])

  def cleanup(project_root, %{workspace_path: path} = node, git, opts)
      when is_binary(path) and path != "" do
    if opts[:require_clean] && dirty?(path),
      do: {:error, :dirty},
      else: remove(project_root, path, node, git)
  end

  def cleanup(_project_root, _node, _git, _opts), do: :ok

  # A directory that is already gone holds nothing to lose.
  defp dirty?(path), do: File.dir?(path) and not match?({:ok, []}, status_checked(path))

  defp remove(project_root, path, node, git) do
    __MODULE__.Ownership.remove(path)

    # spec 74 EFFICIENCY-53: an isolated agent's `lsp` calls start language
    # servers keyed by its own root; they used to outlive the directory for
    # the client's 300 s idle timeout, with a deleted cwd.
    SwarmCode.Domain.LSP.stop_project(path)

    result =
      if __MODULE__.Clone.clone_dir?(path) do
        case export(project_root, path, Map.get(node, :branch)) do
          :ok ->
            File.rm_rf(path)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      else
        git.worktree_remove(project_root, path)
        :ok
      end

    git.worktree_prune(project_root)
    result
  end

  defp export(project_root, path, branch) when is_binary(branch) and branch != "",
    do: __MODULE__.Clone.export_branch(project_root, path, branch)

  defp export(_project_root, _path, _branch), do: :ok

  # spec 74 BUGS-4: a safety commit runs none of the user's or the repo's
  # hooks and never signs — a commit-msg hook that rejects "swarm: …" or a
  # `commit.gpgsign` with no agent used to fail it, and the cleanup that
  # followed removed the uncommitted work.
  @safety_flags ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]

  @doc """
  spec 74 BUGS-4: `git add -A` and `git commit --no-verify` in `path`, with no
  hooks and no signing. `:ok` or `{:error, reason}`; nothing is raised.
  """
  @spec safety_commit(String.t(), String.t()) :: :ok | {:error, String.t()}
  def safety_commit(path, message) do
    with {:ok, _} <- SwarmCode.Domain.Git.run(path, @safety_flags ++ ["add", "-A"]),
         {:ok, _} <-
           SwarmCode.Domain.Git.run(
             path,
             @safety_flags ++ ["commit", "--no-verify", "-q", "-m", message]
           ) do
      :ok
    end
  end

  @doc """
  spec 74 BUGS-4: commits whatever `path` holds (`safety_commit/2`) and then
  checks that nothing is left: `:ok` for a tree that is clean afterwards,
  `{:error, reason}` for one that is not or that git could not read.
  """
  @spec commit_dirty(String.t(), String.t()) :: :ok | {:error, String.t()}
  def commit_dirty(path, message) do
    with {:ok, [_ | _]} <- status_checked(path),
         :ok <- safety_commit(path, message),
         {:ok, []} <- status_checked(path) do
      :ok
    else
      {:ok, []} -> :ok
      {:ok, [_ | _]} -> {:error, "uncommitted work is left after the commit"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  @doc """
  spec 74 BUGS-4: the porcelain status lines of `path`, or `{:error, reason}`
  — `Git.status/1` answers `[]` for any git error, which reads as "clean".
  """
  @spec status_checked(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def status_checked(path) do
    case SwarmCode.Domain.Git.run(path, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, out} -> {:ok, out |> String.split("\n") |> Enum.reject(&(String.trim(&1) == ""))}
      {:error, reason} -> {:error, reason}
    end
  end
end
