defmodule SwarmCodeCLI.UI.Projector.Markdown do
  @moduledoc """
  Markdown for the transcript, laid out to a width in terminal cells.

  `rows/4` turns already-escaped text into rows of `{text, style}` segments.
  Every row fits `width` cells under the given ambiguous-width policy, so the
  caller only maps styles to theme roles and pads. The grammar is what models
  write in a coding answer: `#` headings, paragraphs whose source line breaks
  are kept, `-`/`*`/`+` and numbered lists (nested by indentation, with a
  hanging indent), `>` quotes, `|` tables sized by cells, rules, fenced code on
  a card with a language label and a small tokenizer, and the inline forms
  `**strong**`, `*em*`, `_em_`, `` `code` ``, `[text](url)` and `~~struck~~`.

  Styles are atoms (`:text`, `:strong`, `:em`, `:strong_em`, `:code`, `:link`,
  `:url`, `:heading`, `:subheading`, `:bullet`, `:quote_rail`, `:quote`,
  `:rule`, `:table_head`, `:code_lang`, `:code_text`, `:muted`) or
  `{:syntax, kind}` for code tokens (see `SwarmCodeCLI.UI.Projector.Syntax`).
  A row's `fill` names the style its unused cells are painted in: `:code_card`
  for the rows of a code block, `nil` otherwise.
  """
  alias SwarmCodeCLI.UI.Width
  alias SwarmCodeCLI.UI.Projector.Syntax

  @type style :: atom() | {:syntax, atom()}
  @type segment :: {binary(), style()}
  @type row :: %{segments: [segment()], fill: nil | :code_card}

  # A source line longer than this is laid out as plain text: the inline
  # scanner is linear, but a pathological line should not pay for it on every
  # frame.
  @inline_bytes 16_384
  @code_pad 1

  @spec rows(binary(), pos_integer(), :narrow | :wide, keyword()) :: [row()]
  def rows(text, width, policy, opts \\ [])
      when is_binary(text) and is_integer(width) and width > 0 do
    ascii? = Keyword.get(opts, :ascii?, false)
    ctx = %{width: width, policy: policy, ascii?: ascii?}

    text
    |> String.split(["\r\n", "\n"])
    |> blocks([])
    |> Enum.flat_map(&block_rows(&1, ctx))
    |> trim_blank_edges()
  end

  # --- block grammar ------------------------------------------------------------

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest], acc) do
    trimmed = String.trim_leading(line)

    cond do
      fence = fence_marker(trimmed) ->
        {code, rest} = take_fence(rest, fence, [])
        language = trimmed |> binary_part(3, byte_size(trimmed) - 3) |> String.trim()
        language = language |> String.split(" ", parts: 2) |> hd()
        blocks(rest, [{:code, language, code} | acc])

      table_start?(line, rest) ->
        {rows, rest} = Enum.split_while(rest, &table_line?/1)
        [_separator | body] = rows

        blocks(rest, [{:table, cells(line), alignments(hd(rows)), Enum.map(body, &cells/1)} | acc])

      trimmed == "" ->
        blocks(rest, [:blank | acc])

      rule?(trimmed) ->
        blocks(rest, [:rule | acc])

      match = Regex.run(~r/^(\#{1,6})\s+(.*?)\s*#*\s*$/u, trimmed, capture: :all_but_first) ->
        [marks, content] = match
        blocks(rest, [{:heading, byte_size(marks), content} | acc])

      String.starts_with?(trimmed, ">") ->
        content = trimmed |> String.trim_leading(">") |> String.trim_leading()
        blocks(rest, [{:quote, content} | acc])

      item = list_item(line) ->
        blocks(rest, [item | acc])

      true ->
        blocks(rest, [{:line, line} | acc])
    end
  end

  defp fence_marker("```" <> _), do: "```"
  defp fence_marker("~~~" <> _), do: "~~~"
  defp fence_marker(_), do: nil

  defp take_fence([], _fence, acc), do: {Enum.reverse(acc), []}

  defp take_fence([line | rest], fence, acc) do
    if String.trim(line) |> String.starts_with?(fence) and String.trim(line) |> only?(fence),
      do: {Enum.reverse(acc), rest},
      else: take_fence(rest, fence, [line | acc])
  end

  defp only?(line, fence), do: String.trim_trailing(line, String.first(fence)) == ""

  # A rule is a short line of marks; a long run of them is text to show, not
  # a separator to swallow it.
  defp rule?(line) when byte_size(line) > 120, do: false
  defp rule?(line), do: Regex.match?(~r/^([-*_])(\s*\1){2,}\s*$/, line)

  defp table_start?(line, [next | _]),
    do:
      table_line?(line) and
        Regex.match?(~r/^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/, next)

  defp table_start?(_line, []), do: false

  defp table_line?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "|") and
      String.contains?(binary_part(trimmed, 1, byte_size(trimmed) - 1), "|")
  end

  defp cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp alignments(separator) do
    separator
    |> cells()
    |> Enum.map(fn cell ->
      case {String.starts_with?(cell, ":"), String.ends_with?(cell, ":")} do
        {true, true} -> :center
        {false, true} -> :right
        _ -> :left
      end
    end)
  end

  defp list_item(line) do
    case Regex.run(~r/^(\s*)([-*+]|\d{1,4}[.)])\s+(.*)$/u, line, capture: :all_but_first) do
      [indent, marker, content] ->
        level = min(div(String.length(indent), 2), 4)

        kind =
          if marker in ["-", "*", "+"],
            do: :bullet,
            else: {:number, String.trim_trailing(marker, ".") |> String.trim_trailing(")")}

        # A task list item keeps its box as text: "[x] done" reads as done.
        {:item, level, kind, content}

      nil ->
        nil
    end
  end

  # --- block layout ---------------------------------------------------------------

  defp block_rows(:blank, _ctx), do: [blank()]

  defp block_rows(:rule, ctx),
    do: [row([{String.duplicate(hairline(ctx), min(ctx.width, 48)), :rule}])]

  defp block_rows({:heading, level, content}, ctx) do
    style = if level <= 2, do: :heading, else: :subheading

    content
    |> inline(style)
    |> wrap(ctx.width, [], [], ctx.policy)
  end

  defp block_rows({:line, line}, ctx) do
    # Source indentation is kept as a hanging indent, so an indented
    # continuation of a list item stays under its text.
    indent = line |> String.length() |> Kernel.-(String.length(String.trim_leading(line)))
    indent = min(indent, div(ctx.width, 2))
    pad = if indent > 0, do: [{String.duplicate(" ", indent), :text}], else: []

    line
    |> String.trim_leading()
    |> inline(:text)
    |> wrap(ctx.width, pad, pad, ctx.policy)
  end

  defp block_rows({:quote, content}, ctx) do
    rail = [{rail(ctx) <> " ", :quote_rail}]

    content
    |> inline(:quote)
    |> wrap(ctx.width, rail, rail, ctx.policy)
  end

  defp block_rows({:item, level, kind, content}, ctx) do
    indent = String.duplicate(" ", level * 2)

    marker =
      case kind do
        :bullet -> bullet(level, ctx) <> " "
        {:number, n} -> n <> ". "
      end

    style = if kind == :bullet, do: :bullet, else: :number
    first = [{indent, :text}, {marker, style}]
    rest = [{indent <> String.duplicate(" ", Width.cells(marker, ctx.policy)), :text}]

    content
    |> inline(:text)
    |> wrap(ctx.width, first, rest, ctx.policy)
  end

  defp block_rows({:code, language, lines}, ctx) do
    inner = max(1, ctx.width - @code_pad * 2)
    pad = {String.duplicate(" ", @code_pad), :code_text}
    label = if language == "", do: "code", else: language

    header = %{segments: [pad, {label, :code_lang}], fill: :code_card}

    body =
      lines
      |> Syntax.lines(language)
      |> Enum.flat_map(fn tokens ->
        tokens
        |> code_wrap(inner, ctx.policy)
        |> Enum.map(fn segments -> %{segments: [pad | segments], fill: :code_card} end)
      end)

    [header | body]
  end

  defp block_rows({:table, header, aligns, body}, ctx), do: table(header, aligns, body, ctx)

  # --- tables -----------------------------------------------------------------------

  @gap 2

  defp table(header, aligns, body, ctx) do
    columns = max(length(header), body |> Enum.map(&length/1) |> Enum.max(fn -> 0 end))
    header = pad_cells(header, columns)
    body = Enum.map(body, &pad_cells(&1, columns))
    aligns = aligns |> pad_cells(columns) |> Enum.map(&if(&1 == "", do: :left, else: &1))

    rendered_header = Enum.map(header, &inline(&1, :table_head))
    rendered_body = Enum.map(body, fn cells -> Enum.map(cells, &inline(&1, :text)) end)

    natural =
      [rendered_header | rendered_body]
      |> Enum.map(fn cells -> Enum.map(cells, &segments_cells(&1, ctx.policy)) end)
      |> Enum.zip_with(& &1)
      |> Enum.map(&Enum.max/1)

    widths = fit_columns(natural, ctx.width - @gap * (columns - 1))

    rule =
      widths
      |> Enum.map(&{String.duplicate(hairline(ctx), &1), :rule})
      |> Enum.intersperse({String.duplicate(" ", @gap), :text})

    [table_row(rendered_header, widths, aligns, ctx), row(rule)] ++
      Enum.map(rendered_body, &table_row(&1, widths, aligns, ctx))
  end

  defp pad_cells(cells, columns), do: cells ++ List.duplicate("", max(0, columns - length(cells)))

  # Columns keep their natural width while the table fits; otherwise the
  # widest give way first, never below four cells.
  defp fit_columns(natural, available) do
    if Enum.sum(natural) <= available or available <= 0 do
      natural
    else
      shrink(natural, Enum.sum(natural) - max(available, length(natural) * 4))
    end
  end

  defp shrink(widths, excess) when excess <= 0, do: widths

  defp shrink(widths, excess) do
    widest = Enum.max(widths)

    if widest <= 4 do
      widths
    else
      index = Enum.find_index(widths, &(&1 == widest))
      shrink(List.update_at(widths, index, &(&1 - 1)), excess - 1)
    end
  end

  defp table_row(cells, widths, aligns, ctx) do
    cells
    |> Enum.zip(widths)
    |> Enum.zip(aligns)
    |> Enum.map(fn {{segments, width}, align} -> cell(segments, width, align, ctx.policy) end)
    |> Enum.intersperse([{String.duplicate(" ", @gap), :text}])
    |> List.flatten()
    |> row()
  end

  defp cell(segments, width, align, policy) do
    clipped = clip(segments, width, policy)
    used = segments_cells(clipped, policy)
    free = max(0, width - used)

    {left, right} =
      case align do
        :right -> {free, 0}
        :center -> {div(free, 2), free - div(free, 2)}
        :left -> {0, free}
      end

    spaces(left) ++ clipped ++ spaces(right)
  end

  defp spaces(0), do: []
  defp spaces(n), do: [{String.duplicate(" ", n), :text}]

  # Cuts segments to `width` cells, ending in an ellipsis when anything is lost.
  defp clip(segments, width, policy) do
    if segments_cells(segments, policy) <= width do
      segments
    else
      take(segments, max(0, width - 1), policy, []) ++ [{"…", :muted}]
    end
  end

  defp take([], _left, _policy, acc), do: Enum.reverse(acc)

  defp take([{text, style} | rest], left, policy, acc) do
    cells = Width.cells(text, policy)

    if cells <= left do
      take(rest, left - cells, policy, [{text, style} | acc])
    else
      {head, _tail, _used} = Width.take_cells(text, left, policy)
      Enum.reverse(if(head == "", do: acc, else: [{head, style} | acc]))
    end
  end

  # --- inline grammar -----------------------------------------------------------------

  @doc "Inline markdown of one source line as styled segments, markers removed."
  @spec inline(binary(), style()) :: [segment()]
  def inline(text, base) when byte_size(text) > @inline_bytes, do: [{text, base}]
  def inline(text, base), do: text |> scan(base, "", []) |> merge()

  @specials ["`", "*", "_", "~", "["]

  defp scan("", base, literal, acc), do: Enum.reverse(flush(literal, base, acc))

  defp scan(text, base, literal, acc) do
    case text |> marked(literal, base) |> whole_clusters() do
      {segments, rest} ->
        scan(rest, base, "", Enum.reverse(segments) ++ flush(literal, base, acc))

      nil ->
        # Markers are ASCII, so cutting before one never splits a UTF-8
        # sequence; the byte at 0 is consumed so a lone marker makes progress.
        case :binary.match(text, @specials, scope: {1, byte_size(text) - 1}) do
          :nomatch ->
            scan("", base, literal <> text, acc)

          {at, _} ->
            scan(
              binary_part(text, at, byte_size(text) - at),
              base,
              literal <> binary_part(text, 0, at),
              acc
            )
        end
    end
  end

  # A marker next to a combining mark is part of that character, not markup:
  # cutting there would leave the mark alone at the start of a segment.
  defp whole_clusters(nil), do: nil

  defp whole_clusters({segments, rest} = marked) do
    starts = [rest | Enum.map(segments, &elem(&1, 0))]
    if Enum.any?(starts, &Regex.match?(~r/^\p{M}/u, &1)), do: nil, else: marked
  end

  defp flush("", _base, acc), do: acc
  defp flush(literal, base, acc), do: [{literal, base} | acc]

  defp marked("`" <> _ = text, _before, _base) do
    ticks = if String.starts_with?(text, "``"), do: "``", else: "`"
    tail = binary_part(text, byte_size(ticks), byte_size(text) - byte_size(ticks))

    case :binary.match(tail, ticks) do
      {at, len} when at > 0 ->
        code = tail |> binary_part(0, at) |> String.trim()
        {[{code, :code}], binary_part(tail, at + len, byte_size(tail) - at - len)}

      _ ->
        nil
    end
  end

  defp marked("**" <> _ = text, _before, base), do: enclosed(text, "**", strong(base))
  defp marked("__" <> _ = text, before, base), do: word_enclosed(text, "__", strong(base), before)
  defp marked("~~" <> _ = text, _before, _base), do: enclosed(text, "~~", :muted)

  defp marked("*" <> rest = text, _before, base) do
    if rest != "" and not String.starts_with?(rest, " "), do: enclosed(text, "*", em(base))
  end

  defp marked("_" <> _ = text, before, base), do: word_enclosed(text, "_", em(base), before)

  defp marked("[" <> rest, _before, _base) do
    with {close, 1} <- :binary.match(rest, "]"),
         label = binary_part(rest, 0, close),
         after_label = binary_part(rest, close + 1, byte_size(rest) - close - 1),
         "(" <> target <- after_label,
         {paren, 1} <- :binary.match(target, ")") do
      url = binary_part(target, 0, paren)
      remaining = binary_part(target, paren + 1, byte_size(target) - paren - 1)

      segments =
        if label == url or label == "",
          do: [{url, :link}],
          else: [{label, :link}, {" " <> url, :url}]

      {segments, remaining}
    else
      _ -> nil
    end
  end

  defp marked(_text, _before, _base), do: nil

  defp enclosed(text, marker, style) do
    size = byte_size(marker)
    tail = binary_part(text, size, byte_size(text) - size)

    case :binary.match(tail, marker) do
      {at, len} when at > 0 ->
        inner = binary_part(tail, 0, at)

        if String.ends_with?(inner, " "),
          do: nil,
          else:
            {inline_nested(inner, style), binary_part(tail, at + len, byte_size(tail) - at - len)}

      _ ->
        nil
    end
  end

  # `_` and `__` only open at a word boundary and only close before one, so
  # snake_case names and paths are never read as emphasis.
  defp word_enclosed(text, marker, style, before) do
    if boundary?(last_grapheme(before)) do
      size = byte_size(marker)
      tail = binary_part(text, size, byte_size(text) - size)
      close(tail, marker, style, 0)
    end
  end

  defp close(tail, marker, style, from) do
    size = byte_size(tail)

    case :binary.match(tail, marker, scope: {from, size - from}) do
      {at, len} when at > 0 ->
        after_marker = binary_part(tail, at + len, size - at - len)
        inner = binary_part(tail, 0, at)

        cond do
          String.starts_with?(inner, " ") or String.ends_with?(inner, " ") ->
            nil

          boundary?(String.first(after_marker)) ->
            {inline_nested(inner, style), after_marker}

          true ->
            close(tail, marker, style, at + len)
        end

      _ ->
        nil
    end
  end

  defp boundary?(nil), do: true
  defp boundary?(grapheme), do: not Regex.match?(~r/^[\p{L}\p{N}_]$/u, grapheme)

  defp last_grapheme(""), do: nil
  defp last_grapheme(text), do: String.last(text)

  defp inline_nested(inner, style) do
    inner
    |> scan(style, "", [])
    |> Enum.map(fn
      {text, :code} -> {text, :code}
      {text, :link} -> {text, :link}
      {text, :url} -> {text, :url}
      {text, other} -> {text, combine(style, other)}
    end)
  end

  defp combine(outer, inner) when outer == inner, do: outer

  defp combine(outer, inner) when {outer, inner} in [{:strong, :em}, {:em, :strong}],
    do: :strong_em

  defp combine(_outer, inner), do: inner

  defp strong(:em), do: :strong_em
  defp strong(:heading), do: :heading
  defp strong(:subheading), do: :subheading
  defp strong(:table_head), do: :table_head
  defp strong(_), do: :strong

  defp em(:strong), do: :strong_em
  defp em(:quote), do: :quote
  defp em(_), do: :em

  defp merge(segments) do
    segments
    |> Enum.reject(fn {text, _} -> text == "" end)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_, style} | _] = group -> {Enum.map_join(group, &elem(&1, 0)), style} end)
  end

  # --- wrapping --------------------------------------------------------------------------

  # Greedy word wrap of styled segments. `first` leads the first row and
  # `rest` every continuation row, so list items and quotes hang.
  defp wrap(segments, width, first, rest, policy) do
    first_cells = segments_cells(first, policy)
    rest_cells = segments_cells(rest, policy)

    pieces =
      Enum.flat_map(segments, fn {text, style} ->
        text
        |> String.split(~r/( +)/u, include_captures: true, trim: true)
        |> Enum.map(&{&1, style})
      end)

    {rows, current, _used} =
      Enum.reduce(pieces, {[], first, first_cells}, fn {text, style}, {rows, current, used} ->
        cells = Width.cells(text, policy)
        limit = width
        leading = if rows == [], do: first_cells, else: rest_cells

        cond do
          String.trim(text) == "" and used == leading ->
            {rows, current, used}

          used + cells <= limit ->
            {rows, current ++ [{text, style}], used + cells}

          String.trim(text) == "" ->
            {[current | rows], rest, rest_cells}

          cells <= limit - rest_cells ->
            {[current | rows], rest ++ [{text, style}], rest_cells + cells}

          true ->
            split_word(text, style, rows, current, used, limit, rest, rest_cells, policy)
        end
      end)

    [current | rows]
    |> Enum.reverse()
    |> Enum.map(&row(trim_trailing_space(&1)))
  end

  # A word wider than the row is cut into row-sized pieces.
  defp split_word(text, style, rows, current, used, limit, rest, rest_cells, policy) do
    room = limit - used

    if room <= 0 do
      split_word(text, style, [current | rows], rest, rest_cells, limit, rest, rest_cells, policy)
    else
      {head, tail, head_cells} = Width.take_cells(text, room, policy)

      cond do
        head == "" and used == rest_cells ->
          # Not even one grapheme fits an empty row: keep it whole.
          {rows, current ++ [{text, style}], used + Width.cells(text, policy)}

        head == "" ->
          split_word(
            text,
            style,
            [current | rows],
            rest,
            rest_cells,
            limit,
            rest,
            rest_cells,
            policy
          )

        tail == "" ->
          {rows, current ++ [{head, style}], used + head_cells}

        true ->
          split_word(
            tail,
            style,
            [current ++ [{head, style}] | rows],
            rest,
            rest_cells,
            limit,
            rest,
            rest_cells,
            policy
          )
      end
    end
  end

  defp trim_trailing_space(segments) do
    case List.last(segments) do
      {text, style} ->
        case String.trim_trailing(text, " ") do
          "" when length(segments) > 1 -> trim_trailing_space(Enum.drop(segments, -1))
          trimmed -> List.replace_at(segments, -1, {trimmed, style})
        end

      nil ->
        segments
    end
  end

  # Code keeps its spacing and wraps at the cell, continuing on the next row.
  defp code_wrap([], _width, _policy), do: [[]]

  defp code_wrap(tokens, width, policy) do
    {rows, current, _used} =
      Enum.reduce(tokens, {[], [], 0}, fn {text, kind}, acc ->
        code_token(text, kind, acc, width, policy)
      end)

    Enum.reverse([current | rows])
  end

  defp code_token("", _kind, acc, _width, _policy), do: acc

  defp code_token(text, kind, {rows, current, used}, width, policy) do
    cells = Width.cells(text, policy)

    if used + cells <= width do
      {rows, current ++ [{text, {:syntax, kind}}], used + cells}
    else
      {head, tail, head_cells} = Width.take_cells(text, max(0, width - used), policy)

      if head == "" and used == 0 do
        {[[{text, {:syntax, kind}}] | rows], [], 0}
      else
        current = if head == "", do: current, else: current ++ [{head, {:syntax, kind}}]
        _ = head_cells
        code_token(tail, kind, {[current | rows], [], 0}, width, policy)
      end
    end
  end

  # --- helpers -----------------------------------------------------------------------------

  defp row(segments), do: %{segments: segments, fill: nil}
  defp blank, do: %{segments: [], fill: nil}

  defp trim_blank_edges(rows) do
    rows
    |> Enum.drop_while(&(&1.segments == [] and &1.fill == nil))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.segments == [] and &1.fill == nil))
    |> Enum.reverse()
    |> collapse_blanks()
  end

  defp collapse_blanks(rows) do
    rows
    |> Enum.chunk_while(
      nil,
      fn row, previous ->
        if blank?(row) and previous != nil and blank?(previous),
          do: {:cont, previous},
          else: if(previous, do: {:cont, previous, row}, else: {:cont, row})
      end,
      fn
        nil -> {:cont, nil}
        last -> {:cont, last, nil}
      end
    )
  end

  defp blank?(%{segments: [], fill: nil}), do: true
  defp blank?(_), do: false

  @doc "Cells a list of segments occupies."
  def segments_cells(segments, policy),
    do: Enum.reduce(segments, 0, fn {text, _}, sum -> sum + Width.cells(text, policy) end)

  @doc "A one-cell horizontal line for the policy: `─` where it is narrow, `╌` otherwise."
  def hairline(%{ascii?: true}), do: "-"
  def hairline(%{policy: policy}), do: if(Width.cells("─", policy) == 1, do: "─", else: "╌")

  defp rail(%{ascii?: true}), do: "|"
  defp rail(_ctx), do: "▐"

  defp bullet(_level, %{ascii?: true}), do: "-"
  defp bullet(0, %{policy: policy}), do: if(Width.cells("•", policy) == 1, do: "•", else: "∙")
  defp bullet(1, _ctx), do: "◦"
  defp bullet(_level, _ctx), do: "▪"
end
