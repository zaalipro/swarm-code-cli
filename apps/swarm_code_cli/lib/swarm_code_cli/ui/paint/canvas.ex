defmodule SwarmCodeCLI.UI.Paint.Canvas do
  @moduledoc "Persistent bounded cell construction with whole-glyph overpainting."
  alias SwarmCodeCLI.UI.Size
  alias SwarmCodeCLI.UI.Scene.Rect
  alias SwarmCodeCLI.UI.Paint.Cell

  @enforce_keys [:size, :cells, :owners, :blank_style]
  defstruct [:size, :cells, :owners, :blank_style]

  @opaque t :: %__MODULE__{
            size: Size.t(),
            cells: :array.array(Cell.t()),
            owners: :array.array(binary() | nil),
            blank_style: non_neg_integer()
          }
  @type error :: {:error, :invalid_size | :invalid_cell | :invalid_rect | :capacity_exceeded}

  @spec new(term(), term()) :: {:ok, t()} | error()
  def new(size, blank_style \\ 0) do
    with {:ok, %Size{columns: columns, rows: rows}} <- Size.validate(size) do
      cond do
        columns > 500 or rows > 200 or columns * rows > 100_000 ->
          {:error, :capacity_exceeded}

        not Cell.style?(blank_style) ->
          {:error, :invalid_cell}

        true ->
          count = columns * rows

          {:ok,
           %__MODULE__{
             size: size,
             blank_style: blank_style,
             cells: :array.new(count, default: {:glyph, " ", 1, blank_style}, fixed: true),
             owners: :array.new(count, default: nil, fixed: true)
           }}
      end
    end
  end

  @spec put(t(), term(), term(), term(), term(), term(), term()) :: {:ok, t()} | error()
  def put(canvas, x, y, glyph, width, style, action_id \\ nil)

  def put(%__MODULE__{} = canvas, x, y, glyph, width, style, action_id) do
    cond do
      not Cell.glyph?(glyph, width, style) or not (is_nil(action_id) or Cell.id?(action_id)) ->
        {:error, :invalid_cell}

      not position?(canvas.size, x, y) ->
        {:error, :invalid_rect}

      x + width > canvas.size.columns ->
        {:ok, canvas}

      true ->
        cleared = clear_overhangs(canvas, x, y, width)

        painted =
          Enum.reduce(x..(x + width - 1), cleared, fn column, acc ->
            cell = if column == x, do: {:glyph, glyph, width, style}, else: {:continuation, x}
            set(acc, column, y, cell, action_id)
          end)

        {:ok, painted}
    end
  end

  def put(_, _, _, _, _, _, _), do: {:error, :invalid_cell}

  @spec fill(t(), term(), term()) :: {:ok, t()} | error()
  def fill(%__MODULE__{} = canvas, rect, style) do
    cond do
      not Cell.style?(style) ->
        {:error, :invalid_cell}

      not rectangle?(canvas.size, rect) ->
        {:error, :invalid_rect}

      rect.width == 0 or rect.height == 0 ->
        {:ok, canvas}

      true ->
        painted =
          Enum.reduce(rect.y..(rect.y + rect.height - 1), canvas, fn row, acc ->
            cleared = clear_overhangs(acc, rect.x, row, rect.width)

            Enum.reduce(rect.x..(rect.x + rect.width - 1), cleared, fn column, acc ->
              fill_cell(acc, column, row, style)
            end)
          end)

        {:ok, painted}
    end
  end

  def fill(_, _, _), do: {:error, :invalid_cell}

  @spec finish(t()) :: tuple()
  def finish(%__MODULE__{cells: cells}), do: cells |> :array.to_list() |> List.to_tuple()

  @spec actions(t()) :: %{optional(binary()) => [Rect.t()]}
  def actions(%__MODULE__{size: %Size{columns: columns, rows: rows}} = canvas) do
    Enum.reduce(0..(rows - 1), %{}, fn y, acc -> row_actions(canvas, y, 0, columns, acc) end)
    |> Map.new(fn {id, rects} -> {id, Enum.reverse(rects)} end)
  end

  defp row_actions(_canvas, _y, x, columns, acc) when x == columns, do: acc

  defp row_actions(canvas, y, x, columns, acc) do
    case :array.get(y * columns + x, canvas.owners) do
      nil ->
        row_actions(canvas, y, x + 1, columns, acc)

      id ->
        ending = owner_end(canvas.owners, y * columns, x + 1, columns, id)
        rect = %Rect{x: x, y: y, width: ending - x, height: 1}
        row_actions(canvas, y, ending, columns, Map.update(acc, id, [rect], &[rect | &1]))
    end
  end

  defp owner_end(_owners, _base, x, columns, _id) when x == columns, do: x

  defp owner_end(owners, base, x, columns, id) do
    if :array.get(base + x, owners) == id,
      do: owner_end(owners, base, x + 1, columns, id),
      else: x
  end

  # The caller overwrites every cell inside its range. Only the two boundary
  # glyphs can extend outside it and need separate clearing.
  defp clear_overhangs(canvas, x, y, width) do
    base = y * canvas.size.columns
    left = lead_column(canvas.cells, base, x)
    ending = x + width
    right = lead_column(canvas.cells, base, ending - 1)
    {:glyph, _, right_width, _} = :array.get(base + right, canvas.cells)

    canvas
    |> clear_columns(left, x, y)
    |> clear_columns(ending, right + right_width, y)
  end

  defp lead_column(cells, base, column) do
    case :array.get(base + column, cells) do
      {:continuation, lead} -> lead
      {:glyph, _, _, _} -> column
    end
  end

  defp clear_columns(canvas, start, ending, _y) when start >= ending, do: canvas

  defp clear_columns(canvas, start, ending, y) do
    Enum.reduce(start..(ending - 1), canvas, fn column, acc ->
      set(acc, column, y, {:glyph, " ", 1, canvas.blank_style}, nil)
    end)
  end

  defp fill_cell(canvas, x, y, style) do
    index = y * canvas.size.columns + x
    cell = {:glyph, " ", 1, style}

    if :array.get(index, canvas.cells) == cell and is_nil(:array.get(index, canvas.owners)),
      do: canvas,
      else: set(canvas, x, y, cell, nil)
  end

  defp set(canvas, x, y, cell, owner) do
    index = y * canvas.size.columns + x

    %{
      canvas
      | cells: :array.set(index, cell, canvas.cells),
        owners: :array.set(index, owner, canvas.owners)
    }
  end

  defp position?(%Size{columns: columns, rows: rows}, x, y),
    do: is_integer(x) and x >= 0 and x < columns and is_integer(y) and y >= 0 and y < rows

  defp rectangle?(
         %Size{columns: columns, rows: rows},
         %Rect{x: x, y: y, width: width, height: height} = rect
       ),
       do:
         map_size(rect) == 5 and Enum.all?([x, y, width, height], &(is_integer(&1) and &1 >= 0)) and
           x + width <= columns and y + height <= rows

  defp rectangle?(_, _), do: false
end
