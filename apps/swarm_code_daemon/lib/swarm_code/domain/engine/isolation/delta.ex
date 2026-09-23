defmodule SwarmCode.Domain.Engine.Isolation.Delta do
  # spec 72 D3
  @moduledoc """
  Captures the changes an agent made relative to its baseline, producing a
  combined patch that can be applied with `git apply --3way`.
  """

  @max_patch_bytes 10_000_000

  defstruct [:patch, :untracked_files, :captured_at]

  @type t :: %__MODULE__{
          patch: binary(),
          untracked_files: [String.t()],
          captured_at: DateTime.t()
        }

  alias SwarmCode.Domain.Engine.Isolation.Baseline
  alias SwarmCode.Domain.Git

  @spec capture(String.t(), Baseline.t()) :: {:ok, t()} | {:error, String.t()}
  def capture(isolation_root, %Baseline{} = baseline) do
    current_head = Git.head(isolation_root) || ""

    # spec 72 R4: `Git.run/3` cut every diff at 200 000 characters and wrote
    # "…[truncated]" after it — a corrupt patch `git apply` refuses, so every
    # delta over that size silently fell back to the merge path. The bound is
    # the patch cap, and a cut diff is an error, never a patch.
    opts = [max_bytes: @max_patch_bytes]

    committed_diff =
      if current_head != baseline.head_sha and current_head != "" and baseline.head_sha != "" do
        case Git.run(isolation_root, ["diff", baseline.head_sha, current_head, "--binary"], opts) do
          {:ok, diff} -> diff
          _ -> ""
        end
      else
        ""
      end

    staged =
      case Git.diff_staged(isolation_root, opts) do
        {:ok, s} -> s
        _ -> ""
      end

    unstaged =
      case Git.diff_unstaged(isolation_root, opts) do
        {:ok, u} -> u
        _ -> ""
      end

    untracked_files =
      case Git.ls_untracked(isolation_root) do
        {:ok, files} -> files
        _ -> []
      end

    # spec 73 T69: what the diffs left of the cap is the untracked budget.
    remaining =
      @max_patch_bytes - byte_size(committed_diff) - byte_size(staged) - byte_size(unstaged)

    with false <- Enum.any?([committed_diff, staged, unstaged], &Git.truncated?/1),
         {:ok, untracked_patch} <- untracked_patch(isolation_root, untracked_files, remaining) do
      combined =
        [committed_diff, staged, unstaged, untracked_patch]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      if byte_size(combined) > @max_patch_bytes do
        {:error, "delta too large"}
      else
        {:ok,
         %__MODULE__{
           patch: combined,
           untracked_files: untracked_files,
           captured_at: DateTime.utc_now()
         }}
      end
    else
      _cut_or_over -> {:error, "delta too large"}
    end
  end

  @doc "How many files a combined patch touches — one `diff --git` header each."
  @spec files_changed(binary()) :: non_neg_integer()
  def files_changed(patch) when is_binary(patch),
    do: length(Regex.scan(~r/^diff --git /m, patch))

  @doc false
  # spec 72 R4: a unified diff that adds `file` with `content`. The old
  # hand-written form had no hunk header, doubled a trailing newline and
  # carried binaries as text — nothing `git apply` accepts. Binary content
  # (a NUL in the first 8 KB, git's own heuristic) yields nil: a text hunk
  # cannot carry it, and after `commit_and_stat` git's `--binary` diff does.
  @spec new_file_patch(String.t(), binary()) :: String.t() | nil
  def new_file_patch(file, content) when is_binary(file) and is_binary(content) do
    if binary?(content) do
      nil
    else
      header =
        "diff --git a/#{file} b/#{file}\nnew file mode 100644\n--- /dev/null\n+++ b/#{file}\n"

      case content do
        "" ->
          header

        _text ->
          parts = String.split(content, "\n")

          {lines, trailer} =
            if List.last(parts) == "",
              do: {Enum.drop(parts, -1), ""},
              else: {parts, "\\ No newline at end of file\n"}

          header <>
            "@@ -0,0 +1,#{length(lines)} @@\n" <>
            Enum.map_join(lines, "", &("+" <> &1 <> "\n")) <> trailer
      end
    end
  end

  defp binary?(content) do
    content
    |> binary_part(0, min(byte_size(content), 8_000))
    |> String.contains?(<<0>>)
  end

  # spec 73 T69: every untracked file used to be read whole with no budget —
  # the 10 MB check came after `Enum.join`. A binary file is still skipped
  # (its first 8 KB say so, as `new_file_patch/2` would), a text file is
  # checked against the remaining budget with a stat before it is read.
  defp untracked_patch(_root, [], _remaining), do: {:ok, ""}

  defp untracked_patch(root, files, remaining) do
    Enum.reduce_while(files, {:ok, [], remaining}, fn file, {:ok, acc, left} ->
      path = Path.join(root, file)

      with {:ok, %{type: :regular, size: size}} <- File.stat(path),
           false <- binary_head?(path) do
        if size > left do
          {:halt, {:error, "delta too large"}}
        else
          case File.read(path) do
            {:ok, content} when byte_size(content) <= left ->
              patch = new_file_patch(file, content) || ""
              {:cont, {:ok, [patch | acc], left - byte_size(patch)}}

            {:ok, _grew_past_the_stat} ->
              {:halt, {:error, "delta too large"}}

            _unreadable ->
              {:cont, {:ok, acc, left}}
          end
        end
      else
        _binary_or_missing -> {:cont, {:ok, acc, left}}
      end
    end)
    |> case do
      {:ok, patches, _left} ->
        {:ok, patches |> Enum.reject(&(&1 == "")) |> Enum.reverse() |> Enum.join("\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp binary_head?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 8_000)) do
      {:ok, head} when is_binary(head) -> String.contains?(head, <<0>>)
      _eof_or_error -> false
    end
  end
end
