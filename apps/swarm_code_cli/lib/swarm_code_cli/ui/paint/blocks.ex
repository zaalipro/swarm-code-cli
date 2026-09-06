defmodule SwarmCodeCLI.UI.Paint.Blocks do
  @moduledoc "Pure, bounded Scene display-list layout shared by painting and measurement."
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span, Style}
  alias SwarmCodeCLI.UI.Paint.{Budget, Markdown, Options, Text}
  alias SwarmCodeCLI.UI.Paint.Style, as: PaintStyle

  @blocks [
    Block.Text,
    Block.RichText,
    Block.Markdown,
    Block.Code,
    Block.VirtualList,
    Block.RunCard,
    Block.AgentList,
    Block.ConsensusLedger,
    Block.ResearchDocument,
    Block.Progress,
    Block.Tabs,
    Block.KeyValues,
    Block.Composer,
    Block.Notice,
    Block.ActionDeck
  ]
  @statuses [
    :queued,
    :running,
    :streaming,
    :paused,
    :waiting_question,
    :waiting_approval,
    :retrying,
    :done,
    :failed,
    :stopped,
    :interrupted,
    :superseded
  ]

  def lines(items, width, options, inherited, max_rows, policy \\ :narrow)

  def lines(items, width, %Options{} = options, inherited, max_rows, policy)
      when is_list(items) and is_integer(width) and width >= 0 and width <= 500 and
             is_integer(max_rows) and max_rows >= 0 and max_rows <= 200 and
             policy in [:narrow, :wide] do
    if Options.validate(options) != :ok, do: fail(:invalid_scene)

    case Budget.check_display_list(items) do
      :ok -> :ok
      {:error, reason} -> fail(reason)
    end

    ctx = %{width: width, options: options, style: inherited, policy: policy, depth: 0}
    {:ok, if(width == 0 or max_rows == 0, do: [], else: sequence(items, ctx, max_rows))}
  catch
    {:paint, reason} -> {:error, reason}
  end

  def lines(_, _, _, _, _, _), do: {:error, :invalid_scene}

  defp sequence(_, _, 0), do: []
  defp sequence([], _, _), do: []

  defp sequence([item | rest], ctx, rows) do
    painted = item(item, ctx, rows)
    painted ++ sequence(rest, ctx, rows - length(painted))
  end

  defp sequence(_, _, _), do: fail(:invalid_scene)

  defp item(_, %{depth: depth}, _) when depth > 32, do: fail(:capacity_exceeded)

  defp item(%{__struct__: module} = value, ctx, rows)
       when module in @blocks or module in [SafeText, Span] do
    if map_size(value) != map_size(struct(module)), do: fail(:invalid_scene)
    block(value, %{ctx | depth: ctx.depth + 1}, rows)
  end

  defp item(_, _, _), do: fail(:invalid_scene)

  defp block(%SafeText{} = value, ctx, rows), do: render([run(value, ctx.style)], ctx, rows)
  defp block(%Span{} = span, ctx, rows), do: render(span_runs(span, ctx), ctx, rows)

  defp block(%Block.Text{text: value, action_id: id}, ctx, rows),
    do: render([run(value, ctx.style, id)], ctx, rows)

  defp block(%Block.RichText{spans: spans, action_id: id}, ctx, rows) when is_list(spans) do
    action!(id)

    runs =
      Enum.flat_map(spans, fn
        %Span{} = span -> span_runs(%{span | action_id: span.action_id || id}, ctx)
        _ -> fail(:invalid_scene)
      end)

    render(runs, ctx, rows)
  end

  defp block(%Block.Markdown{text: value}, ctx, rows),
    do: unwrap(Markdown.lines(value!(value), ctx.width, ctx.options, ctx.style, rows, ctx.policy))

  defp block(%Block.Code{text: value, language: language}, ctx, rows) do
    caption = if language, do: render([run(language, role(:label, ctx))], ctx, rows), else: []
    left = rows - length(caption)
    caption ++ if(left > 0, do: render([run(value, role(:code, ctx))], ctx, left), else: [])
  end

  defp block(%Block.VirtualList{items: items}, ctx, rows), do: sequence(items, ctx, rows)
  defp block(%Block.AgentList{agents: items}, ctx, rows), do: sequence(items, ctx, rows)

  defp block(%Block.ConsensusLedger{entries: entries}, ctx, rows) do
    header = render([raw("Consensus", role(:heading, ctx))], ctx, rows)
    header ++ sequence(entries, ctx, rows - length(header))
  end

  defp block(%Block.ResearchDocument{title: title, sources: sources}, ctx, rows) do
    header = render([run(title, role(:heading, ctx))], ctx, rows)
    header ++ sequence(sources, ctx, rows - length(header))
  end

  defp block(%Block.RunCard{title: title, status: status, body: body}, ctx, rows)
       when status in @statuses do
    {status_text, status_role} = Theme.status(status)
    boundary = if ctx.options.ascii?, do: " - ", else: " — "

    header =
      render(
        [
          run(title, role(:title, ctx)),
          raw(boundary, ctx.style),
          run(status_text, role(status_role, ctx))
        ],
        ctx,
        rows
      )

    header ++ sequence(body, ctx, rows - length(header))
  end

  defp block(%Block.Composer{text: value, placeholder: placeholder}, ctx, rows) do
    case value!(value) do
      "" -> render([run(placeholder, role(:text_muted, ctx))], ctx, rows)
      text -> render([raw(text, ctx.style)], ctx, rows)
    end
  end

  defp block(%Block.Notice{text: text, severity: severity, action_id: id}, ctx, rows)
       when severity in [:info, :success, :warning, :error] do
    render(
      span_runs(%Span{text: text, action_id: id, style: %Style{role: severity}}, ctx),
      ctx,
      rows
    )
  end

  defp block(%Block.Progress{label: label, value: value, maximum: maximum}, ctx, rows)
       when is_integer(value) and value >= 0 and is_integer(maximum) and maximum >= 0 do
    tail =
      if maximum == 0 do
        if ctx.options.ascii?, do: " ...", else: " …"
      else
        slots = max(1, min(20, ctx.width - 10))
        filled = div(min(value, maximum) * slots, maximum)
        {on, off} = if ctx.options.ascii?, do: {"#", "-"}, else: {"█", "░"}

        " [" <>
          String.duplicate(on, filled) <>
          String.duplicate(off, slots - filled) <>
          "] " <> Integer.to_string(div(min(value, maximum) * 100, maximum)) <> "%"
      end

    render([run(label, ctx.style), raw(tail, role(:status, ctx))], ctx, rows)
  end

  defp block(%Block.KeyValues{rows: values}, ctx, rows) when is_list(values) do
    # A label never reserves more than a third of the available cells.
    column = max(1, min(24, div(ctx.width, 3)))
    key_values(values, ctx, rows, column)
  end

  defp block(%Block.ActionDeck{actions: actions}, ctx, rows) when is_list(actions),
    do: inline(actions, ctx, rows, nil, 0, [])

  defp block(%Block.Tabs{tabs: tabs, selected: selected}, ctx, rows)
       when is_list(tabs) and is_integer(selected) and selected >= 0,
       do: inline(tabs, ctx, rows, selected, 0, [])

  defp block(_, _, _), do: fail(:invalid_scene)

  defp key_values(_, _, 0, _), do: []
  defp key_values([], _, _, _), do: []

  defp key_values([{label, value} | rest], ctx, rows, column) do
    label_line = render([run(label, role(:label, ctx))], %{ctx | width: column}, 1)

    label_runs =
      case label_line do
        [line] -> Enum.map(line.units, &Map.take(&1, [:text, :style, :action_id]))
        [] -> []
      end

    painted =
      render(label_runs ++ [raw(": ", ctx.style), run(value, role(:value, ctx))], ctx, rows)

    painted ++ key_values(rest, ctx, rows - length(painted), column)
  end

  defp key_values(_, _, _, _), do: fail(:invalid_scene)

  # Items are measured with the same glyph layout before packing. A label that
  # fits on a row moves as a whole; oversized labels wrap within their own rows.
  defp inline([], _, _, _, _, acc), do: acc
  defp inline(_, _, 0, _, _, acc), do: acc

  defp inline([value | rest], ctx, rows, selected, index, acc) do
    selected? = selected == index
    item_ctx = if selected?, do: %{ctx | style: role(:selected, ctx)}, else: ctx

    painted =
      if selected?, do: selected_item(value, item_ctx, rows), else: item(value, item_ctx, rows)

    combined = pack(acc, painted, ctx)
    visible = Enum.take(combined, rows)

    if length(combined) > rows or
         (length(visible) == rows and List.last(visible).cells == ctx.width),
       do: visible,
       else: inline(rest, ctx, rows, selected, index + 1, visible)
  end

  defp selected_item(value, ctx, rows) do
    prefix = raw("SELECTED > ", ctx.style)
    selected_ctx = Map.put(ctx, :prefix_role, :selected)

    case value do
      %SafeText{} ->
        render([prefix, run(value, ctx.style)], ctx, rows)

      %Span{} ->
        render([prefix | span_runs(value, selected_ctx)], ctx, rows)

      %Block.Text{text: text, action_id: id} ->
        render([prefix, run(text, ctx.style, id)], ctx, rows)

      %Block.RichText{spans: spans, action_id: id} when is_list(spans) ->
        action!(id)

        runs =
          Enum.flat_map(spans, fn
            %Span{} = span -> span_runs(%{span | action_id: span.action_id || id}, selected_ctx)
            _ -> fail(:invalid_scene)
          end)

        render([prefix | runs], ctx, rows)

      _ ->
        header = render([prefix], ctx, rows)

        header ++
          if(rows > length(header),
            do: item(value, selected_ctx, rows - length(header)),
            else: []
          )
    end
  end

  defp pack([], lines, _), do: lines
  defp pack(acc, [], _), do: acc

  defp pack(acc, [first | rest] = lines, ctx) do
    last = List.last(acc)

    if last.cells + 2 + first.cells <= ctx.width do
      [separator] = render([raw("  ", ctx.style)], ctx, 1)

      joined = %{
        units: last.units ++ separator.units ++ first.units,
        cells: last.cells + 2 + first.cells
      }

      Enum.drop(acc, -1) ++ [joined | rest]
    else
      acc ++ lines
    end
  end

  defp span_runs(%Span{style: style, text: text, action_id: id} = span, ctx) do
    if map_size(span) != 4, do: fail(:invalid_scene)
    resolved = unwrap(PaintStyle.resolve(style, ctx.style, ctx.options.color_mode))
    themed = Theme.style(style.role, %Capabilities{size: nil, color_mode: ctx.options.color_mode})

    prefix =
      style.prefix || if(Map.get(ctx, :prefix_role) == style.role, do: nil, else: themed.prefix)

    prefix_runs =
      if prefix,
        do: [raw(prefix_value(prefix, ctx.options.ascii?) <> " ", resolved, id)],
        else: []

    prefix_runs ++ [run(text, resolved, id)]
  end

  # Only catalogue chrome is eligible for ASCII fallback. Explicit external
  # prefixes, like every other external SafeText, keep their original Unicode.
  defp prefix_value(%SafeText{token: token} = text, true) when is_atom(token),
    do:
      value!(text)
      |> String.replace("—", "-")
      |> String.replace("→", ">")
      |> String.replace("•", "*")

  defp prefix_value(text, _), do: value!(text)

  defp role(name, ctx),
    do: unwrap(PaintStyle.resolve(%Style{role: name}, ctx.style, ctx.options.color_mode))

  defp run(value, style, id \\ nil), do: raw(value!(value), style, id)

  defp raw(text, style, id \\ nil) do
    action!(id)
    %{text: text, style: style, action_id: id}
  end

  defp value!(%SafeText{} = value) do
    SafeText.value(value)
  rescue
    ArgumentError -> fail(:invalid_text)
    FunctionClauseError -> fail(:invalid_text)
  end

  defp value!(_), do: fail(:invalid_text)
  defp action!(nil), do: :ok
  defp action!(id) when is_binary(id) and byte_size(id) > 0, do: :ok
  defp action!(_), do: fail(:invalid_scene)
  defp render(_, _, 0), do: []
  defp render(runs, ctx, rows), do: unwrap(Text.lines(runs, ctx.width, ctx.policy, rows))
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: fail(reason)
  defp fail(reason), do: throw({:paint, reason})
end
