defmodule SwarmCode.Domain.Engine.Isolation.Worktree do
  # spec 72 D1
  @moduledoc """
  Git worktree isolation backend. Extracts today's logic from RunServer into
  the Backend behaviour.
  """

  @behaviour SwarmCode.Domain.Engine.Isolation.Backend

  alias SwarmCode.Domain.Git

  # spec 72 R5: `:git` is RunServer's adapter seam (`run_server_git_adapter`)
  # — the extraction called SwarmCode.Domain.Git directly and the blocking-git tests
  # never saw their `worktree add`.
  @impl true
  def create(project_root, target_path, opts) do
    branch = Keyword.get(opts, :branch)
    git = Keyword.get(opts, :git, Git)

    case git.worktree_add(project_root, target_path, branch) do
      {:ok, _} ->
        base_sha = git.head(project_root) || ""
        {:ok, %{root: target_path, branch: branch, base_sha: base_sha}}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end
end
