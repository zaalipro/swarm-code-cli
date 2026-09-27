defmodule SwarmCodeCLI.UI.Settings.Grid do
  @moduledoc """
  Every column and row number of the settings layer (pass 75, E) from the
  terminal's `{columns, rows}`, in one pure module. The projector, `Nav`'s
  page step, the enum editor's window and the tests read the same numbers.

  Four classes by width:

    * `:wide` (160 columns and more): rail, page and the note column
      (rail 2-25, page 30-111, note spine 116, note text 118-157).
    * `:rail` (120-159): rail and a page of `columns - 32` cells; the note
      becomes a 3-line drawer under the focused row.
    * `:strip` (90-119): no rail; a section strip on row 2 and a page of
      `columns - 4` cells from column 2.
    * `:small` (80-89): the page from column 1, `columns - 2` cells, a
      narrower label column and a 2-line drawer.

  Below 80 × 20 the grid is `:too_small` and only `class`, `columns` and
  `rows` are set.
  """

  defstruct [
    :class,
    :columns,
    :rows,
    :margin,
    :rail,
    :page,
    :note,
    :body_top,
    :body_rows,
    :message_row,
    :status_row,
    :strip_row,
    :label_width,
    :value_offset,
    :drawer_lines,
    :well_width
  ]

  @type class :: :wide | :rail | :strip | :small | :too_small
  @type span :: %{left: non_neg_integer(), width: pos_integer()}
  @type t :: %__MODULE__{
          class: class(),
          columns: pos_integer(),
          rows: pos_integer(),
          margin: 0..2,
          rail: span() | nil,
          page: span(),
          note: %{spine: non_neg_integer(), left: non_neg_integer(), width: pos_integer()} | nil,
          body_top: non_neg_integer(),
          body_rows: pos_integer(),
          message_row: non_neg_integer(),
          status_row: non_neg_integer(),
          strip_row: non_neg_integer() | nil,
          label_width: 19 | 29,
          value_offset: 23 | 33,
          drawer_lines: 0 | 2 | 3,
          well_width: 34 | 40 | 80
        }

  @wide 160
  @rail 120
  @strip 90
  @small 80
  @min_rows 20

  @doc "The layout class of a terminal `columns` wide."
  @spec class(pos_integer()) :: class()
  def class(columns) when columns >= @wide, do: :wide
  def class(columns) when columns >= @rail, do: :rail
  def class(columns) when columns >= @strip, do: :strip
  def class(columns) when columns >= @small, do: :small
  def class(_columns), do: :too_small

  @doc "The grid of a `columns` × `rows` terminal."
  @spec for(pos_integer(), pos_integer()) :: t()
  def for(columns, rows) do
    class = class(columns)

    if class == :too_small or rows < @min_rows do
      %__MODULE__{class: :too_small, columns: columns, rows: rows}
    else
      grid = fields(columns, class)

      %{
        grid
        | columns: columns,
          rows: rows,
          body_rows: rows - grid.body_top - 4,
          message_row: rows - 3,
          status_row: rows - 1
      }
    end
  end

  defp fields(_columns, :wide) do
    %__MODULE__{
      class: :wide,
      margin: 2,
      rail: %{left: 2, width: 24},
      page: %{left: 30, width: 82},
      note: %{spine: 116, left: 118, width: 40},
      body_top: 3,
      strip_row: nil,
      label_width: 29,
      value_offset: 33,
      drawer_lines: 0,
      well_width: 80
    }
  end

  defp fields(columns, :rail) do
    %{
      fields(columns, :wide)
      | class: :rail,
        page: %{left: 30, width: columns - 32},
        note: nil,
        drawer_lines: 3
    }
  end

  defp fields(columns, :strip) do
    %__MODULE__{
      class: :strip,
      margin: 1,
      rail: nil,
      page: %{left: 2, width: columns - 4},
      note: nil,
      body_top: 4,
      strip_row: 2,
      label_width: 29,
      value_offset: 33,
      drawer_lines: 3,
      well_width: 40
    }
  end

  defp fields(columns, :small) do
    %__MODULE__{
      class: :small,
      margin: 1,
      rail: nil,
      page: %{left: 1, width: columns - 2},
      note: nil,
      body_top: 2,
      strip_row: nil,
      label_width: 19,
      value_offset: 23,
      drawer_lines: 2,
      well_width: 34
    }
  end

  @doc "The PgUp/PgDn step: the body's row count, never less than 3."
  @spec page_height(t()) :: pos_integer()
  def page_height(%__MODULE__{body_rows: rows}) when is_integer(rows), do: max(rows, 3)
  def page_height(%__MODULE__{}), do: 3

  @doc "The mark slot's column (one right of the spine)."
  @spec mark_col(t()) :: non_neg_integer()
  def mark_col(%__MODULE__{page: page}), do: page.left + 1

  @doc "The label's column."
  @spec label_col(t()) :: non_neg_integer()
  def label_col(%__MODULE__{page: page}), do: page.left + 3

  @doc "The value's column."
  @spec value_col(t()) :: non_neg_integer()
  def value_col(%__MODULE__{page: page, value_offset: offset}), do: page.left + offset

  @doc "The column a right-aligned tag ends on."
  @spec tag_right(t()) :: non_neg_integer()
  def tag_right(%__MODULE__{page: page}), do: page.left + page.width - 1
end
