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
  @spec cleanup(String.t(), map(), module()) :: :ok | {:error, term()}
  def cleanup(project_root, node, git \\ SwarmCode.Domain.Git)

  def cleanup(project_root, %{workspace_path: path} = node, git)
      when is_binary(path) and path != "" do
    __MODULE__.Ownership.remove(path)

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

  def cleanup(_project_root, _node, _git), do: :ok

  defp export(project_root, path, branch) when is_binary(branch) and branch != "",
    do: __MODULE__.Clone.export_branch(project_root, path, branch)

  defp export(_project_root, _path, _branch), do: :ok
end
