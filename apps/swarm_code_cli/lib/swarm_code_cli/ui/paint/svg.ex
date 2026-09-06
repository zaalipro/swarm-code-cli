defmodule SwarmCodeCLI.UI.Paint.SVG do
  @moduledoc """
  Pure, passive SVG cell previews of validated paint plans.

  Cells are 10 by 20 pixels, with a 16-pixel local monospace font. Default
  colors and ANSI mappings are preview choices; this is not native terminal
  appearance evidence. No fonts, images, scripts or other resources are loaded.
  The result is bounded to 128 MiB before conversion from iodata to a binary.
  """
  alias SwarmCodeCLI.UI.Paint.Plan
  alias SwarmCodeCLI.UI.Scene.{Cursor, Rect}

  @cell_width 10
  @cell_height 20
  @max_bytes 128 * 1024 * 1024
  @foreground "#f3f2f0"
  @background "#141414"
  @ansi_names [
    :black,
    :red,
    :green,
    :yellow,
    :blue,
    :magenta,
    :cyan,
    :white,
    :bright_black,
    :bright_red,
    :bright_green,
    :bright_yellow,
    :bright_blue,
    :bright_magenta,
    :bright_cyan,
    :bright_white
  ]
  @ansi_colors {
    "#000000",
    "#800000",
    "#008000",
    "#808000",
    "#000080",
    "#800080",
    "#008080",
    "#c0c0c0",
    "#808080",
    "#ff0000",
    "#00ff00",
    "#ffff00",
    "#0000ff",
    "#ff00ff",
    "#00ffff",
    "#ffffff"
  }
  @ansi Map.new(Enum.with_index(@ansi_names), fn {name, index} ->
          {name, elem(@ansi_colors, index)}
        end)
  @cube {0, 95, 135, 175, 215, 255}

  @spec encode(term()) :: {:ok, binary()} | {:error, :invalid_plan}
  def encode(plan) do
    with :ok <- Plan.validate(plan) do
      svg = document(plan)

      if :erlang.iolist_size(svg) <= @max_bytes,
        do: {:ok, :erlang.iolist_to_binary(svg)},
        else: {:error, :invalid_plan}
    end
  catch
    :invalid_xml -> {:error, :invalid_plan}
  end

  defp document(plan) do
    width = plan.size.columns * @cell_width
    height = plan.size.rows * @cell_height
    palette = plan.palette |> Tuple.to_list() |> Enum.map(&resolve_style/1) |> List.to_tuple()
    {backgrounds, glyphs} = cells(plan, palette, 0, [], [])

    [
      "<svg",
      attrs(
        xmlns: "http://www.w3.org/2000/svg",
        viewBox: "0 0 #{width} #{height}",
        width: width,
        height: height
      ),
      attrs("data-revision": plan.revision, "data-ambiguous-width": plan.ambiguous_width),
      ">",
      "<title>FAKE DEMO — NO USER DATA · cell preview</title>",
      "<g>",
      Enum.reverse(backgrounds),
      "</g>",
      "<g",
      attrs(
        "font-family": "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
        "font-size": 16,
        "xml:space": "preserve"
      ),
      ">",
      Enum.reverse(glyphs),
      "</g>",
      actions(plan.actions),
      cursor(plan.cursor),
      focus(plan.focus),
      "</svg>"
    ]
  end

  defp cells(plan, _palette, index, backgrounds, glyphs) when index == tuple_size(plan.cells),
    do: {backgrounds, glyphs}

  defp cells(plan, palette, index, backgrounds, glyphs) do
    {:glyph, text, width, style_index} = elem(plan.cells, index)
    {foreground, background, modifiers} = elem(palette, style_index)
    x = rem(index, plan.size.columns) * @cell_width
    y = div(index, plan.size.columns) * @cell_height

    backgrounds =
      Enum.reduce(0..(width - 1), backgrounds, fn offset, acc ->
        [rect(x + offset * @cell_width, y, @cell_width, @cell_height, fill: background) | acc]
      end)

    glyph = [
      "<text",
      attrs(
        x: x,
        y: y + 15,
        fill: foreground,
        textLength: width * @cell_width,
        lengthAdjust: "spacingAndGlyphs"
      ),
      modifier_attrs(modifiers),
      ">",
      escape(text),
      "</text>"
    ]

    cells(plan, palette, index + width, backgrounds, [glyph | glyphs])
  end

  defp resolve_style(style) do
    foreground = color(style.foreground, @foreground)
    background = color(style.background, @background)

    if :reversed in style.modifiers,
      do: {background, foreground, style.modifiers},
      else: {foreground, background, style.modifiers}
  end

  defp color(nil, default), do: default
  defp color({:rgb, red, green, blue}, _default), do: rgb(red, green, blue)
  defp color({:ansi, name}, _default), do: Map.fetch!(@ansi, name)
  defp color({:indexed, index}, _default) when index < 16, do: elem(@ansi_colors, index)

  defp color({:indexed, index}, _default) when index < 232 do
    cube = index - 16
    rgb(elem(@cube, div(cube, 36)), elem(@cube, rem(div(cube, 6), 6)), elem(@cube, rem(cube, 6)))
  end

  defp color({:indexed, index}, _default) do
    gray = 8 + 10 * (index - 232)
    rgb(gray, gray, gray)
  end

  defp rgb(red, green, blue),
    do: "#" <> Base.encode16(<<red, green, blue>>, case: :lower)

  defp modifier_attrs(modifiers) do
    Enum.map(modifiers, fn
      :bold -> attrs("font-weight": "bold")
      :dim -> attrs(opacity: "0.6")
      :italic -> attrs("font-style": "italic")
      :underlined -> attrs("text-decoration": "underline")
      :reversed -> []
    end)
  end

  defp actions(actions) do
    actions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {id, rectangles} ->
      [
        "<g",
        attrs("data-action": id),
        ">",
        Enum.map(rectangles, fn r ->
          rect(
            r.x * @cell_width,
            r.y * @cell_height,
            r.width * @cell_width,
            r.height * @cell_height,
            fill: "none"
          )
        end),
        "</g>"
      ]
    end)
  end

  defp cursor(%Cursor{visible?: true} = cursor) do
    x = cursor.x * @cell_width
    y = cursor.y * @cell_height

    {x, y, width, height} =
      case cursor.shape do
        :block -> {x, y, @cell_width, @cell_height}
        :bar -> {x, y, 2, @cell_height}
        :underline -> {x, y + @cell_height - 2, @cell_width, 2}
      end

    [
      "<rect",
      attrs("data-cursor": cursor.shape),
      attrs(x: x, y: y, width: width, height: height, fill: @foreground, opacity: "0.65"),
      "/>"
    ]
  end

  defp cursor(_), do: []

  defp focus(%{region_id: region, rect: %Rect{} = rect}) do
    # Inset the stroke so focus on an outer edge remains entirely in the viewBox.
    [
      "<rect",
      attrs("data-focus": region),
      attrs(
        x: rect.x * @cell_width + 1,
        y: rect.y * @cell_height + 1,
        width: rect.width * @cell_width - 2,
        height: rect.height * @cell_height - 2,
        fill: "none",
        stroke: "#ff6a1a",
        "stroke-width": 2
      ),
      "/>"
    ]
  end

  defp focus(_), do: []

  defp rect(x, y, width, height, extra),
    do: ["<rect", attrs([x: x, y: y, width: width, height: height] ++ extra), "/>"]

  defp attrs(attributes),
    do:
      Enum.map(attributes, fn {name, value} ->
        [" ", Atom.to_string(name), "=\"", escape(to_string(value)), "\""]
      end)

  defp escape(text) do
    # These two Unicode scalar values are excluded by XML 1.0, even as references.
    # Plan's opaque identifiers need not otherwise follow a display text policy.
    if :binary.match(text, [<<0xFFFE::utf8>>, <<0xFFFF::utf8>>]) != :nomatch,
      do: throw(:invalid_xml)

    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
