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
      base: base
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
    style =
      if region.role in [:navigator, :inspector],
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

  defp border(ctx, rect, style) do
    horizontal = chrome("─", "-", ctx)
    vertical = chrome("│", "|", ctx)

    corners =
      if ctx.options.ascii? or ctx.policy == :wide,
        do: {"+", "+", "+", "+"},
        else: {"┌", "┐", "└", "┘"}

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

  defp hairline(region, ctx, surface) do
    rect = region.rect

    # pass72 R13: no full-height rule beside the side panel; its surface is
    # the edge. Without colour (no surface shows) the hairline stays.
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
