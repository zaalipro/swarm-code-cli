defmodule SwarmCodeCLI.UI.Paint.Markdown do
  @moduledoc "Small literal-preserving Markdown presentation, with bounded retained rows."
  alias SwarmCodeCLI.UI.Paint.{Options, Text}
  alias SwarmCodeCLI.UI.Paint.Style, as: PaintStyle
  alias SwarmCodeCLI.UI.Scene.Style

  def lines(text, width, options, inherited, max_rows, policy \\ :narrow)

  def lines(text, width, %Options{} = options, inherited, max_rows, policy)
      when is_binary(text) and is_integer(width) and width >= 0 and width <= 500 and
             is_integer(max_rows) and max_rows >= 0 and max_rows <= 200 and
             policy in [:narrow, :wide] do
    if Options.validate(options) != :ok, do: throw({:paint, :invalid_scene})
    if byte_size(text) > 4_194_304, do: throw({:paint, :capacity_exceeded})
    ctx = %{width: width, options: options, style: inherited, policy: policy}
    {:ok, if(width == 0 or max_rows == 0, do: [], else: scan(text, ctx, max_rows, nil))}
  catch
    {:paint, reason} -> {:error, reason}
  end

  def lines(_, _, _, _, _, _), do: {:error, :invalid_text}

  @doc false
  def parsed_lines(text, %Options{} = options, inherited, width \\ 500, policy \\ :narrow)
      when is_binary(text) do
    if Options.validate(options) != :ok, do: throw({:paint, :invalid_scene})
    if byte_size(text) > 4_194_304, do: throw({:paint, :capacity_exceeded})
    ctx = %{options: options, style: inherited, width: width, policy: policy}

    Stream.unfold({text, nil}, fn
      {nil, _} ->
        nil

      {remaining, fence} ->
        {line, rest} = next_line(remaining)
        {runs, next_fence} = display_presentation(line, fence, ctx)
        {%{runs: runs, code?: fence != nil or next_fence != nil}, {rest, next_fence}}
    end)
    |> Stream.reject(&(&1.runs == :skip))
  end

  defp display_presentation(line, fence, ctx) do
    {runs, next_fence} = presentation(line, fence, ctx, 0)

    if runs == :skip or Enum.map_join(runs, & &1.text) == line do
      {runs, next_fence}
    else
      # Removing syntax can detach a combining mark or exceed the shaper's
      # aggregate run budget. Validate the transformed line before windowing;
      # preserve admitted source bytes when that presentation is unsupported.
      case Text.lines(runs, ctx.width, ctx.policy, 1) do
        {:ok, _} ->
          {runs, next_fence}

        {:error, reason} when reason in [:invalid_text, :capacity_exceeded] ->
          {[run(line, ctx.style)], next_fence}
      end
    end
  catch
    # Canonical source text can exceed the optional inline syntax budget.
    # Preserve that line literally for scrolling instead of failing projection.
    {:paint, :capacity_exceeded} -> {[run(line, ctx.style)], fence}
  end

  defp scan(_, _, 0, _), do: []
  defp scan(nil, _, _, _), do: []

  defp scan(text, ctx, rows, fence) do
    {line, rest} = next_line(text)
    {runs, next_fence} = display_presentation(line, fence, ctx)

    painted =
      if runs == :skip, do: [], else: unwrap(Text.lines(runs, ctx.width, ctx.policy, rows))

    # Empty source lines still occupy a paragraph line.
    painted = if runs != :skip and painted == [], do: [%{units: [], cells: 0}], else: painted
    painted ++ scan(rest, ctx, rows - length(painted), next_fence)
  end

  defp next_line(text) do
    case :binary.match(text, "\n") do
      :nomatch ->
        {text, nil}

      {offset, 1} ->
        {text |> binary_part(0, offset) |> String.trim_trailing("\r"),
         binary_part(text, offset + 1, byte_size(text) - offset - 1)}
    end
  end

  defp presentation(line, fence, ctx, _rows) do
    cond do
      fence && String.trim(line) == fence ->
        {:skip, nil}

      fence ->
        {[run(line, role(:code, ctx))], fence}

      String.starts_with?(line, "```") ->
        open_fence(line, "```", ctx)

      String.starts_with?(line, "~~~") ->
        open_fence(line, "~~~", ctx)

      true ->
        {content, style, prefix} = line_style(line, ctx)
        runs = inline(content, style, ctx, 0, [])
        {if(prefix == "", do: runs, else: [run(prefix, style) | runs]), nil}
    end
  end

  defp open_fence(line, marker, ctx) do
    caption = binary_part(line, 3, byte_size(line) - 3) |> String.trim()
    if caption == "", do: {:skip, marker}, else: {[run(caption, role(:label, ctx))], marker}
  end

  defp line_style(line, ctx) do
    case Regex.run(~r/^(\#{1,6}) (.*)$/u, line, capture: :all_but_first) do
      [_, content] ->
        {content, role(:heading, ctx), ""}

      _ ->
        case line do
          <<marker, " ", rest::binary>> when marker in [?-, ?*, ?+] ->
            {rest, ctx.style, if(ctx.options.ascii?, do: "* ", else: "• ")}

          _ ->
            {line, ctx.style, ""}
        end
    end
  end

  # Keep literal source as subbinaries. Parsing removes only supported markers,
  # so shaping sees complete transformed Unicode context rather than a guessed
  # source-grapheme prefix. The text shaper retains only the visible cells.
  defp inline("", _, _, _, acc), do: Enum.reverse(acc)
  defp inline(_, _, _, 4096, _), do: throw({:paint, :capacity_exceeded})

  defp inline(text, style, ctx, count, acc) do
    case marked(text) do
      {content, rest, modifier} ->
        marked_style =
          case modifier do
            :code -> role(:code, %{ctx | style: style})
            mod -> %{style | modifiers: Enum.uniq(style.modifiers ++ [mod])}
          end

        inline(rest, style, ctx, count + 1, [run(content, marked_style) | acc])

      nil ->
        {literal, rest} = literal_prefix(text)
        inline(rest, style, ctx, count + 1, [run(literal, style) | acc])
    end
  end

  defp literal_prefix(text) do
    case :binary.match(text, ["*", "`"]) do
      :nomatch -> {text, ""}
      {0, 1} -> {binary_part(text, 0, 1), binary_part(text, 1, byte_size(text) - 1)}
      {at, 1} -> {binary_part(text, 0, at), binary_part(text, at, byte_size(text) - at)}
    end
  end

  defp marked(text) do
    cond do
      String.starts_with?(text, "**") -> enclosed(text, "**", :bold)
      String.starts_with?(text, "*") -> enclosed(text, "*", :italic)
      String.starts_with?(text, "`") -> enclosed(text, "`", :code)
      true -> nil
    end
  end

  defp enclosed(text, marker, modifier) do
    size = byte_size(marker)
    tail = binary_part(text, size, byte_size(text) - size)

    case :binary.match(tail, marker) do
      {at, len} when at > 0 ->
        {binary_part(tail, 0, at), binary_part(tail, at + len, byte_size(tail) - at - len),
         modifier}

      _ ->
        nil
    end
  end

  defp role(name, ctx),
    do: unwrap(PaintStyle.resolve(%Style{role: name}, ctx.style, ctx.options.color_mode))

  defp run(text, style), do: %{text: text, style: style, action_id: nil}
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: throw({:paint, reason})
end
