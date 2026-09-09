defmodule SwarmCode.Domain.Projects.Workspace do
  @moduledoc """
  Paths SwarmCode keeps per project (`<root>/.swarm_code`) and globally
  (`SwarmCode.Domain.Paths.config_dir()`).
  """

  alias SwarmCode.Domain.Git

  @dir ".swarm_code"

  @spec dir(String.t()) :: String.t()
  def dir(root), do: Path.join(root, @dir)

  @spec memory_file(String.t()) :: String.t()
  def memory_file(root), do: Path.join(dir(root), "MEMORY.md")

  @spec commands_dir(String.t()) :: String.t()
  def commands_dir(root), do: Path.join(dir(root), "commands")

  @spec worktrees_dir(String.t()) :: String.t()
  def worktrees_dir(root), do: Path.join(dir(root), "worktrees")

  @doc "Spec 45 §6.2: where a consensus run's `write_spec` files land."
  @spec specs_dir(String.t()) :: String.t()
  def specs_dir(root), do: Path.join(dir(root), "specs")

  @doc """
  Creates `<root>/.swarm_code` and, in a git repo, makes git ignore it through
  `.git/info/exclude` (no change to the user's own .gitignore).
  """
  @spec ensure!(String.t()) :: String.t()
  def ensure!(root) do
    path = dir(root)
    File.mkdir_p(path)
    if Git.repo?(root), do: Git.exclude!(root, @dir <> "/")
    path
  end

  @spec global_dir() :: String.t()
  def global_dir, do: SwarmCode.Domain.Paths.config_dir()

  @spec global_memory_file() :: String.t()
  def global_memory_file, do: Path.join(global_dir(), "MEMORY.md")

  @spec global_commands_dir() :: String.t()
  def global_commands_dir, do: Path.join(global_dir(), "commands")

  @spec attachments_dir() :: String.t()
  def attachments_dir, do: Path.join(global_dir(), "attachments")

  @doc "Creates a directory (and its parents) and returns it."
  @spec ensure_dir!(String.t()) :: String.t()
  def ensure_dir!(path) do
    File.mkdir_p(path)
    path
  end
end
