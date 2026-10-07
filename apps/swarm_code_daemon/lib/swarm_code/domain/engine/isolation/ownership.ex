defmodule SwarmCode.Domain.Engine.Isolation.Ownership do
  # spec 72 D5
  @moduledoc """
  Ownership markers for isolation directories. Prevents stale directories
  from being cleaned up while another process is still using them, even
  after PID recycling.
  """

  require Logger

  alias SwarmCode.Domain.Engine.Isolation.Clone
  alias SwarmCode.Domain.Git

  @marker_file ".swarm_code_isolation_owner.json"

  @type marker :: %{
          pid: integer(),
          node_id: String.t(),
          start_token: String.t() | nil
        }

  @doc "The marker's file name, for the git exclude list (spec 72 R5)."
  @spec marker_file() :: String.t()
  def marker_file, do: @marker_file

  @doc "Write an ownership marker into `isolation_dir`."
  @spec write(String.t(), String.t()) :: :ok | {:error, term()}
  def write(isolation_dir, node_id) do
    pid = self_os_pid()
    token = process_start_token(pid)
    marker = %{pid: pid, node_id: node_id, start_token: token}
    path = Path.join(isolation_dir, @marker_file)
    File.mkdir_p!(isolation_dir)

    # spec 72 R5: same-directory atomic replacement — a boot sweep that reads
    # a half-written marker would reclaim a live directory.
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, Jason.encode!(marker)),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Returns true if the owner process recorded in the marker is still alive."
  @spec live?(String.t()) :: boolean()
  def live?(isolation_dir) do
    path = Path.join(isolation_dir, @marker_file)

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, %{"pid" => pid, "start_token" => token}} when is_integer(pid) ->
            check_pid_alive(pid, token)

          _ ->
            # Malformed marker — safe to reclaim.
            false
        end

      {:error, _} ->
        # Missing marker — safe to reclaim.
        false
    end
  end

  @doc "Remove the ownership marker. Best-effort, never fails."
  @spec remove(String.t()) :: :ok
  def remove(isolation_dir) do
    path = Path.join(isolation_dir, @marker_file)
    File.rm(path)
    :ok
  end

  @doc """
  Walk `worktrees_root`, removing subdirectories whose owner is no longer alive.
  Returns the count of removed directories.

  spec 73 T12: with `project_root`, a dead directory that is a git tree is
  settled the way `RunServer.cleanup_worktrees/1` settles a run's — its
  uncommitted work is committed as `(stopped)`, a clone's `swarm/` branch is
  fetched into the project (`Clone.export_branch/3`) and the directory only
  goes when that succeeded; a failed export keeps the directory and logs.
  Without it (tests, a directory that is not a project) the sweep removes.
  """
  @spec cleanup_stale(String.t(), String.t() | nil) :: {:ok, non_neg_integer()}
  def cleanup_stale(worktrees_root, project_root \\ nil) do
    case File.ls(worktrees_root) do
      {:ok, entries} ->
        branches =
          for entry <- entries,
              subdir = Path.join(worktrees_root, entry),
              File.dir?(subdir) and not live?(subdir),
              {:removed, branch} <- [reclaim(subdir, project_root)],
              do: branch

        if is_binary(project_root) do
          Git.worktree_prune(project_root)
          # After the prune: a worktree's branch is "checked out" until then.
          Enum.each(branches, &drop_spent_branch(project_root, &1))
        end

        {:ok, length(branches)}

      {:error, _} ->
        {:ok, 0}
    end
  end

  # spec 73 T12. spec 74 ARCHITECTURE-6: `{:removed, branch}` — the branch the
  # dir had checked out (read before it goes), or `:kept`.
  defp reclaim(subdir, project_root) do
    branch = if File.exists?(Path.join(subdir, ".git")), do: Git.current_branch(subdir)

    case preserve_work(subdir, project_root) do
      :ok ->
        Logger.info("swarm_code removing stale isolation dir: #{subdir}")
        File.rm_rf(subdir)
        {:removed, branch}

      {:error, reason} ->
        Logger.warning("swarm_code kept stale isolation dir #{subdir}: #{reason}")
        :kept
    end
  end

  # spec 74 ARCHITECTURE-6: every dead dir used to leave its `swarm/<run>/<name>`
  # branch in the user's repository for good, most of them with nothing on
  # them. A branch with no commit the project's HEAD lacks is deleted — the
  # delete loses nothing; one with commits ahead is the user's recoverable
  # work and stays.
  defp drop_spent_branch(project_root, "swarm/" <> _ = branch) do
    case Git.commits_ahead(project_root, "HEAD", branch) do
      {:ok, 0} ->
        Logger.info("swarm_code deleting spent branch #{branch}")
        Git.branch_delete(project_root, branch)

      _ahead_or_unknown ->
        :ok
    end
  end

  defp drop_spent_branch(_project_root, _other), do: :ok

  defp preserve_work(_subdir, nil), do: :ok

  defp preserve_work(subdir, project_root) do
    # Only a directory with its own `.git` (a clone's directory, a worktree's
    # file) is a tree of its own: a plain directory under the project would
    # answer git's questions for the *project* and `add -A` the user's tree.
    if File.exists?(Path.join(subdir, ".git")) do
      # spec 74 BUGS-4: a tree whose work could not be committed is kept —
      # `reclaim/2` used to `rm_rf` it whatever the commit said.
      with :ok <- commit_stopped(subdir) do
        with true <- Clone.clone_dir?(subdir),
             "swarm/" <> _ = branch <- Git.current_branch(subdir) do
          Clone.export_branch(project_root, subdir, branch)
        else
          _worktree_or_other_branch -> :ok
        end
      end
    else
      :ok
    end
  end

  # spec 74 BUGS-4: the safety commit (no hooks, no signing), and its result.
  defp commit_stopped(dir) do
    SwarmCode.Domain.Engine.Isolation.commit_dirty(dir, "swarm: (stopped)")
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Returns the OS pid of this BEAM instance.
  defp self_os_pid do
    System.pid() |> String.to_integer()
  end

  # Check if a PID is alive, comparing start tokens to detect recycling.
  # spec 73 T71: `SwarmCode.Domain.OSProcess.alive?/1` (one `ps`, what run_command
  # uses) instead of a second liveness mechanism built on `kill -0` and the
  # locale of its error string.
  defp check_pid_alive(pid, expected_token) do
    SwarmCode.Domain.OSProcess.alive?(pid) and
      (is_nil(expected_token) or process_start_token(pid) == expected_token)
  end

  # macOS: use `ps -o lstart= -p <pid>` to get the process start time.
  defp process_start_token(pid) do
    case System.cmd("ps", ["-o", "lstart=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {out, 0} ->
        trimmed = String.trim(out)
        if trimmed != "", do: trimmed, else: nil

      _ ->
        nil
    end
  end
end
