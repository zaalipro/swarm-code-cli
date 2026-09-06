defmodule SwarmCodeCLI.UI.Transcript do
  @moduledoc "Shared lazy rendered transcript rows for scroll measurement and projection."
  alias SwarmCodeCLI.UI.{Prose, SafeText, Width}
  alias SwarmCodeCLI.UI.Paint.{Markdown, Options, Text}
  alias SwarmCodeCLI.UI.Paint.Style, as: PaintStyle
  alias SwarmCodeCLI.UI.Scene.{Block, Color, Span, Style}
  @base %{foreground: nil, background: nil, modifiers: []}

  def rows(item, kind, width, capabilities) do
    width = max(1, min(width, 500))
    limits = %{SafeText.Limits.content() | ambiguous_width: capabilities.ambiguous_width}

    text =
      case SafeText.external(item.text, limits) do
        {:ok, safe} -> SafeText.value(safe)
        {:error, _} -> SafeText.value(SafeText.chrome(:text_limit))
      end

    options = %Options{color_mode: capabilities.color_mode, ascii?: capabilities.ascii?}
    {:ok, base} = PaintStyle.resolve(%Style{role: :text_primary}, @base, options.color_mode)
    policy = capabilities.ambiguous_width

    {prefix, content} =
      cond do
        item.state == :superseded ->
          {:ok, muted} = PaintStyle.resolve(%Style{role: :text_muted}, base, options.color_mode)

          {[plain(SafeText.value(SafeText.chrome(:status_superseded)), muted)],
           plain_lines(text, muted)}

        item.role == :tool and kind == :consensus ->
          {:ok, heading} = PaintStyle.resolve(%Style{role: :heading}, base, options.color_mode)
          {[plain("Consensus", heading)], plain_lines(text, base)}

        item.role == :tool and kind == :research ->
          {:ok, heading} = PaintStyle.resolve(%Style{role: :heading}, base, options.color_mode)

          {[plain(SafeText.value(SafeText.chrome(:research_report)), heading)],
           plain_lines(text, base)}

        item.role == :assistant ->
          {[], Markdown.parsed_lines(text, options, base, width, policy)}

        true ->
          {[], plain_lines(text, base)}
      end

    Stream.concat(prefix, content)
    |> Stream.flat_map(&layout(&1, width, policy))
  end

  def height(item, kind, width, capabilities),
    do: Enum.count(rows(item, kind, width, capabilities))

  def window(item, kind, width, capabilities, offset, limit, follow?) do
    rows = rows(item, kind, width, capabilities)

    visible =
      cond do
        limit <= 0 -> []
        follow? -> Enum.take(rows, -limit)
        true -> rows |> Stream.drop(max(0, offset)) |> Enum.take(limit)
      end

    policy = capabilities.ambiguous_width

    spans =
      visible
      |> Enum.map(&block(&1, policy))
      |> Enum.intersperse(%Block.Text{text: safe("\n", policy)})
      |> Enum.flat_map(fn
        %Block.RichText{spans: spans} -> spans
        %Block.Text{text: text} -> [%Span{text: text}]
      end)

    {if(spans == [], do: nil, else: %Block.RichText{spans: spans}), length(visible)}
  end

  defp plain(text, style),
    do: %{runs: [%{text: text, style: style, action_id: nil}], code?: false}

  defp plain_lines(text, style) do
    Stream.unfold(text, fn
      nil ->
        nil

      remaining ->
        case :binary.match(remaining, "\n") do
          :nomatch ->
            {plain(remaining, style), nil}

          {at, 1} ->
            {plain(binary_part(remaining, 0, at), style),
             binary_part(remaining, at + 1, byte_size(remaining) - at - 1)}
        end
    end)
  end

  defp layout(%{runs: runs, code?: code?}, width, policy) do
    text = Enum.map_join(runs, & &1.text)
    lines = if code?, do: Width.wrap(text, width, policy), else: Prose.wrap(text, width, policy)
    lines = if lines == [], do: [""], else: lines

    Stream.transform(lines, runs, fn line, remaining ->
      {selected, rest} = take_runs(remaining, byte_size(line), [])
      {:ok, rows} = Text.lines(selected, width, policy, 200)
      {if(rows == [], do: [%{units: [], cells: 0}], else: rows), rest}
    end)
  end

  defp take_runs(runs, 0, acc), do: {Enum.reverse(acc), runs}

  defp take_runs([run | rest], bytes, acc) do
    count = min(byte_size(run.text), bytes)
    selected = %{run | text: binary_part(run.text, 0, count)}
    remaining = binary_part(run.text, count, byte_size(run.text) - count)
    tail = if remaining == "", do: rest, else: [%{run | text: remaining} | rest]
    take_runs(tail, bytes - count, [selected | acc])
  end

  defp block(%{units: []}, policy), do: %Block.Text{text: safe(" ", policy)}

  defp block(%{units: units}, policy) do
    spans =
      units
      |> Enum.chunk_by(& &1.style)
      |> Enum.map(fn group ->
        style = hd(group).style

        %Span{
          text: safe(Enum.map_join(group, & &1.text), policy),
          style: %Style{
            role: :plain,
            foreground: color(style.foreground),
            background: color(style.background),
            modifiers: style.modifiers
          }
        }
      end)

    %Block.RichText{spans: spans}
  end

  defp safe(text, policy) do
    # Re-escape complete clusters in source-sized chunks, then concatenate
    # under SafeText's larger escaped-output budget.
    limits = SafeText.Limits.content()

    text
    |> String.graphemes()
    |> Enum.chunk_while(
      {[], 0},
      fn grapheme, {parts, bytes} ->
        if bytes + byte_size(grapheme) > limits.input_bytes do
          {:cont, parts |> Enum.reverse() |> Enum.join(), {[grapheme], byte_size(grapheme)}}
        else
          {:cont, {[grapheme | parts], bytes + byte_size(grapheme)}}
        end
      end,
      fn {parts, _} -> {:cont, parts |> Enum.reverse() |> Enum.join(), {[], 0}} end
    )
    |> Enum.map(fn chunk ->
      {:ok, safe} = SafeText.external(chunk, %{limits | ambiguous_width: policy})
      safe
    end)
    |> SafeText.concat()
  end

  defp color(nil), do: nil
  defp color(value), do: %Color{role: :default, value: value}
end
