defmodule SwarmCode.Domain.Tools.IntegrateAgent do
  @moduledoc "Merges an isolated sub-agent's branch back into the working project."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.{Conversations, Git}
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

      case Git.merge(ctx.project_root, branch) do
        {:ok, _out} ->
          {stat, _files} = Git.diff_stat(ctx.project_root, base: "HEAD~1")
          cleanup(root, node)
          progress.(100, "merged")
          {:ok, "merged #{branch}: #{if stat == "", do: "no changes", else: stat}"}

        {:error, {:conflicts, paths}} ->
          {:error, "conflicts in: #{Enum.join(paths, ", ")} — resolve manually"}

        {:error, reason} ->
          {:error, "could not merge #{branch}: " <> last_line(reason)}
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
      case node do
        %{workspace_path: path} when is_binary(path) and path != "" ->
          Git.worktree_remove(root, path)

        _other ->
          :ok
      end

      Git.worktree_prune(root)
      if is_binary(branch) and branch != "", do: Git.branch_delete(root, branch)
      Conversations.mark_node_integrated(node.id)
      :ok
    end
  end

  defp last_line(text) do
    text |> to_string() |> String.split("\n") |> Enum.reject(&(&1 == "")) |> List.last() ||
      "unknown error"
  end
end
