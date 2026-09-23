defmodule SwarmCode.Domain.Engine.Isolation.Baseline do
  # spec 72 D2
  @moduledoc """
  Captures the repository state before a sub-agent starts working, so that a
  delta can be computed when it finishes.
  """

  @max_content_bytes 10_000_000

  defstruct [:head_sha, :staged_diff, :unstaged_diff, :untracked_patch, :captured_at]

  @type t :: %__MODULE__{
          head_sha: String.t(),
          staged_diff: binary(),
          unstaged_diff: binary(),
          untracked_patch: binary(),
          captured_at: DateTime.t()
        }

  alias SwarmCode.Domain.Engine.Isolation.Delta
  alias SwarmCode.Domain.Git

  @spec capture(String.t()) :: {:ok, t()} | {:error, String.t()}
  def capture(project_root) do
    head_sha = Git.head(project_root) || ""
    # spec 72 R4: the diffs are read up to the cap, and a cut diff is an error.
    opts = [max_bytes: @max_content_bytes]

    with {:ok, staged} <- Git.diff_staged(project_root, opts),
         false <- Git.truncated?(staged),
         {:ok, unstaged} <- Git.diff_unstaged(project_root, opts),
         false <- Git.truncated?(unstaged) do
      budget = @max_content_bytes - byte_size(staged) - byte_size(unstaged)

      if budget < 0 do
        {:error, "baseline too large: #{byte_size(staged) + byte_size(unstaged)} bytes"}
      else
        case build_untracked_patch(project_root, budget) do
          {:over, _partial} ->
            {:error, "baseline too large: untracked content exceeds cap"}

          {:ok, untracked} ->
            {:ok,
             %__MODULE__{
               head_sha: head_sha,
               staged_diff: staged,
               unstaged_diff: unstaged,
               untracked_patch: untracked,
               captured_at: DateTime.utc_now()
             }}
        end
      end
    else
      {:error, reason} -> {:error, to_string(reason)}
      true -> {:error, "baseline too large: diff exceeds cap"}
    end
  end

  defp build_untracked_patch(root, budget) do
    case Git.ls_untracked(root) do
      {:ok, files} ->
        do_build_untracked(root, files, budget, [])

      # spec 72 R4: this returned a bare "" the caller's case never matched.
      _ ->
        {:ok, ""}
    end
  end

  defp do_build_untracked(_root, [], _budget, acc),
    do: {:ok, acc |> Enum.reverse() |> Enum.join("\n")}

  defp do_build_untracked(_root, _files, budget, acc) when budget <= 0 do
    {:over, acc |> Enum.reverse() |> Enum.join("\n")}
  end

  # spec 73 T69: the size is checked with a stat before the file is read —
  # a 4 GB untracked file was loaded into the isolation task first and
  # compared with the budget afterwards.
  defp do_build_untracked(root, [file | rest], budget, acc) do
    path = Path.join(root, file)

    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > budget ->
        {:over, acc |> Enum.reverse() |> Enum.join("\n")}

      {:ok, %{type: :regular}} ->
        case File.read(path) do
          {:ok, content} when byte_size(content) <= budget ->
            case Delta.new_file_patch(file, content) do
              nil -> do_build_untracked(root, rest, budget, acc)
              patch -> do_build_untracked(root, rest, budget - byte_size(patch), [patch | acc])
            end

          {:ok, _grew_past_the_stat} ->
            {:over, acc |> Enum.reverse() |> Enum.join("\n")}

          _ ->
            do_build_untracked(root, rest, budget, acc)
        end

      _not_a_regular_file ->
        do_build_untracked(root, rest, budget, acc)
    end
  end
end
