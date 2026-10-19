defmodule SwarmCodeCLI.UI.Home.Grid do
  @moduledoc """
  orbit U4: the size classes of Home and the rows and columns each one gives its
  parts. Pure arithmetic on the terminal size; nothing here reads state.

  | class | when | mark | orbits | preview |
  |---|---|---|---|---|
  | `:orbit_l` | 150 x 40 and up | 40 x 20 | up to 6 | yes |
  | `:orbit_m` | 120 x 34 and up | 32 x 16 | up to 4 | yes |
  | `:orbit_s` | 100 x 30 and up | 24 x 12 | up to 3 | no |
  | `:compact` | 72 x 20 and up | the inline glyph | line orbits, up to 4 | no |
  | `:minimal` | 50 x 14 and up | the inline glyph | none | no |
  | `:too_small` | anything less | the CLI's tiny screen | | |

  The ASCII glyph tier draws no braille (D23), so every class at or above
  `:orbit_s` is `:compact` there.

  The rows of the three orbit classes follow one rule (D-main-dark, D-wide): the
  mark starts on row 2, its last row is `r_bot`, the project counts sit on
  `r_bot + 1`, the legend on `r_bot + 2 ..`, the list header on `r_bot + 6` and the
  list from `r_bot + 7`, nine rows at most. The composer is the third row from
  the bottom, then the hint row and the status row.
  """

  @max_list 9

  @type class :: :orbit_l | :orbit_m | :orbit_s | :compact | :minimal | :too_small
  @type t :: %{
          class: class(),
          columns: pos_integer(),
          rows: pos_integer(),
          mark: nil | {pos_integer(), pos_integer()},
          mark_origin: {non_neg_integer(), non_neg_integer()},
          orbit_slots: non_neg_integer(),
          orbit_first: non_neg_integer(),
          orbit_last: non_neg_integer(),
          preview?: boolean(),
          wide_extras?: boolean(),
          list_rows: non_neg_integer(),
          r_top: non_neg_integer(),
          r_bot: non_neg_integer(),
          count_row: non_neg_integer(),
          legend_row: non_neg_integer(),
          header_row: non_neg_integer(),
          list_first: non_neg_integer(),
          composer_row: non_neg_integer(),
          hint_row: non_neg_integer(),
          status_row: non_neg_integer()
        }

  @doc "The class of a terminal of `columns` x `rows` at the glyph tier `tier`."
  @spec class(pos_integer(), pos_integer(), :rich | :measured | :ascii) :: class()
  def class(columns, rows, tier \\ :rich) do
    class =
      cond do
        columns >= 150 and rows >= 40 -> :orbit_l
        columns >= 120 and rows >= 34 -> :orbit_m
        columns >= 100 and rows >= 30 -> :orbit_s
        columns >= 72 and rows >= 20 -> :compact
        columns >= 50 and rows >= 14 -> :minimal
        true -> :too_small
      end

    if tier == :ascii and class in [:orbit_l, :orbit_m, :orbit_s], do: :compact, else: class
  end

  @doc """
  Everything the projector needs to place Home's parts at this size. `n_orbits`
  (how many projects there are to draw, default 4) only matters to `:compact`,
  whose line orbits push the list down.
  """
  @spec for(pos_integer(), pos_integer(), :rich | :measured | :ascii, non_neg_integer()) :: t()
  def for(columns, rows, tier \\ :rich, n_orbits \\ 4) do
    build(class(columns, rows, tier), columns, rows, n_orbits)
  end

  defp build(class, columns, rows, _n_orbits) when class in [:orbit_l, :orbit_m, :orbit_s] do
    {mark, slots, first, last, preview?, wide?} =
      case class do
        :orbit_l -> {{40, 20}, 6, 64, max(120, 130 + (columns - 160)), true, true}
        :orbit_m -> {{32, 16}, 4, 52, 100 + (columns - 120), true, false}
        :orbit_s -> {{24, 12}, 3, 44, columns - 20, false, false}
      end

    {_w, h} = mark
    r_top = 2
    r_bot = r_top + h - 1
    list_first = r_bot + 7
    composer = rows - 3
    # the wide class keeps three rows for "before you start something big" and a blank
    below_list = if wide?, do: 4, else: 0

    base(class, columns, rows)
    |> Map.merge(%{
      mark: mark,
      mark_origin: {r_top, 4},
      orbit_slots: slots,
      orbit_first: first,
      orbit_last: last,
      preview?: preview?,
      wide_extras?: wide?,
      r_top: r_top,
      r_bot: r_bot,
      count_row: r_bot + 1,
      legend_row: r_bot + 2,
      header_row: r_bot + 6,
      list_first: list_first,
      list_rows: list_rows(composer - list_first - below_list, 3)
    })
  end

  defp build(:compact, columns, rows, n_orbits) do
    lines = min(max(rows - 20, 0), min(n_orbits, 4))
    orbits_first = 5
    # the ticks row closes the line orbits; with none there is neither
    header = if lines > 0, do: orbits_first + lines + 1, else: orbits_first
    list_first = header + 1

    base(:compact, columns, rows)
    |> Map.merge(%{
      mark: nil,
      mark_origin: {2, 2},
      orbit_slots: lines,
      r_top: orbits_first,
      r_bot: orbits_first + max(lines - 1, 0),
      count_row: orbits_first + lines,
      legend_row: 2,
      header_row: header,
      list_first: list_first,
      # a blank row stands above the composer
      list_rows: list_rows(rows - 4 - list_first, 3)
    })
  end

  defp build(:minimal, columns, rows, _n_orbits) do
    list_first = 5

    base(:minimal, columns, rows)
    |> Map.merge(%{
      mark: nil,
      mark_origin: {2, 2},
      orbit_slots: 0,
      r_top: 2,
      r_bot: 2,
      count_row: 2,
      legend_row: 2,
      header_row: 4,
      list_first: list_first,
      list_rows: list_rows(rows - 4 - list_first, 1)
    })
  end

  defp build(:too_small, columns, rows, _n_orbits) do
    base(:too_small, columns, rows)
    |> Map.merge(%{
      mark: nil,
      mark_origin: {0, 0},
      orbit_slots: 0,
      r_top: 0,
      r_bot: 0,
      count_row: 0,
      legend_row: 0,
      header_row: 0,
      list_first: 0,
      list_rows: 0
    })
  end

  defp base(class, columns, rows) do
    %{
      class: class,
      columns: columns,
      rows: rows,
      mark: nil,
      mark_origin: {0, 0},
      orbit_slots: 0,
      orbit_first: 0,
      orbit_last: 0,
      preview?: false,
      wide_extras?: false,
      composer_row: rows - 3,
      hint_row: rows - 2,
      status_row: rows - 1
    }
  end

  defp list_rows(available, least), do: available |> min(@max_list) |> max(least)

  @doc """
  The columns of the first `count` orbits of a grid:
  `round(first + k * (last - first) / (slots - 1))` over `max(4, count)` slots,
  at most the class's. Fewer projects than slots leave the outer slots empty.
  """
  @spec orbit_columns(t(), non_neg_integer()) :: [non_neg_integer()]
  def orbit_columns(%{class: class}, _count) when class not in [:orbit_l, :orbit_m, :orbit_s],
    do: []

  def orbit_columns(grid, count) do
    slots = grid.orbit_slots |> min(max(4, count))
    span = grid.orbit_last - grid.orbit_first

    for k <- 0..(slots - 1)//1 |> Enum.take(count) do
      if slots == 1, do: grid.orbit_first, else: round(grid.orbit_first + k * span / (slots - 1))
    end
  end

  @doc "The line orbits' rule runs from this column to that one (`:compact`)."
  @spec line_range(pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  def line_range(columns), do: {18, columns - 5}
end
