defmodule SwarmCode.Domain.FuzzyMatch do
  @moduledoc """
  Case-insensitive fuzzy matching for file paths.
  # spec 70 E5
  """

  @doc """
  Score a candidate path against a query. Returns `{:match, score}` if all
  query characters appear in order in the path, or `:no_match` otherwise.

  Scoring: +3 for matching after `/` or `.` (segment/extension start),
  +2 for consecutive matches, +1 for each match.
  """
  # spec 73 T94: every position is a byte offset — the old walk sliced by
  # grapheme (`String.slice/2`), added a byte offset from `:binary.match/2`
  # and read the separator with `String.at/2`, so a path with a non-ASCII
  # character before the match (`docs/résumé.md`) scored the wrong bytes or
  # missed; the slice also copied the tail once per query character.
  def score(candidate, query) do
    downcased = String.downcase(candidate)
    query_chars = String.downcase(query) |> String.graphemes()

    do_score(downcased, query_chars, 0, -1, 0)
  end

  defp do_score(_candidate, [], _pos, _last_match, score), do: {:match, score}

  defp do_score(candidate, [qc | rest], pos, last_match, score) do
    case find_char(candidate, qc, pos) do
      nil ->
        :no_match

      found_pos ->
        bonus =
          cond do
            # Match right after / or . = segment/extension start
            found_pos > 0 and binary_part(candidate, found_pos - 1, 1) in ["/", "."] -> 3
            # Consecutive match
            found_pos == last_match + 1 -> 2
            true -> 0
          end

        next = found_pos + byte_size(qc)
        do_score(candidate, rest, next, next - 1, score + 1 + bonus)
    end
  end

  defp find_char(string, char, from_pos) when from_pos < byte_size(string) do
    case :binary.match(string, char, scope: {from_pos, byte_size(string) - from_pos}) do
      {offset, _} -> offset
      :nomatch -> nil
    end
  end

  defp find_char(_string, _char, _from_pos), do: nil

  @doc """
  Filter and rank candidates by fuzzy match against the query.
  Returns the top `limit` matches sorted by score descending.
  """
  def filter(candidates, query, limit \\ 50) do
    candidates
    |> Enum.reduce([], fn path, acc ->
      case score(path, query) do
        {:match, s} -> [{path, s} | acc]
        :no_match -> acc
      end
    end)
    |> Enum.sort_by(fn {_path, s} -> s end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {path, _s} -> path end)
  end
end
