defmodule SwarmCode.Domain.Engine.Isolation.Backend do
  # spec 72 D1
  @moduledoc """
  Behaviour for isolation backends that create sandboxed directories for
  sub-agents to work in.
  """

  @callback create(project_root :: String.t(), target_path :: String.t(), opts :: keyword()) ::
              {:ok, %{root: String.t(), branch: String.t() | nil, base_sha: String.t()}}
              | {:error, String.t()}

  # spec 73 T72: a backend only creates. Removal is
  # `SwarmCode.Domain.Engine.Isolation.cleanup/3` for both backends — the marker, a
  # clone's branch export, the directory and the worktree prune in one place.
end
