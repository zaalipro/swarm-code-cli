defmodule SwarmCode.Domain.Tools.IntegrateAgent do
  @moduledoc "Merges an isolated sub-agent's branch back into the working project."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.{Conversations, Git}
  alias SwarmCode.Domain.Engine.Isolation.Clone
  alias SwarmCode.Domain.Projects.Workspace
  alias SwarmCode.Domain.Tools.Path, as: SafePath

  @impl true
  def name, do: "integrate_agent"

  @impl true
  def description,
    do:
      "Merge the git branch of a sub-agent that worked in an isolated worktree into the " <>
        "current project. Use the branch name reported when the sub-agent finished."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "branch" => %{"type" => "string", "description" => "The sub-agent's branch name"}
      },
      "required" => ["branch"]
    }
  end

  @impl true
  def permission(_args), do: :write

  # spec 66 T20: a merge into the working tree runs alone.
  @impl true
  def parallel?, do: false

  @impl true
  def title(args), do: "integrate " <> to_string(args["branch"] || "")

  @impl true
  def run(args, ctx, progress) do
    branch = to_string(args["branch"])

    # Spec 51 §5.2: a nested sub runs with its own worktree as `project_root`;
    # the worktrees live under the project's root, so that is what the node is
    # validated (and cleaned) against. The merge itself stays where the caller
    # works. The branch may also belong to an earlier run of the conversation
    # (a resumed swarm integrating what the old attempt left).
    root = confinement_root(ctx)

    with {:ok, branch} <- Git.validate_revision(branch),
         %{} = node <-
           Conversations.unintegrated_run_branch(ctx.run_id, branch) ||
             Conversations.unintegrated_branch(ctx[:conversation_id], ctx[:project_id], branch),
         :ok <- validate_node(root, node) do
      progress.(nil, "merging " <> branch)

      # spec 72 D4: try delta-patch apply before falling back to merge.
      case try_delta_patch(root, ctx.project_root, node, branch) do
        {:applied, stat_msg} ->
          cleanup(root, node)
          progress.(100, "merged")
          {:ok, stat_msg}

        {:already_applied, msg} ->
          cleanup(root, node)
          progress.(100, "merged")
          {:ok, msg}

        :no_delta ->
          do_merge(ctx.project_root, root, branch, node, progress)
      end
    else
      {:error, message} -> {:error, message}
      nil -> {:error, "no unintegrated agent branch #{branch} belongs to this run"}
    end
  end

  defp confinement_root(ctx) do
    case ctx[:project_id] && SwarmCode.Domain.Projects.get(ctx.project_id) do
      %{root_path: root} when is_binary(root) and root != "" -> root
      _other -> ctx.project_root
    end
  end

  @doc """
  Checks that a node's worktree is one of ours before anything is removed.

  Spec 32 §4: cleanup used to look the branch up globally and remove whatever
  `workspace_path` it found. A worktree lives under `<project>/.swarm_code/
  worktrees/<something>` and nowhere else.
  """
  @spec validate_node(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_node(root, %{workspace_path: path}) when is_binary(path) and path != "" do
    worktrees = Workspace.worktrees_dir(root)

    if path != worktrees and SafePath.confined?(worktrees, path),
      do: :ok,
      else: {:error, "that agent's worktree is not inside this project"}
  end

  # An agent that never got a worktree has nothing to remove, which is fine.
  def validate_node(_root, %{}), do: :ok

  @doc "Removes this node's worktree, deletes its branch and marks that node integrated."
  @spec cleanup(String.t(), map()) :: :ok | {:error, String.t()}
  def cleanup(root, %{branch: branch} = node) do
    with :ok <- validate_node(root, node) do
      # spec 72 D5 / R2 — spec 73 T72: the one cleanup path, shared with the
      # RunServer's run-end sweep (marker, clone export, removal, prune). The
      # branch is already integrated here, so a clone whose export fails is
      # still removed: nothing in it is the only copy any more.
      case SwarmCode.Domain.Engine.Isolation.cleanup(root, node) do
        :ok -> :ok
        {:error, _reason} -> File.rm_rf(node.workspace_path)
      end

      if is_binary(branch) and branch != "", do: Git.branch_delete(root, branch)
      # spec 72 R2: the applied delta patch has nothing left to say.
      File.rm_rf(delta_dir(root, node))
      Conversations.mark_node_integrated(node.id)
      :ok
    end
  end

  defp last_line(text) do
    text |> to_string() |> String.split("\n") |> Enum.reject(&(&1 == "")) |> List.last() ||
      "unknown error"
  end

  # spec 72 D4: try to apply the delta patch if available.
  defp try_delta_patch(root, project_root, node, branch) do
    delta_path = Path.join(delta_dir(root, node), "delta.patch")

    with true <- File.regular?(delta_path),
         {:ok, patch} <- File.read(delta_path),
         true <- byte_size(patch) > 0 do
      case Git.apply_patch(project_root, patch, three_way: true) do
        :ok ->
          {stat, _files} = Git.diff_stat(project_root)

          {:applied,
           "merged #{branch} (delta patch): #{if stat == "", do: "no changes", else: stat}"}

        {:error, :already_applied} ->
          {:already_applied, "#{branch} already integrated (no-op)"}

        {:error, _reason} ->
          # Fall through to the standard merge path.
          :no_delta
      end
    else
      _ -> :no_delta
    end
  end

  defp do_merge(project_root, root, branch, node, progress) do
    # spec 72 R2: a clone's branch is in the clone's own .git until it is
    # fetched over — without this the merge fallback never found it. spec 73
    # T73: a failed fetch is the answer, not a merge of whatever older copy
    # the project holds.
    export =
      case node do
        %{workspace_path: path} when is_binary(path) and path != "" ->
          if Clone.clone_dir?(path),
            do: Clone.export_branch(project_root, path, branch),
            else: :ok

        _other ->
          :ok
      end

    with :ok <- export do
      merge(project_root, root, branch, node, progress)
    else
      {:error, reason} ->
        {:error, "could not fetch #{branch} from its clone: " <> last_line(reason)}
    end
  end

  defp merge(project_root, root, branch, node, progress) do
    case Git.merge(project_root, branch) do
      {:ok, _out} ->
        {stat, _files} = Git.diff_stat(project_root, base: "HEAD~1")
        cleanup(root, node)
        progress.(100, "merged")
        {:ok, "merged #{branch}: #{if stat == "", do: "no changes", else: stat}"}

      {:error, {:conflicts, paths}} ->
        {:error, "conflicts in: #{Enum.join(paths, ", ")} — resolve manually"}

      {:error, reason} ->
        {:error, "could not merge #{branch}: " <> last_line(reason)}
    end
  end

  # spec 72 F2: where RunServer persisted this node's delta patch — spec 73
  # T60: the layout comes from `SwarmCode.Domain.Engine.Isolation`, the writer's side.
  defp delta_dir(root, %{id: id}) when is_binary(id),
    do: SwarmCode.Domain.Engine.Isolation.delta_dir(root, id)

  defp delta_dir(root, _node), do: Path.join([root, ".swarm_code", "isolation", "unknown"])
end
