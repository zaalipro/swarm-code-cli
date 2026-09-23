defmodule SwarmCode.Governance.ProvenanceSync.UnifiedDiff do
  @moduledoc """
  A deterministic unified diff (three lines of context) computed in-process with
  `List.myers_difference/2`, so a recorded CLI patch does not depend on the
  installed `git`/`diff` version. Lines keep their terminator: a missing final
  newline is a real difference and is printed the way `git diff` prints it.
  """

  @context 3

  @doc "The unified diff from `old` to `new`, or `\"\"` when they are equal."
  @spec diff(binary(), binary(), String.t(), String.t()) :: binary()
  def diff(old, new, old_label, new_label)
      when is_binary(old) and is_binary(new) and is_binary(old_label) and is_binary(new_label) do
    if old == new do
      ""
    else
      ops = old |> lines() |> List.myers_difference(lines(new)) |> annotate()

      hunks =
        ops
        |> change_ranges()
        |> Enum.map(&hunk(ops, &1))

      IO.iodata_to_binary(["--- a/", old_label, "\n+++ b/", new_label, "\n" | hunks])
    end
  end

  @doc false
  @spec lines(binary()) :: [binary()]
  def lines(text), do: String.split(text, ~r/(?<=\n)/, trim: true)

  defp annotate(script) do
    script
    |> Enum.flat_map(fn {kind, lines} -> Enum.map(lines, &{kind, &1}) end)
    |> Enum.map_reduce({1, 1}, fn
      {:eq, line}, {i, j} -> {{:eq, line, i, j}, {i + 1, j + 1}}
      {:del, line}, {i, j} -> {{:del, line, i, j}, {i + 1, j}}
      {:ins, line}, {i, j} -> {{:ins, line, i, j}, {i, j + 1}}
    end)
    |> elem(0)
    |> List.to_tuple()
  end

  # Op-index ranges {first, last} of each hunk: every change widened by the
  # context, neighbours merged when at most 2 × context equal lines separate them.
  defp change_ranges(ops) do
    last_index = tuple_size(ops) - 1

    changes = for k <- 0..last_index//1, elem(elem(ops, k), 0) != :eq, do: k

    changes
    |> Enum.chunk_while(
      nil,
      fn
        k, nil -> {:cont, {k, k}}
        k, {first, previous} when k - previous - 1 <= 2 * @context -> {:cont, {first, k}}
        k, range -> {:cont, range, {k, k}}
      end,
      fn
        nil -> {:cont, nil}
        range -> {:cont, range, nil}
      end
    )
    |> Enum.map(fn {first, last} ->
      {max(first - @context, 0), min(last + @context, last_index)}
    end)
  end

  defp hunk(ops, {first, last}) do
    range = for k <- first..last, do: elem(ops, k)
    {_kind, _line, i, j} = hd(range)
    old_count = Enum.count(range, &(elem(&1, 0) != :ins))
    new_count = Enum.count(range, &(elem(&1, 0) != :del))

    body =
      Enum.map(range, fn
        {:eq, line, _i, _j} -> body_line(" ", line)
        {:del, line, _i, _j} -> body_line("-", line)
        {:ins, line, _i, _j} -> body_line("+", line)
      end)

    ["@@ -", span(i, old_count), " +", span(j, new_count), " @@\n" | body]
  end

  # A zero-length side names the line before it, as GNU diff and git do.
  defp span(start, 0), do: "#{start - 1},0"
  defp span(start, 1), do: Integer.to_string(start)
  defp span(start, count), do: "#{start},#{count}"

  defp body_line(prefix, line) do
    if String.ends_with?(line, "\n"),
      do: [prefix, line],
      else: [prefix, line, "\n\\ No newline at end of file\n"]
  end
end
