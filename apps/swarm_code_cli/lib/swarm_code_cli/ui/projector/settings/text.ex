defmodule SwarmCodeCLI.UI.Projector.Settings.Text do
  @moduledoc """
  Cell arithmetic for the settings projector: segments (`[{text, role}]`)
  measured, clipped, padded, spread left/right, spliced over each other and
  word-wrapped under the terminal's width policy, and turned into scene
  spans. Every string goes through `Density.safe/3` (control characters
  and width) and, at the ASCII tier, through `Settings.Glyphs.asciify/1`.
  """

  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Projector.Density
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Settings.Glyphs

  @type segment :: {String.t(), atom() | {atom(), [atom()]}}

  @doc "The width of `segments` in cells."
  @spec cells(map(), [segment()]) :: non_neg_integer()
  def cells(state, segments),
    do: segments |> Enum.map(fn {text, _} -> text_cells(state, text) end) |> Enum.sum()

  @doc "The width of one text in cells."
  @spec text_cells(map(), String.t()) :: non_neg_integer()
  def text_cells(state, text),
    do: Width.cells(prepare(state, text), state.capabilities.ambiguous_width)

  @doc "A text as it is drawn: one line, ASCII twins at the ASCII tier."
  @spec prepare(map(), String.t()) :: String.t()
  def prepare(state, text) do
    text = String.replace(to_string(text), ["\r\n", "\n", "\r", "\t"], " ")
    if Glyphs.tier(state.capabilities) == :ascii, do: Glyphs.asciify(text), else: text
  end

  @doc "`segments` cut to `width` cells (the last kept text ends in `…` when cut)."
  @spec clip(map(), [segment()], non_neg_integer()) :: [segment()]
  def clip(state, segments, width) do
    {kept, _used} =
      Enum.reduce(segments, {[], 0}, fn {text, role}, {acc, used} ->
        text = prepare(state, text)
        room = width - used
        size = Width.cells(text, state.capabilities.ambiguous_width)

        cond do
          room <= 0 or text == "" -> {acc, used}
          size <= room -> {[{text, role} | acc], used + size}
          true -> {[{cut(state, text, room), role} | acc], width}
        end
      end)

    Enum.reverse(kept)
  end

  defp cut(state, text, room) do
    ellipsis = Glyphs.get(:ellipsis, Glyphs.tier(state.capabilities))
    keep = max(room - String.length(ellipsis), 0)

    {taken, _} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({"", 0}, fn grapheme, {acc, used} ->
        size = Width.cells(grapheme, state.capabilities.ambiguous_width)

        if used + size > keep,
          do: {:halt, {acc, used}},
          else: {:cont, {acc <> grapheme, used + size}}
      end)

    if room >= String.length(ellipsis), do: taken <> ellipsis, else: taken
  end

  @doc "`segments` clipped and padded to exactly `width` cells."
  @spec fit(map(), [segment()], non_neg_integer()) :: [segment()]
  def fit(state, segments, width) do
    clipped = clip(state, segments, width)
    used = cells(state, clipped)

    if used < width,
      do: clipped ++ [{String.duplicate(" ", width - used), :text_primary}],
      else: clipped
  end

  @doc "`left`, then `right` flush with the right edge; the left gives way first."
  @spec spread(map(), [segment()], [segment()], non_neg_integer()) :: [segment()]
  def spread(state, left, right, width) do
    right = clip(state, right, max(width - 1, 0))
    right_cells = cells(state, right)
    left = clip(state, left, max(width - right_cells - 1, 0))
    gap = width - cells(state, left) - right_cells
    left ++ [{String.duplicate(" ", max(gap, 0)), :text_primary}] ++ right
  end

  @doc "`over` drawn over `under` from cell `column` (both fitted to `width`)."
  @spec splice(map(), [segment()], non_neg_integer(), [segment()], non_neg_integer()) :: [
          segment()
        ]
  def splice(state, under, column, over, width) do
    under = fit(state, under, width)
    over_width = cells(state, over)
    {before, rest} = split_at(state, under, column)
    {_covered, after_} = split_at(state, rest, over_width)
    fit(state, before ++ over ++ after_, width)
  end

  # Segments split at a cell; a wide character across the cut becomes a space.
  defp split_at(state, segments, column) do
    {left, right, _} =
      Enum.reduce(segments, {[], [], 0}, fn {text, role}, {left, right, used} ->
        size = Width.cells(text, state.capabilities.ambiguous_width)

        cond do
          used >= column ->
            {left, [{text, role} | right], used + size}

          used + size <= column ->
            {[{text, role} | left], right, used + size}

          true ->
            {a, b} = split_text(state, text, column - used)
            {[{a, role} | left], [{b, role} | right], used + size}
        end
      end)

    {Enum.reverse(left), Enum.reverse(right)}
  end

  defp split_text(state, text, room) do
    {a, b, _} =
      text
      |> String.graphemes()
      |> Enum.reduce({"", "", 0}, fn grapheme, {a, b, used} ->
        size = Width.cells(grapheme, state.capabilities.ambiguous_width)

        cond do
          b != "" -> {a, b <> grapheme, used}
          used + size <= room -> {a <> grapheme, b, used + size}
          used < room -> {a <> " ", " ", room}
          true -> {a, grapheme, used}
        end
      end)

    {a, b}
  end

  @doc "`text` word-wrapped to `width` cells (a word longer than a line is cut)."
  @spec wrap(map(), String.t(), pos_integer()) :: [String.t()]
  def wrap(_state, "", _width), do: [""]

  def wrap(state, text, width) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce([], fn word, lines ->
      case lines do
        [] ->
          [word]

        [line | rest] ->
          candidate = line <> " " <> word

          if text_cells(state, candidate) <= width,
            do: [candidate | rest],
            else: [word, line | rest]
      end
    end)
    |> Enum.reverse()
    |> case do
      [] -> [""]
      lines -> lines
    end
  end

  @doc "One screen row of `segments`, exactly `width` cells."
  @spec row(map(), [segment()], non_neg_integer()) :: Block.RichText.t()
  def row(state, segments, width) do
    spans =
      state
      |> fit(segments, width)
      |> Enum.reject(fn {text, _} -> text == "" end)
      |> Enum.map(fn {text, role} ->
        %Span{
          text: Density.safe(text, state, max(text_cells(state, text), 1)),
          style: style(state, role)
        }
      end)

    spans =
      if spans == [],
        do: [%Span{text: Density.safe(" ", state, 1), style: style(state, :text_primary)}],
        else: spans

    %Block.RichText{spans: spans}
  end

  @doc "The style of a role; `{role, modifiers}` adds modifiers, `{role, :on, background}` a background."
  @spec style(map(), term()) :: map()
  def style(state, {role, :on, background}) do
    base = style(state, role)
    %{base | background: Theme.style(background, state.capabilities).background}
  end

  def style(state, {role, modifiers}) when is_list(modifiers) do
    base = style(state, role)
    %{base | modifiers: Enum.uniq(modifiers ++ (base.modifiers -- [:dim]))}
  end

  def style(%{capabilities: %{color_mode: :monochrome} = caps}, role) do
    base = %{Theme.style(role, caps) | prefix: nil}

    modifiers =
      cond do
        role in [:text_muted, :text_faint, :text_ghost, :border] -> [:dim]
        role in [:warning, :error, :accent, :focus] -> [:bold]
        role in [:selection] -> [:reverse]
        true -> []
      end

    %{base | modifiers: Enum.uniq(modifiers ++ base.modifiers)}
  end

  def style(state, role), do: %{Theme.style(role, state.capabilities) | prefix: nil}

  @doc "Puts every segment of a row on the selection background."
  @spec select([segment()]) :: [segment()]
  def select(segments),
    do: Enum.map(segments, fn {text, role} -> {text, on(role, :selection)} end)

  defp on({role, :on, _}, background), do: {role, :on, background}
  defp on({role, modifiers}, background) when is_list(modifiers), do: {role, :on, background}
  defp on(role, background), do: {role, :on, background}

  @doc false
  def safe_value(%SafeText{} = text), do: SafeText.value(text)
end
