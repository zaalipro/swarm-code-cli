defmodule SwarmCode.Governance.ProvenanceSync.Git do
  @moduledoc """
  Read-only access to the upstream desktop checkout: `rev-parse`, `status`,
  `ls-tree` and `cat-file` against a commit, never a checkout. Plus
  `git merge-file` on private temporary copies for the three-way merge.
  """

  @ref_pattern ~r/\A[0-9A-Za-z][0-9A-Za-z._\/^~-]{0,199}\z/

  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref), do: is_binary(ref) and Regex.match?(@ref_pattern, ref)

  @doc "The full commit sha `ref` names in `upstream`."
  @spec resolve(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(upstream, ref) do
    with :ok <- repository(upstream),
         true <- valid_ref?(ref) || {:error, "invalid upstream ref #{inspect(ref)}"},
         {:ok, out} <- git(upstream, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]),
         sha = String.trim(out),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) || {:error, "cannot resolve #{ref}"} do
      {:ok, sha}
    else
      {:error, _message} = error -> error
    end
  end

  @spec clean?(Path.t()) :: boolean()
  def clean?(upstream) do
    match?({:ok, ""}, git(upstream, ["status", "--porcelain", "--untracked-files=no"]))
  end

  @doc "Every blob path under `prefix` at `sha` (`prefix` may also name one file)."
  @spec ls_tree(Path.t(), String.t(), String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def ls_tree(upstream, sha, prefix) do
    case git(upstream, ["ls-tree", "-r", "-z", "--name-only", sha, "--", prefix]) do
      {:ok, out} -> {:ok, out |> String.split(<<0>>, trim: true) |> Enum.sort()}
      error -> error
    end
  end

  @doc "The exact bytes of `path` at `sha`."
  @spec show(Path.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def show(upstream, sha, path) do
    case git(upstream, ["cat-file", "blob", sha <> ":" <> path]) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _message} -> {:error, "#{path} does not exist at #{short(sha)}"}
    end
  end

  @doc """
  Three-way merge of `ours` (the CLI file) with the upstream change `base` →
  `theirs`. Returns `{:ok, merged}` or `{:conflict, text_with_markers}`.
  """
  @spec merge(binary(), binary(), binary(), [String.t()]) ::
          {:ok, binary()} | {:conflict, binary()} | {:error, String.t()}
  def merge(ours, base, theirs, [ours_label, base_label, theirs_label]) do
    dir = Path.join(System.tmp_dir!(), "provenance-sync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    try do
      paths =
        for {name, bytes} <- [ours: ours, base: base, theirs: theirs], into: %{} do
          path = Path.join(dir, Atom.to_string(name))
          File.write!(path, bytes)
          {name, path}
        end

      args =
        ["merge-file", "-p", "--diff3"] ++
          ["-L", ours_label, "-L", base_label, "-L", theirs_label] ++
          [paths.ours, paths.base, paths.theirs]

      case System.cmd("git", args, stderr_to_stdout: false) do
        {merged, 0} -> {:ok, merged}
        {merged, status} when status in 1..127 -> {:conflict, merged}
        {_output, status} -> {:error, "git merge-file failed with status #{status}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  @spec short(String.t()) :: String.t()
  def short(sha), do: String.slice(sha, 0, 7)

  defp repository(upstream) do
    cond do
      not is_binary(upstream) or not File.dir?(upstream) ->
        {:error, "upstream checkout #{inspect(upstream)} does not exist"}

      match?({:ok, _}, git(upstream, ["rev-parse", "--git-dir"])) ->
        :ok

      true ->
        {:error, "#{upstream} is not a git checkout"}
    end
  end

  defp git(upstream, args) do
    case System.cmd("git", ["-C", upstream | args], stderr_to_stdout: false, into: "") do
      {out, 0} -> {:ok, out}
      {_out, status} -> {:error, "git #{hd(args)} failed with status #{status}"}
    end
  rescue
    error in ErlangError -> {:error, "git is unavailable: #{Exception.message(error)}"}
  end
end
