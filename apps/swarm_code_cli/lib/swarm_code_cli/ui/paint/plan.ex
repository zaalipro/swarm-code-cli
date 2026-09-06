defmodule SwarmCodeCLI.UI.Paint.Plan do
  @moduledoc "Validated renderer-neutral cells, palette and visible action rectangles."
  alias SwarmCodeCLI.UI.{Size, Width}
  alias SwarmCodeCLI.UI.Scene.{Color, Cursor, Rect, Style}
  alias SwarmCodeCLI.UI.Paint.Cell

  defstruct version: 1,
            revision: 0,
            size: nil,
            ambiguous_width: :narrow,
            color_mode: :truecolor,
            cells: {},
            palette: {},
            cursor: nil,
            focus: nil,
            actions: %{},
            diagnostics: []

  @type t :: %__MODULE__{
          version: 1,
          revision: non_neg_integer(),
          size: Size.t(),
          ambiguous_width: :narrow | :wide,
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome,
          cells: tuple(),
          palette: tuple(),
          cursor: Cursor.t() | nil,
          focus: map() | nil,
          actions: %{optional(binary()) => [Rect.t()]},
          diagnostics: [{:clipped_action, binary()}]
        }

  @spec validate(term()) :: :ok | {:error, :invalid_plan}
  def validate(%__MODULE__{} = plan) do
    if valid?(plan), do: :ok, else: {:error, :invalid_plan}
  rescue
    _ -> {:error, :invalid_plan}
  end

  def validate(_), do: {:error, :invalid_plan}

  @spec cell(t(), term(), term()) :: Cell.t() | nil
  def cell(%__MODULE__{size: %Size{columns: columns, rows: rows}, cells: cells}, x, y)
      when is_integer(columns) and is_integer(rows) and
             is_integer(x) and x >= 0 and x < columns and is_integer(y) and y >= 0 and y < rows and
             is_tuple(cells) do
    index = y * columns + x
    if index < tuple_size(cells), do: elem(cells, index)
  end

  def cell(_, _, _), do: nil

  defp valid?(plan) do
    map_size(plan) == 12 and plan.version == 1 and unsigned?(plan.revision) and
      valid_size?(plan.size) and plan.ambiguous_width in [:narrow, :wide] and
      plan.color_mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
      is_tuple(plan.cells) and tuple_size(plan.cells) == plan.size.columns * plan.size.rows and
      is_tuple(plan.palette) and tuple_size(plan.palette) in 1..4096 and
      is_map(plan.actions) and not is_struct(plan.actions) and map_size(plan.actions) <= 4096 and
      :erlang.external_size(plan) <= 32 * 1024 * 1024 and
      valid_palette?(plan.palette, plan.color_mode) and
      valid_cells?(
        plan.cells,
        0,
        tuple_size(plan.cells),
        plan.size.columns,
        tuple_size(plan.palette),
        plan.ambiguous_width,
        MapSet.new()
      ) and
      cursor?(plan.cursor, plan.size) and focus?(plan.focus, plan.size) and
      actions?(plan.actions, plan.size, plan.cells) and
      diagnostics?(plan.diagnostics, plan.actions)
  end

  defp unsigned?(value),
    do: is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615

  defp valid_size?(%Size{columns: columns, rows: rows} = size),
    do: Size.valid?(size) and columns <= 500 and rows <= 200 and columns * rows <= 100_000

  defp valid_size?(_), do: false

  defp valid_palette?(palette, mode),
    do: palette |> Tuple.to_list() |> Enum.all?(&style?(&1, mode))

  defp style?(
         %{foreground: foreground, background: background, modifiers: modifiers} = style,
         mode
       ),
       do:
         map_size(style) == 3 and color?(foreground, mode) and color?(background, mode) and
           is_list(modifiers) and length(modifiers) <= 5 and Enum.uniq(modifiers) == modifiers and
           Enum.all?(modifiers, &(&1 in Style.modifiers()))

  defp style?(_, _), do: false

  defp color?(value, mode) do
    Color.valid?(%Color{role: :default, value: value}) and
      case value do
        nil -> true
        {:rgb, _, _, _} -> mode == :truecolor
        {:indexed, _} -> mode in [:truecolor, :ansi256]
        {:ansi, _} -> mode in [:truecolor, :ansi256, :ansi16]
        _ -> false
      end
  end

  defp valid_cells?(_cells, count, count, _columns, _palette_count, _policy, _memo), do: true

  defp valid_cells?(cells, index, count, columns, palette_count, policy, memo) do
    case elem(cells, index) do
      {:glyph, text, width, style} ->
        if Cell.style?(style) and style < palette_count and is_integer(width) and
             width in 1..500 and rem(index, columns) + width <= columns do
          case validated_glyph(text, width, policy, memo) do
            false ->
              false

            memo ->
              continuations?(cells, index + 1, index + width, rem(index, columns)) and
                valid_cells?(cells, index + width, count, columns, palette_count, policy, memo)
          end
        else
          false
        end

      _ ->
        false
    end
  end

  # Per-plan policy is fixed. Only successful identity/width checks enter this
  # bounded memo; cell style, geometry and ownership are checked independently.
  defp validated_glyph(text, width, policy, memo) do
    key = {text, width}

    cond do
      MapSet.member?(memo, key) -> memo
      not Cell.glyph?(text, width, 0) -> false
      Width.cells(text, policy) != width -> false
      MapSet.size(memo) < 1024 -> MapSet.put(memo, key)
      true -> memo
    end
  end

  defp continuations?(_cells, ending, ending, _lead), do: true

  defp continuations?(cells, index, ending, lead),
    do:
      elem(cells, index) == {:continuation, lead} and
        continuations?(cells, index + 1, ending, lead)

  defp cursor?(nil, _), do: true

  defp cursor?(%Cursor{x: x, y: y, shape: shape, visible?: visible} = cursor, size),
    do:
      map_size(cursor) == 5 and unsigned?(x) and x < size.columns and unsigned?(y) and
        y < size.rows and shape in [:block, :bar, :underline] and is_boolean(visible)

  defp cursor?(_, _), do: false

  defp focus?(nil, _size), do: true

  defp focus?(%{region_id: region_id} = focus, size),
    do:
      not is_struct(focus) and
        Enum.all?(Map.keys(focus), &(&1 in [:region_id, :control_id, :rect])) and
        Cell.id?(region_id) and
        (is_nil(Map.get(focus, :control_id)) or Cell.id?(focus.control_id)) and
        (not Map.has_key?(focus, :rect) or rect?(focus.rect, size))

  defp focus?(_, _size), do: false

  defp actions?(actions, size, cells) do
    Enum.reduce_while(actions, %{}, fn {id, rects}, occupied ->
      if Cell.id?(id) and is_list(rects) and rects != [] do
        case rectangles?(rects, size, occupied, id) do
          false -> {:halt, false}
          total -> {:cont, total}
        end
      else
        {:halt, false}
      end
    end)
    |> case do
      false -> false
      occupied -> glyph_owners?(cells, 0, tuple_size(cells), occupied)
    end
  end

  defp rectangles?([], _size, occupied, _id), do: occupied

  defp rectangles?([rect | rest], size, occupied, id) do
    if rect?(rect, size) and
         map_size(occupied) + rect.width * rect.height <= size.columns * size.rows do
      case occupy_rectangle(rect, size.columns, occupied, id) do
        false -> false
        occupied -> rectangles?(rest, size, occupied, id)
      end
    else
      false
    end
  end

  defp rectangles?(_, _, _, _), do: false

  defp occupy_rectangle(rect, columns, occupied, id) do
    Enum.reduce_while(rect.y..(rect.y + rect.height - 1), occupied, fn y, occupied ->
      result =
        Enum.reduce_while(rect.x..(rect.x + rect.width - 1), occupied, fn x, occupied ->
          index = y * columns + x

          if Map.has_key?(occupied, index),
            do: {:halt, false},
            else: {:cont, Map.put(occupied, index, id)}
        end)

      if result == false, do: {:halt, false}, else: {:cont, result}
    end)
  end

  defp glyph_owners?(_cells, count, count, _occupied), do: true

  defp glyph_owners?(cells, index, count, occupied) do
    {:glyph, _text, width, _style} = elem(cells, index)
    owner = Map.get(occupied, index)

    same_owner?(occupied, index + 1, index + width, owner) and
      glyph_owners?(cells, index + width, count, occupied)
  end

  defp same_owner?(_occupied, ending, ending, _owner), do: true

  defp same_owner?(occupied, index, ending, owner),
    do: Map.get(occupied, index) == owner and same_owner?(occupied, index + 1, ending, owner)

  defp rect?(%Rect{x: x, y: y, width: width, height: height} = rect, size),
    do:
      map_size(rect) == 5 and Enum.all?([x, y, width, height], &unsigned?/1) and width > 0 and
        height > 0 and x + width <= size.columns and y + height <= size.rows

  defp rect?(_, _), do: false

  defp diagnostics?(diagnostics, actions), do: diagnostics?(diagnostics, actions, MapSet.new())
  defp diagnostics?([], _actions, _seen), do: true

  defp diagnostics?([{:clipped_action, id} | rest], actions, seen) do
    Cell.id?(id) and MapSet.size(seen) + map_size(actions) < 4096 and not MapSet.member?(seen, id) and
      not Map.has_key?(actions, id) and diagnostics?(rest, actions, MapSet.put(seen, id))
  end

  defp diagnostics?(_, _, _), do: false
end
