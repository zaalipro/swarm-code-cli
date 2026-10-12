defmodule SwarmCodeCLI.UI.Draft.Pastes do
  @moduledoc """
  cli020 D8 (ux-live-16, decision 4e): a large bracketed paste collapses to
  one placeholder in the draft, `[Pasted text #N · L lines]`, and its text
  waits in the draft's `pastes` map (`%{N => text}`, N from 1 per draft).

  On send every placeholder still present verbatim is replaced by its text
  (`expand/2`); one the user edited is sent as typed. Backspace or Delete
  next to a whole placeholder removes it at once (`deletion/3`), and the
  entry remains while current text, undo/redo or the vim register references it.
  Exact original markers expand on every occurrence, even when typed or duplicated
  by the user. Edited markers are literal. Inserted payload bytes are opaque and
  never scanned again. All expansion counts first and admits at most 262144 bytes.
  A paste collapses when `paste_collapse_lines`
  (cli.json, 8; 0 = never) is passed or it is over 4,096 bytes.
  """

  @max_bytes 4_096
  @max_message 262_144

  @doc "The words of placeholder `n` for a paste of `lines` lines."
  @spec placeholder(pos_integer(), pos_integer()) :: binary()
  def placeholder(n, 1), do: "[Pasted text ##{n} · 1 line]"
  def placeholder(n, lines), do: "[Pasted text ##{n} · #{lines} lines]"

  @doc "The number of lines of `text`."
  @spec lines(binary()) :: pos_integer()
  def lines(text), do: length(:binary.matches(text, "\n")) + 1

  @doc "Whether a paste of `text` collapses under a `limit` of lines (0 = never)."
  @spec collapse?(binary(), non_neg_integer()) :: boolean()
  def collapse?(_text, 0), do: false
  def collapse?(text, limit), do: lines(text) > limit or byte_size(text) > @max_bytes

  @doc """
  Collapses `text` into the draft's pastes: `{placeholder, pastes}` with
  the next free number.
  """
  @spec put(map(), binary()) :: {binary(), map()}
  def put(pastes, text) do
    n = if pastes == %{}, do: 1, else: Enum.max(Map.keys(pastes)) + 1
    {placeholder(n, lines(text)), Map.put(pastes, n, text)}
  end

  @spec references(binary(), map()) :: MapSet.t()
  def references(text, pastes) do
    Enum.reduce(pastes, MapSet.new(), fn {id, payload}, ids ->
      if :binary.match(text, placeholder(id, lines(payload))) == :nomatch,
        do: ids,
        else: MapSet.put(ids, id)
    end)
  end

  @spec retain(map(), MapSet.t()) :: map()
  def retain(pastes, ids), do: Map.take(pastes, MapSet.to_list(ids))

  @spec admit(map(), binary()) :: {:ok, binary(), map()} | {:error, :paste_capacity}
  def admit(pastes, text) when map_size(pastes) < 64 do
    {marker, next} = put(pastes, text)
    {:ok, marker, next}
  end

  def admit(_pastes, _text), do: {:error, :paste_capacity}

  @doc "Count original literal and marker contributions without copying payloads."
  @spec expanded_bytes(binary(), map()) :: {:ok, non_neg_integer()} | {:error, :too_large}
  def expanded_bytes(text, pastes), do: count(text, index(pastes), 0)

  @doc "Bounded, opaque expansion of every original exact marker."
  @spec expand(binary(), map()) :: {:ok, binary()} | {:error, :too_large}
  def expand(text, pastes) do
    index = index(pastes)
    with {:ok, _bytes} <- count(text, index, 0), do: {:ok, materialize(text, index)}
  end

  @doc "Whether the expanded message is over the 256 KiB bound."
  @spec too_large?(binary(), map()) :: boolean()
  def too_large?(text, pastes), do: expanded_bytes(text, pastes) == {:error, :too_large}

  defp index(pastes) do
    markers = Map.new(pastes, fn {id, payload} -> {placeholder(id, lines(payload)), payload} end)
    pattern = if map_size(markers) == 0, do: nil, else: :binary.compile_pattern(Map.keys(markers))
    {pattern, markers}
  end

  defp span(text, {nil, _}), do: {text, "", nil}

  defp span(text, {pattern, markers}) do
    case :binary.match(text, pattern) do
      :nomatch ->
        {text, "", nil}

      {offset, length} ->
        <<literal::binary-size(offset), marker::binary-size(length), rest::binary>> = text
        {literal, rest, Map.fetch!(markers, marker)}
    end
  end

  defp count("", _index, used), do: {:ok, used}

  defp count(text, index, used) do
    {literal, rest, payload} = span(text, index)
    bytes = byte_size(literal)

    cond do
      bytes > @max_message - used -> {:error, :too_large}
      payload == nil -> {:ok, used + bytes}
      byte_size(payload) > @max_message - used - bytes -> {:error, :too_large}
      true -> count(rest, index, used + bytes + byte_size(payload))
    end
  end

  defp materialize(text, index), do: text |> materialize_spans(index, []) |> IO.iodata_to_binary()
  defp materialize_spans("", _index, acc), do: Enum.reverse(acc)

  defp materialize_spans(text, index, acc) do
    {literal, rest, payload} = span(text, index)

    if payload == nil,
      do: Enum.reverse([literal | acc]),
      else: materialize_spans(rest, index, [payload, literal | acc])
  end

  @doc """
  The whole-placeholder deletion a Backspace (`:backward`) or Delete
  (`:forward`) at grapheme `cursor` of `text` makes: `{graphemes, n}` (the
  placeholder's length and its number) or nil.
  """
  @spec deletion(binary(), non_neg_integer(), :backward | :forward, map()) ::
          {pos_integer(), pos_integer()} | nil
  def deletion(_text, _cursor, _direction, pastes) when map_size(pastes) == 0, do: nil

  def deletion(text, cursor, direction, pastes) do
    {before, rest} = text |> String.graphemes() |> Enum.split(cursor)
    before = Enum.join(before)
    rest = Enum.join(rest)

    Enum.find_value(pastes, fn {n, pasted} ->
      words = placeholder(n, lines(pasted))

      hit? =
        case direction do
          :backward -> String.ends_with?(before, words)
          :forward -> String.starts_with?(rest, words)
        end

      if hit?, do: {String.length(words), n}
    end)
  end
end
