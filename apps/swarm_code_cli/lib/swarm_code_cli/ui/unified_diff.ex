defmodule SwarmCodeCLI.UI.UnifiedDiff do
  @moduledoc """
  Parses `git diff --no-color` text into per-file blocks for the Scene.

  Mirrors the desktop parser: `diff --git` starts a file, `@@` starts a hunk,
  and inside a hunk the first byte classifies the line. Lines that arrive
  before any `diff --git` header are dropped, because there is no file to
  attach them to. A single line budget spans every file and hunk; a hunk that
  would be emitted empty by the cut is dropped rather than shown as a bare
  header, and the elision marker is set only when a line was really removed.
  """
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Projector.Density

  @max_lines 2_000
  @too_large "File too large to show"

  @doc "The note the daemon sends instead of a diff when the file exceeds its cap."
  @spec too_large_note() :: binary()
  def too_large_note, do: @too_large

  @doc """
  Returns `{blocks, empty_note}`. `empty_note` is non-nil only when the input
  produced no files, so the caller can distinguish "nothing changed" from the
  daemon's explicit too-large note.

  `:ambiguous_width` selects the width policy used while escaping; it must
  match the policy the paint layer will wrap with.
  """
  @spec blocks(binary() | nil, keyword()) :: {[Block.Diff.t()], binary() | nil}
  def blocks(text, opts \\ [])
  def blocks(nil, _opts), do: {[], nil}

  def blocks(text, opts) when is_binary(text) do
    limit = Keyword.get(opts, :max_lines, @max_lines)
    policy = Keyword.get(opts, :ambiguous_width, :narrow)
    limits = %{Limits.content() | ambiguous_width: policy}

    {files, _remaining} =
      text
      |> parse()
      |> Enum.map_reduce(limit, &budget(&1, &2, limits))

    case Enum.reject(files, &is_nil/1) do
      [] -> {[], if(text == @too_large, do: @too_large, else: "No textual changes.")}
      kept -> {kept, nil}
    end
  end

  # ── parsing ──────────────────────────────────────────────────────────────

  defp parse(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], &consume/2)
    |> Enum.reverse()
    |> Enum.map(fn file -> %{file | hunks: finish_hunks(file.hunks)} end)
  end

  defp finish_hunks(hunks) do
    hunks
    |> Enum.reverse()
    |> Enum.map(fn {header, lines} -> {header, Enum.reverse(lines)} end)
  end

  defp consume("diff --git " <> rest, files),
    do: [%{path: git_path(rest), hunks: [], added: 0, removed: 0} | files]

  # Nothing to attach to yet: git preamble before the first file header.
  defp consume(_line, []), do: []

  defp consume("@@" <> _ = line, [file | rest]),
    do: [%{file | hunks: [{line, []} | file.hunks]} | rest]

  # Before the first hunk these are file headers (index/---/+++/mode), not content.
  defp consume(line, [%{hunks: []} = file | rest]) do
    case line do
      "+++ b/" <> path -> [%{file | path: path} | rest]
      _ -> [file | rest]
    end
  end

  defp consume(line, [file | rest]) do
    [{header, lines} | hunks] = file.hunks

    {kind, added, removed} =
      case line do
        "+" <> _ -> {:add, 1, 0}
        "-" <> _ -> {:del, 0, 1}
        "\\" <> _ -> {:meta, 0, 0}
        _ -> {:ctx, 0, 0}
      end

    file = %{
      file
      | hunks: [{header, [{kind, line} | lines]} | hunks],
        added: file.added + added,
        removed: file.removed + removed
    }

    [file | rest]
  end

  # "a/lib/foo.ex b/lib/foo.ex" → "lib/foo.ex"
  defp git_path(rest) do
    case String.split(rest, " b/", parts: 2) do
      [_a, b] -> b
      _ -> rest |> String.split(" ") |> List.last() |> to_string()
    end
  end

  # ── budgeting and conversion ─────────────────────────────────────────────

  defp budget(file, remaining, limits) do
    {hunks, {remaining, cut?}} =
      Enum.map_reduce(file.hunks, {remaining, false}, fn {header, lines}, {left, cut?} ->
        kept = Enum.take(lines, left)
        taken = length(kept)
        dropped? = taken < length(lines)
        hunk = if taken == 0 and dropped?, do: nil, else: {header, kept}
        {hunk, {left - taken, cut? or dropped?}}
      end)

    hunks = Enum.reject(hunks, &is_nil/1)

    block =
      if hunks == [] and cut? do
        nil
      else
        %Block.Diff{
          path: safe(file.path, limits),
          added: file.added,
          removed: file.removed,
          hunks:
            Enum.map(hunks, fn {header, lines} ->
              {safe(header, limits), safe_lines(lines, limits)}
            end),
          truncated?: cut?
        }
      end

    {block, remaining}
  end

  defp safe_lines(lines, limits),
    do: Enum.map(lines, fn {kind, text} -> {kind, safe(text, limits)} end)

  defp safe(text, limits), do: Density.external(text, limits)
end
