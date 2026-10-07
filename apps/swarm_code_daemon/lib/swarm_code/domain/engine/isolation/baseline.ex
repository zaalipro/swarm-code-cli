defmodule SwarmCode.Domain.Engine.Isolation.Baseline do
  # spec 72 D2
  @moduledoc """
  Captures the repository state before a sub-agent starts working, so that a
  delta can be computed when it finishes.
  """

  defstruct [:head_sha, :captured_at]

  @typedoc """
  spec 74 BUGS-59: the HEAD the isolated agent starts from. A clone is reset
  to HEAD and a worktree is checked out at it, so the directory is clean when
  the agent starts: the staged, unstaged and untracked diffs this used to
  carry (up to 10 MB each, held for the run's life) were always empty, and the
  delta is `diff(head_sha, HEAD)` plus whatever the agent left uncommitted.
  """
  @type t :: %__MODULE__{head_sha: String.t(), captured_at: DateTime.t()}

  alias SwarmCode.Domain.Git

  @spec capture(String.t()) :: {:ok, t()}
  def capture(project_root),
    do:
      {:ok, %__MODULE__{head_sha: Git.head(project_root) || "", captured_at: DateTime.utc_now()}}
end
