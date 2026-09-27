defmodule SwarmCodeCLI.UI.Paint.Scene do
  @moduledoc false
  alias SwarmCodeCLI.UI.{Scene, SafeText, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Rect, Style}
  alias SwarmCodeCLI.UI.Paint.{Blocks, Canvas, Plan}
  alias SwarmCodeCLI.UI.Paint.Style, as: PaintStyle

  def paint(%Scene{} = scene, options) do
    base = %{foreground: nil, background: nil, modifiers: []}
    base = resolve(:canvas, base, options)
    base = resolve(:text_primary, base, options)
    {:ok, canvas} = Canvas.new(scene.size, 0)

    ctx = %{
      canvas: canvas,
      lookup: %{base => 0},
      entries: [base],
      options: options,
      policy: scene.ambiguous_width,
      base: base,
      size: scene.size
    }

    ctx = Enum.reduce(scene.regions, ctx, &region/2)
    ctx = if scene.overlay, do: dialog(scene.overlay, ctx), else: ctx
    expected = action_ids(scene.overlay || scene.regions) |> Enum.uniq() |> Enum.sort()
    actions = Canvas.actions(ctx.canvas) |> Map.take(expected)

    plan = %Plan{
      revision: scene.revision,
      size: scene.size,
      ambiguous_width: scene.ambiguous_width,
      color_mode: options.color_mode,
      cells: Canvas.finish(ctx.canvas),
      palette: ctx.entries |> Enum.reverse() |> List.to_tuple(),
      cursor: if(scene.overlay, do: nil, else: scene.cursor),
      focus: focus(scene),
      actions: actions,
      diagnostics: for(id <- expected, not Map.has_key?(actions, id), do: {:clipped_action, id})
    }

    {:ok, plan}
  catch
    {:paint, reason} -> {:error, reason}
  end

  defp region(%{rect: %{width: width, height: height}}, ctx) when width == 0 or height == 0,
    do: ctx

  defp region(region, ctx) do
    # pass 75 R7.7 (QA-1): the docked side panel has no fill; the blank gap
    # column is its edge (the hairline stays in monochrome).
    style =
      if region.role == :navigator,
        do: resolve(:surface, ctx.base, ctx.options),
        else: ctx.base

    ctx = fill(ctx, region.rect, style)

    # Paint gap-column hairline for navigator and inspector docks
    ctx = hairline(region, ctx, style)

    {ctx, rect} =
      if region.role == :navigator do
        heading =
          if region.focus == :active do
            resolve(:focus, style, ctx.options)
          else
            resolved = resolve(:text_faint, style, ctx.options)
            %{resolved | modifiers: [:bold]}
          end

        label = [%Block.Text{text: region.label}]

        {layout(label, %{region.rect | height: 1}, heading, ctx),
         %{region.rect | y: region.rect.y + 1, height: region.rect.height - 1}}
      else
        {ctx, region.rect}
      end

    layout(region.blocks, rect, style, ctx)
  end

  defp dialog(%{rect: %{width: width, height: height}}, ctx) when width == 0 or height == 0,
    do: ctx

  # pass75 interview: the note. Everything behind it steps back to the ghost
  # colour, one cell of air is cleared around it, and it is drawn without a
  # fill in a rounded faint frame whose edges carry its words.
  defp dialog(%{style: :note} = dialog, ctx) do
    rect = dialog.rect
    %{columns: columns, rows: rows} = ctx.size

    ctx =
      if dialog.backdrop == :ghost and ctx.options.color_mode != :monochrome,
        do: ghost(ctx, %Rect{x: 0, y: 0, width: columns, height: rows}),
        else: ctx

    ctx =
      if dialog.air do
        x = max(rect.x - 1, 0)
        y = max(rect.y - 1, 0)

        fill(
          ctx,
          %Rect{
            x: x,
            y: y,
            width: min(rect.x + rect.width + 1, columns) - x,
            height: min(rect.y + rect.height + 1, rows) - y
          },
          ctx.base
        )
      else
        fill(ctx, rect, ctx.base)
      end

    faint = resolve(:text_faint, ctx.base, ctx.options)

    ctx =
      ctx
      |> border(rect, faint, :rounded)
      |> edge(rect, rect.y, dialog.edges.top_left, dialog.edges.top_right, faint)
      |> edge(
        rect,
        rect.y + rect.height - 1,
        dialog.edges.bottom_left,
        dialog.edges.bottom_right,
        faint
      )

    inner = %Rect{
      x: rect.x + min(3, rect.width),
      y: rect.y + min(1, rect.height),
      width: max(0, rect.width - 6),
      height: max(0, rect.height - 2)
    }

    layout(dialog.blocks, inner, ctx.base, ctx)
  end

  defp dialog(dialog, ctx) do
    rect = dialog.rect
    style = resolve(:card, ctx.base, ctx.options)
    # A dialog floats over the transcript, so its frame is drawn a step
    # brighter than a panel's hairline: the ghost text colour, not the border.
    ctx = fill(ctx, rect, style) |> border(rect, resolve(:text_ghost, style, ctx.options))

    inner = %Rect{
      x: rect.x + min(1, rect.width),
      y: rect.y + min(1, rect.height),
      width: max(0, rect.width - 2),
      height: max(0, rect.height - 2)
    }

    title = resolve(:heading, style, ctx.options)

    ctx =
      layout(
        [%Block.Text{text: dialog.title}],
        %{inner | y: rect.y, height: if(inner.width > 0, do: 1, else: 0)},
        title,
        ctx
      )

    footer = lines(dialog.footer, inner.width, inner.height, style, ctx)
    footer_height = length(footer)
    ctx = layout(dialog.blocks, %{inner | height: inner.height - footer_height}, style, ctx)

    paint_lines(
      footer,
      %{inner | y: inner.y + inner.height - footer_height, height: footer_height},
      ctx
    )
  end

  defp border(ctx, rect, style, set \\ :square) do
    {horizontal, vertical, corners} = frame_glyphs(ctx, set)
    {index, ctx} = index(ctx, style)

    ctx =
      Enum.reduce(rect.x..(rect.x + rect.width - 1), ctx, fn x, acc ->
        acc
        |> glyph(x, rect.y, horizontal, 1, index, nil)
        |> glyph(x, rect.y + rect.height - 1, horizontal, 1, index, nil)
      end)

    ctx =
      Enum.reduce(rect.y..(rect.y + rect.height - 1), ctx, fn y, acc ->
        acc
        |> glyph(rect.x, y, vertical, 1, index, nil)
        |> glyph(rect.x + rect.width - 1, y, vertical, 1, index, nil)
      end)

    ctx
    |> glyph(rect.x, rect.y, elem(corners, 0), 1, index, nil)
    |> glyph(rect.x + rect.width - 1, rect.y, elem(corners, 1), 1, index, nil)
    |> glyph(rect.x, rect.y + rect.height - 1, elem(corners, 2), 1, index, nil)
    |> glyph(rect.x + rect.width - 1, rect.y + rect.height - 1, elem(corners, 3), 1, index, nil)
  end

  defp frame_glyphs(ctx, :square) do
    corners =
      if ctx.options.ascii? or ctx.policy == :wide,
        do: {"+", "+", "+", "+"},
        else: {"┌", "┐", "└", "┘"}

    {chrome("─", "-", ctx), chrome("│", "|", ctx), corners}
  end

  # pass75 interview: the note's rounded set; box drawing is ambiguous
  # width, so the wide policy draws the one-cell bracket pieces instead.
  defp frame_glyphs(ctx, :rounded) do
    cond do
      ctx.options.ascii? -> {"-", "|", {"+", "+", "+", "+"}}
      ctx.policy == :wide -> {"⎯", "⎜", {"⎡", "⎤", "⎣", "⎦"}}
      true -> {"─", "│", {"╭", "╮", "╰", "╯"}}
    end
  end

  # pass75 interview: an edge row keeps `╭─` and `─╮` and one blank of the
  # frame on each side: the left words start at x + 3, the right words end at
  # x + width - 4, with at least one blank, one rule and one blank between
  # them. When both do not fit the left words win and the right are cut (or
  # dropped); a cut side ends in an ellipsis.
  defp edge(ctx, rect, y, left, right, frame) when rect.width >= 7 do
    available = rect.width - 6
    left_runs = edge_runs(left, ctx)
    right_runs = edge_runs(right, ctx)
    {left_runs, left_width} = cut_runs(left_runs, available, ctx)

    {right_runs, right_width} =
      if right_runs == [] or available - left_width - 3 < 2,
        do: {[], 0},
        else: cut_runs(right_runs, available - left_width - 3, ctx)

    {index, ctx} = index(ctx, frame)

    ctx =
      if left_width > 0,
        do:
          ctx
          |> glyph(rect.x + 2, y, " ", 1, index, nil)
          |> glyph(rect.x + 3 + left_width, y, " ", 1, index, nil),
        else: ctx

    ctx = paint_runs(ctx, left_runs, rect.x + 3, y)
    right_x = rect.x + rect.width - 3 - right_width

    if right_width > 0 do
      ctx
      |> glyph(right_x - 1, y, " ", 1, index, nil)
      |> glyph(rect.x + rect.width - 3, y, " ", 1, index, nil)
      |> paint_runs(right_runs, right_x, y)
    else
      ctx
    end
  end

  defp edge(ctx, _rect, _y, _left, _right, _frame), do: ctx

  defp edge_runs(spans, ctx) do
    for %Scene.Span{} = span <- spans do
      style =
        case PaintStyle.resolve(span.style, ctx.base, ctx.options.color_mode) do
          {:ok, style} -> style
          {:error, reason} -> throw({:paint, reason})
        end

      {SafeText.value(span.text), style, span.action_id}
    end
  end

  defp cut_runs(runs, limit, ctx) do
    total = Enum.reduce(runs, 0, fn {text, _, _}, sum -> sum + Width.cells(text, ctx.policy) end)

    if total <= limit do
      {runs, total}
    else
      ellipsis = if ctx.options.ascii?, do: "...", else: "…"
      room = max(limit - Width.cells(ellipsis, ctx.policy), 0)

      {kept, used, last_style} =
        Enum.reduce_while(runs, {[], 0, nil}, fn {text, style, id}, {kept, used, last} ->
          {prefix, rest, width} = Width.take_cells(text, room - used, ctx.policy)
          kept = if prefix == "", do: kept, else: [{prefix, style, id} | kept]
          next = {kept, used + width, if(prefix == "", do: last || style, else: style)}
          if rest == "", do: {:cont, next}, else: {:halt, next}
        end)

      width = used + Width.cells(ellipsis, ctx.policy)

      if width > limit,
        do: {Enum.reverse(kept), used},
        else: {Enum.reverse([{ellipsis, last_style, nil} | kept]), width}
    end
  end

  defp paint_runs(ctx, runs, x, y) do
    {_, ctx} =
      Enum.reduce(runs, {x, ctx}, fn {text, style, id}, {x, acc} ->
        {index, acc} = index(acc, style)

        Enum.reduce(Width.graphemes(text), {x, acc}, fn grapheme, {x, acc} ->
          width = Width.cells(grapheme, acc.policy)

          if width == 0,
            do: {x, acc},
            else: {x + width, glyph(acc, x, y, grapheme, width, index, id)}
        end)
      end)

    ctx
  end

  # pass75 interview: every painted cell steps back to the ghost colour with
  # its modifiers dropped, glyphs and backgrounds kept. A twin that would pass
  # the 4 096 style bound is not made; that cell keeps its colour.
  defp ghost(ctx, rect) do
    ghost = resolve(:text_ghost, ctx.base, ctx.options).foreground

    {ctx, twins} =
      Enum.reduce(ctx.lookup, {ctx, %{}}, fn {entry, i}, {acc, twins} ->
        try do
          {j, acc} = index(acc, %{entry | foreground: ghost, modifiers: []})
          {acc, Map.put(twins, i, j)}
        catch
          {:paint, :capacity_exceeded} -> {acc, twins}
        end
      end)

    %{ctx | canvas: Canvas.restyle(ctx.canvas, rect, &Map.get(twins, &1, &1))}
  end

  defp hairline(region, ctx, surface) do
    rect = region.rect

    # pass72 R13: no full-height rule beside the side panel in colour; the
    # blank gap column is the edge (pass 75: no fill either). Without colour
    # the hairline stays.
    gap_col =
      case region.role do
        :navigator -> rect.x + rect.width
        :inspector when ctx.options.color_mode == :monochrome -> rect.x - 1
        _ -> nil
      end

    if gap_col != nil and gap_col >= 0 do
      border_style = resolve(:border, surface, ctx.options)
      {index, ctx} = index(ctx, border_style)
      glyph_char = chrome("╎", "|", ctx)

      Enum.reduce(rect.y..(rect.y + rect.height - 1)//1, ctx, fn y, acc ->
        case Canvas.put(acc.canvas, gap_col, y, glyph_char, 1, index, nil) do
          {:ok, canvas} -> %{acc | canvas: canvas}
          {:error, _} -> acc
        end
      end)
    else
      ctx
    end
  end

  defp chrome(unicode, ascii, ctx),
    do: if(ctx.options.ascii? or Width.cells(unicode, ctx.policy) != 1, do: ascii, else: unicode)

  defp layout(_, %{width: width, height: height}, _, ctx) when width == 0 or height == 0, do: ctx

  defp layout(blocks, rect, style, ctx),
    do: paint_lines(lines(blocks, rect.width, rect.height, style, ctx), rect, ctx)

  defp lines(blocks, width, height, style, ctx) do
    case Blocks.lines(blocks, width, ctx.options, style, height, ctx.policy) do
      {:ok, lines} -> lines
      {:error, reason} -> throw({:paint, reason})
    end
  end

  defp paint_lines(lines, rect, ctx) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(ctx, fn {line, dy}, acc ->
      {_, acc} =
        Enum.reduce(line.units, {rect.x, acc}, fn unit, {x, current} ->
          {style, current} = index(current, unit.style)

          {x + unit.width,
           glyph(current, x, rect.y + dy, unit.text, unit.width, style, unit.action_id)}
        end)

      acc
    end)
  end

  defp glyph(ctx, x, y, text, width, style, action) do
    case Canvas.put(ctx.canvas, x, y, text, width, style, action) do
      {:ok, canvas} -> %{ctx | canvas: canvas}
      {:error, reason} -> throw({:paint, reason})
    end
  end

  defp fill(ctx, rect, style) do
    {index, ctx} = index(ctx, style)

    case Canvas.fill(ctx.canvas, rect, index) do
      {:ok, canvas} -> %{ctx | canvas: canvas}
      {:error, reason} -> throw({:paint, reason})
    end
  end

  defp index(ctx, style) do
    case Map.fetch(ctx.lookup, style) do
      {:ok, index} ->
        {index, ctx}

      :error ->
        index = map_size(ctx.lookup)
        if index >= 4096, do: throw({:paint, :capacity_exceeded})

        {index,
         %{ctx | lookup: Map.put(ctx.lookup, style, index), entries: [style | ctx.entries]}}
    end
  end

  defp resolve(role, inherited, options) do
    case PaintStyle.resolve(%Style{role: role}, inherited, options.color_mode) do
      {:ok, style} -> style
      {:error, reason} -> throw({:paint, reason})
    end
  end

  defp focus(%{overlay: %{rect: rect} = dialog}) when rect.width > 0 and rect.height > 0,
    do: %{region_id: dialog.id, control_id: dialog.focused_control_id, rect: rect}

  defp focus(scene) do
    case Enum.find(
           scene.regions,
           &(&1.focus == :active and &1.rect.width > 0 and &1.rect.height > 0)
         ) do
      nil -> nil
      region -> %{region_id: region.id, control_id: nil, rect: region.rect}
    end
  end

  defp action_ids(%SafeText{}), do: []

  defp action_ids(%{} = map),
    do:
      Enum.flat_map(Map.to_list(map), fn
        {:action_id, id} when is_binary(id) -> [id]
        {_, value} -> action_ids(value)
      end)

  defp action_ids(list) when is_list(list), do: Enum.flat_map(list, &action_ids/1)
  defp action_ids(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> action_ids()
  defp action_ids(_), do: []
end
