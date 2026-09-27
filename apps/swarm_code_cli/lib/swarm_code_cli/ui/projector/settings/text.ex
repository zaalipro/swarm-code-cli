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

  @doc """
  `segments` word-wrapped to `width` cells with their roles kept across the
  breaks. Words split on single spaces; a space never starts a line and
  trailing spaces are dropped; a word wider than a line starts its own line
  and is split at `width` cells, never cut with `…`.
  """
  @spec wrap_segments(map(), [segment()], pos_integer()) :: [[segment()]]
  def wrap_segments(state, segments, width) do
    {done, current, _used} =
      segments
      |> Enum.flat_map(fn {text, role} ->
        text
        |> to_string()
        |> String.split(~r/( )/, include_captures: true, trim: true)
        |> Enum.map(&{&1, role})
      end)
      |> Enum.reduce({[], [], 0}, &place(state, &1, width, &2))

    [current | done]
    |> Enum.reverse()
    |> Enum.map(&finish_line/1)
  end

  defp place(_state, {" ", _}, _width, {done, [], 0}), do: {done, [], 0}

  defp place(state, {" ", _} = token, width, {done, current, used}) do
    size = text_cells(state, " ")

    if used + size <= width,
      do: {done, [token | current], used + size},
      else: {[current | done], [], 0}
  end

  defp place(state, {word, role} = token, width, {done, current, used}) do
    size = text_cells(state, word)

    cond do
      used + size <= width ->
        {done, [token | current], used + size}

      size <= width ->
        {[current | done], [token], size}

      true ->
        done = if current == [], do: done, else: [current | done]
        [{last, last_size} | full] = state |> split_cells(word, width) |> Enum.reverse()
        full_lines = Enum.map(full, fn {chunk, _} -> [{chunk, role}] end)
        {full_lines ++ done, [{last, role}], last_size}
    end
  end

  # A word split into chunks of at most `width` cells (at least one grapheme each).
  defp split_cells(state, word, width) do
    {chunks, chunk, used} =
      word
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn grapheme, {chunks, chunk, used} ->
        size = text_cells(state, grapheme)

        if used + size > width and chunk != "",
          do: {[{chunk, used} | chunks], grapheme, size},
          else: {chunks, chunk <> grapheme, used + size}
      end)

    Enum.reverse([{chunk, used} | chunks])
  end

  defp finish_line(reversed) do
    reversed
    |> Enum.drop_while(fn {text, _} -> text == " " end)
    |> Enum.reverse()
    |> Enum.chunk_by(fn {_, role} -> role end)
    |> Enum.map(fn [{_, role} | _] = run -> {Enum.map_join(run, &elem(&1, 0)), role} end)
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
  # The focus band: a pseudo-background drawn as the accent chip's background,
  # or as reverse video where there is no background colour to spend.
  def style(%{capabilities: caps} = state, {inner, :on, :band}) do
    base = style(state, inner)

    if caps.color_mode in [:truecolor, :ansi256],
      do: %{base | background: Theme.style(:chip_accent, caps).background},
      else: %{base | modifiers: Enum.uniq(base.modifiers ++ [:reversed])}
  end

  # 16 colours and NO_COLOR drop the hover, surface and popover fills.
  def style(%{capabilities: %{color_mode: mode}} = state, {inner, :on, bg})
      when bg in [:hover, :surface, :popover] and mode in [:ansi16, :monochrome],
      do: style(state, inner)

  def style(state, {role, :on, background}) do
    base = style(state, role)

    case Theme.style(background, state.capabilities) do
      # NO_COLOR and 16 colours draw the selection as reverse video (§4.11),
      # not as a background colour; a picker's or a confirmation's focused
      # line lost it and read like the others.
      %{background: nil, modifiers: modifiers} ->
        %{base | modifiers: Enum.uniq(base.modifiers ++ (modifiers -- [:dim]))}

      %{background: color} ->
        %{base | background: color}
    end
  end

  def style(state, {role, modifiers}) when is_list(modifiers) do
    base = style(state, role)
    %{base | modifiers: Enum.uniq(modifiers ++ (base.modifiers -- [:dim]))}
  end

  # Roles that vanish on a slate desk draw as the faintest readable text.
  def style(state, role) when role in [:text_ghost, :border, :border_soft, :ticks_track],
    do: style(state, :text_faint)

  def style(%{capabilities: %{color_mode: :monochrome} = caps}, role) do
    themed = Theme.style(role, caps)

    modifiers =
      cond do
        role in [:text_muted, :text_faint, :text_ghost, :border] -> [:dim]
        role in [:warning, :error, :accent, :focus] -> [:bold]
        role in [:selection] -> [:reversed]
        true -> []
      end

    base = %{themed | prefix: nil, modifiers: Enum.uniq(modifiers ++ themed.modifiers)}

    # The painter puts a role's words (`FOCUS >`, `! WAITING`, `[INFO]`) before every
    # span of that role in monochrome. Settings rows carry their own marks and are
    # measured without those words, so such a role paints as primary text with the
    # same modifiers (NO_COLOR has no colour to lose).
    if themed.prefix, do: %{base | role: :text_primary}, else: base
  end

  def style(state, role), do: %{Theme.style(role, state.capabilities) | prefix: nil}

  @doc "Puts every segment of a row on the selection background."
  @spec select([segment()]) :: [segment()]
  def select(segments),
    do: Enum.map(segments, fn {text, role} -> {text, on(role, :selection)} end)

  @doc "Puts every segment of a row on the focus band (`style/2` resolves `:band`)."
  @spec band([segment()]) :: [segment()]
  def band(segments), do: Enum.map(segments, fn {text, role} -> {text, on(role, :band)} end)

  @doc "Every segment drawn faint (a popover's scrim); a background wrapper is kept."
  @spec scrim([segment()]) :: [segment()]
  def scrim(segments) do
    Enum.map(segments, fn
      {text, {_, :on, background}} -> {text, {:text_faint, :on, background}}
      {text, _} -> {text, :text_faint}
    end)
  end

  defp on({role, :on, _}, background), do: {role, :on, background}

  defp on({_role, modifiers} = spec, background) when is_list(modifiers),
    do: {spec, :on, background}

  defp on(role, background), do: {role, :on, background}

  @doc false
  def safe_value(%SafeText{} = text), do: SafeText.value(text)
end
