defmodule SwarmCodeCLI.UI.Draft.Pastes do
  @moduledoc """
  cli020 D8 (ux-live-16, decision 4e): a large bracketed paste collapses to
  one placeholder in the draft, `[Pasted text #N · L lines]`, and its text
  waits in the draft's `pastes` map (`%{N => text}`, N from 1 per draft).

  On send every placeholder still present verbatim is replaced by its text
  (`expand/2`); one the user edited is sent as typed. Backspace or Delete
  next to a whole placeholder removes it at once (`deletion/3`), and the
  entry goes with it. A paste collapses when `paste_collapse_lines`
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

  @doc "The text to send: every placeholder still present is its text again."
  @spec expand(binary(), map()) :: binary()
  def expand(text, pastes) when map_size(pastes) == 0, do: text

  def expand(text, pastes) do
    Enum.reduce(Enum.sort(pastes), text, fn {n, pasted}, acc ->
      String.replace(acc, placeholder(n, lines(pasted)), pasted, global: false)
    end)
  end

  @doc "Whether the expanded message is over the 256 KiB bound."
  @spec too_large?(binary(), map()) :: boolean()
  def too_large?(text, pastes), do: byte_size(expand(text, pastes)) > @max_message

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
