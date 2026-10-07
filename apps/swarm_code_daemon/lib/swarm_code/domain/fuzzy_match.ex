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

  # `score/2` on an already-downcased candidate and query (spec 74 UI-SPEED-25).
  defp score_lower(lower, query_chars), do: do_score(lower, query_chars, 0, -1, 0)

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

  @typedoc "A path with its downcased form, `nil` when that is the path itself."
  @type entry :: {String.t(), String.t() | nil}

  @doc """
  The file finder's index (spec 74 UI-SPEED-25): each path downcased once,
  when the index is built, not on every keystroke. Most paths are already
  lower case and store `nil`, so the index stays about the size of the list.
  """
  @spec index([String.t()]) :: [entry()]
  def index(paths) do
    Enum.map(paths, fn path ->
      lower = String.downcase(path)
      {path, if(lower == path, do: nil, else: lower)}
    end)
  end

  @doc """
  `filter/3` over an `index/1`: the same paths in the same order (ties keep
  `filter/3`'s order, the later candidate first), with the query downcased
  once and the top `limit` kept in a bounded set instead of sorting every
  match.
  """
  @spec filter_indexed([entry()], String.t(), pos_integer()) :: [String.t()]
  def filter_indexed(entries, query, limit \\ 50),
    do: entries |> search_indexed(query, limit) |> elem(0)

  @doc """
  `filter_indexed/3` plus every matching entry, in index order. A caller that
  keeps the matches can search a longer query that starts with this one over
  them alone: a path that matches `"app"` matches `"ap"`, and the relative
  order — which breaks ties — is the same.
  """
  @spec search_indexed([entry()], String.t(), pos_integer()) :: {[String.t()], [entry()]}
  def search_indexed(entries, query, limit \\ 50) do
    query_chars = query |> String.downcase() |> String.graphemes()

    # `{set, size, floor}`: `floor` is the smallest `{score, index}` kept once
    # the set is full. Indices only grow, so a match scoring below the floor's
    # score can never enter — no set operation for most matches.
    {{set, _size, _floor}, matched, _i} =
      Enum.reduce(entries, {{:gb_sets.empty(), 0, nil}, [], 0}, fn {path, lower} = entry,
                                                                   {top, matched, i} ->
        case score_lower(lower || path, query_chars) do
          {:match, s} -> {keep(top, {s, i, path}, limit), [entry | matched], i + 1}
          :no_match -> {top, matched, i + 1}
        end
      end)

    top = set |> :gb_sets.to_list() |> Enum.reverse() |> Enum.map(&elem(&1, 2))
    {top, Enum.reverse(matched)}
  end

  defp keep({set, size, _floor}, item, limit) when size < limit do
    set = :gb_sets.add(item, set)
    size = size + 1
    {set, size, if(size == limit, do: :gb_sets.smallest(set))}
  end

  defp keep({set, size, {floor_score, _, _}} = top, {s, _, _} = item, _limit) do
    if s >= floor_score do
      {_dropped, set} = :gb_sets.take_smallest(:gb_sets.add(item, set))
      {set, size, :gb_sets.smallest(set)}
    else
      top
    end
  end

  defp keep(top, _item, _limit), do: top
end
