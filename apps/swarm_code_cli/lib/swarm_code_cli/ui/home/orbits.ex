defmodule SwarmCodeCLI.UI.Home.Orbits do
  @moduledoc """
  orbit U4: the geometry of the orbits, a port of the designer's `gen_D.py`.

  Each project is an arc, a half ellipse around the mark's ring centre: its
  conversations are beads on it, the newest at the top and the oldest at the
  bottom, spaced on a logarithmic age scale (now at the top, 30 days at the
  bottom). The arcs are braille, the beads one cell each, drawn over a gap in
  the braille. In `:compact` there is no room for ellipses and each project is a
  line with the same age scale running left to right.

  Everything here is pure: positions in braille dots and cells from the mark's
  centre, the columns of the orbits and the ages of the beads. The projector
  decides what a cell holds and in which role.
  """

  alias SwarmCodeCLI.UI.Home.Mark
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph

  @ratio 0.6
  @max_minutes 43_200
  @log_max :math.log(1 + @max_minutes)

  defstruct [:cxd, :cyd, :cols, :radii, :b, :r_top, :r_bot]

  @type t :: %__MODULE__{}

  @doc """
  The orbits around a mark of `size` drawn with its top-left cell at `{row, col}`,
  one per entry of `cols` (the column each reaches to its right).
  """
  @spec new(Mark.size(), {non_neg_integer(), non_neg_integer()}, [non_neg_integer()]) :: t()
  def new({_w, h} = size, {row, col}, cols) do
    {cx, cy, _radius} = Mark.centre(size)
    cxd = col * 2 + cx
    cyd = row * 4 + cy
    r_top = row
    r_bot = row + h - 1
    radii = Enum.map(cols, &(2 * &1 + 1 - cxd))
    half = max(abs(r_top * 4 - cyd), abs((r_bot + 1) * 4 - cyd))
    b = Enum.map(radii, &max(@ratio * &1, half + 3))

    %__MODULE__{
      cxd: cxd,
      cyd: cyd,
      cols: cols,
      radii: List.to_tuple(radii),
      b: List.to_tuple(b),
      r_top: r_top,
      r_bot: r_bot
    }
  end

  @doc "How far down a conversation of `minutes` age sits, 0.0 at now and 1.0 at 30 days."
  @spec frac_age(number()) :: float()
  def frac_age(minutes) do
    minutes |> max(0) |> min(@max_minutes) |> then(&(:math.log(1 + &1) / @log_max))
  end

  @doc "The row a conversation of `minutes` age sits on."
  @spec row_for(t(), number()) :: non_neg_integer()
  def row_for(%__MODULE__{r_top: top, r_bot: bottom}, minutes),
    do: top + round((bottom - top) * frac_age(minutes))

  @doc "Orbit `k`'s x in braille dots at the dot row `y`."
  @spec x_dot(t(), non_neg_integer(), number()) :: float()
  def x_dot(%__MODULE__{} = o, k, y) do
    ratio = (y - o.cyd) / elem(o.b, k)
    o.cxd + elem(o.radii, k) * :math.sqrt(max(0.0, 1 - ratio * ratio))
  end

  @doc "The cell column of orbit `k` on `row`: where a bead sits."
  @spec col_at(t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def col_at(%__MODULE__{} = o, k, row), do: div(trunc(x_dot(o, k, row * 4 + 2.5)), 2)

  @doc """
  Orbit `k`'s braille as `%{{row, col} => bits}` over the mark's rows. `step` is 1
  for this project's orbit and the selected one and 2 for the others (a dotted
  arc); `locked` is a set of `{row, col}` cells the arc must not write, the mark's.
  """
  @spec arc_cells(t(), non_neg_integer(), 1 | 2, MapSet.t()) :: %{
          {non_neg_integer(), non_neg_integer()} => 1..255
        }
  def arc_cells(%__MODULE__{} = o, k, step \\ 1, locked \\ MapSet.new()) do
    for y <- (o.r_top * 4)..((o.r_bot + 1) * 4 - 1)//step, reduce: %{} do
      acc ->
        x = trunc(x_dot(o, k, y + 0.5))
        key = {div(y, 4), div(x, 2)}

        if MapSet.member?(locked, key),
          do: acc,
          else:
            Map.update(
              acc,
              key,
              Mark.bit(rem(x, 2), rem(y, 4)),
              &Bitwise.bor(&1, Mark.bit(rem(x, 2), rem(y, 4)))
            )
    end
  end

  @doc """
  Where the beads of orbit `k` sit, for conversations of the given ages in minutes
  (newest first): `[{row, col}]`. A bead that would land on a row already taken
  moves down one row at a time while there is room.
  """
  @spec bead_spots(t(), non_neg_integer(), [number()]) :: [
          {non_neg_integer(), non_neg_integer()}
        ]
  def bead_spots(%__MODULE__{} = o, k, ages) do
    {spots, _taken} =
      Enum.map_reduce(ages, [], fn minutes, taken ->
        row = bump(row_for(o, minutes), taken, o.r_bot)
        {{row, col_at(o, k, row)}, [row | taken]}
      end)

    spots
  end

  defp bump(row, taken, bottom) do
    if row in taken and row < bottom, do: bump(row + 1, taken, bottom), else: row
  end

  @doc "The age labels down the right edge: `[{row, text}]` for now, 1 h, 1 d, 7 d and 30 d."
  @spec ticks(t()) :: [{non_neg_integer(), binary()}]
  def ticks(%__MODULE__{} = o) do
    [
      {o.r_top, "now"},
      {row_for(o, 60), "1 h"},
      {row_for(o, 1_440), "1 d"},
      {row_for(o, 10_080), "7 d"},
      {o.r_bot, "30 d"}
    ]
  end

  # ------------------------------------------------------------- line orbits

  @doc "The column of a bead of `minutes` age on a line orbit running from `t0` to `t1`."
  @spec line_x(integer(), integer(), number()) :: integer()
  def line_x(t0, t1, minutes), do: t0 + round((t1 - t0) * frac_age(minutes))

  @doc """
  The tick row under the line orbits: `[{col, text}]`. The first four sit at
  their age; "30 d" ends at `t1 + 1`.
  """
  @spec line_ticks(integer(), integer()) :: [{integer(), binary()}]
  def line_ticks(t0, t1) do
    [
      {line_x(t0, t1, 0), "now"},
      {line_x(t0, t1, 60), "1 h"},
      {line_x(t0, t1, 1_440), "1 d"},
      {line_x(t0, t1, 10_080), "7 d"},
      {t1 + 1 - 4, "30 d"}
    ]
  end

  # --------------------------------------------------------------- the beads

  @doc """
  A bead's glyph and role (`gen_D.py bead/1`), from a conversation with
  `updated_at`, `live`, `live_kind`, `waiting` and `unread` (a
  `DTO.HomeConversation` or a `DTO.ConversationSummary`) at time `now` (unix
  milliseconds): waiting is `!` (`:warning`), live a filled dot in its kind's role,
  unread a filled dot in plain text, updated within a day a filled dot in muted
  text and older a hollow faint one. Returns `{text, role, bold?}`.
  """
  @spec bead(map(), integer(), :rich | :measured | :ascii) :: {binary(), atom(), boolean()}
  def bead(conversation, now, tier) do
    cond do
      Map.get(conversation, :waiting, 0) > 0 ->
        {Glyph.get(:bang, tier), :warning, true}

      Map.get(conversation, :live, false) ->
        role =
          case Map.get(conversation, :live_kind) do
            nil -> :accent
            kind -> Mark.kind_role(kind)
          end

        {Glyph.get(:dot_on, tier), role, true}

      Map.get(conversation, :unread, false) ->
        {Glyph.get(:dot_on, tier), :text_primary, false}

      age_minutes(conversation, now) <= 1_440 ->
        {Glyph.get(:dot_on, tier), :text_muted, false}

      true ->
        {Glyph.get(:dot_off, tier), :text_faint, false}
    end
  end

  @doc "A conversation's age in minutes at `now` (milliseconds); never negative."
  @spec age_minutes(map(), integer()) :: non_neg_integer()
  def age_minutes(%{updated_at: at}, now) when is_integer(at) and is_integer(now),
    do: max(div(now - at, 60_000), 0)

  def age_minutes(_conversation, _now), do: @max_minutes
end
