defmodule SwarmCodeCLI.UI.Home.Mark do
  @moduledoc """
  orbit U3: the ncode mark on Home, a ring, five rising bars and a dot, drawn in
  braille from the desktop logo (`Frame.logo_mark/1`).

  The braille of the three sizes, 40x20, 32x16 and 24x12 cells, is rasterised at
  compile time by `Mark.Raster` (D22); nothing is computed per frame. Which dots
  are set never depends on data. What data changes is the role of each cell:

    * the **ring** is the month's budget: cells up to `frac` are lit (`:accent`,
      `:warning` from 90 %, `:error` at 100 %), the rest ghost; `frac: nil` is a
      ghost ring, the answer to "no budget yet";
    * the **bars** are the live runs, bottom to top: bar k is `nil` (an empty
      slot, `:disabled`) or `{role, progress}`, drawn in `role` up to `progress`
      percent of its height and `:text_faint` above;
    * the **dot** is `:on` (`:warning`, something waits for you), `:off` or
      `:ghost`.

  A cell's lit state is decided from its mean position along the bar or arc
  (`t_mid`, `f_mid`), where `d_mark.py` counted samples; the glyphs are the same.

  The compact inline glyph is not a raster: `"⢎⡁"` `"▂▃▅▆█"` and `"●"` at the rich
  glyph tier, their one-cell twins at the measured tier and `() .-=+# *` at ASCII.
  """

  alias SwarmCodeCLI.UI.Home.Mark.Raster
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph

  @sizes [{40, 20}, {32, 16}, {24, 12}]

  @elements Map.new(@sizes, fn {w, h} -> {{w, h}, Raster.cells(w, h)} end)

  @type size :: {pos_integer(), pos_integer()}
  @type bar :: nil | {atom(), 0..100 | nil}
  @type opts :: %{
          optional(:frac) => float() | nil,
          optional(:bars) => [bar()],
          optional(:dot) => :on | :off | :ghost
        }

  @doc "The sizes that are rasterised: `{columns, rows}`."
  @spec sizes() :: [size()]
  def sizes, do: @sizes

  @doc "The mark size of a Home layout class, or nil for the classes with the inline glyph."
  @spec size(atom()) :: size() | nil
  def size(:orbit_l), do: {40, 20}
  def size(:orbit_m), do: {32, 16}
  def size(:orbit_s), do: {24, 12}
  def size(_class), do: nil

  @doc "Every cell of the mark with its element, `[{row, col, char, element}]`, row-major."
  @spec elements(size()) :: [{non_neg_integer(), non_neg_integer(), binary(), term()}]
  def elements(size), do: Map.fetch!(@elements, size)

  @doc "The `{row, col}` set of the mark's cells: what an arc must not draw over."
  @spec cell_set(size()) :: MapSet.t({non_neg_integer(), non_neg_integer()})
  def cell_set(size),
    do: MapSet.new(elements(size), fn {row, col, _char, _element} -> {row, col} end)

  @doc """
  The ring's centre and radius in braille dots, relative to the mark box's origin
  (the arcs of the orbits are centred on it): `{cx, cy, radius}`.
  """
  @spec centre(size()) :: {float(), float(), float()}
  def centre({w, h}) do
    s = min(2 * w, 4 * h) / 520.0
    ox = (2 * w - 520 * s) / 2
    oy = (4 * h - 520 * s) / 2
    %{cx: cx, cy: cy} = Raster.geometry()
    {(cx + 30) * s + ox, cy * s + oy, Raster.ring_radius() * s}
  end

  @doc """
  The mark's cells with their roles: `[{row, col, char, role}]`, row-major. `opts`
  is `%{frac: nil | float, bars: [bar] (five), dot: :on | :off | :ghost}`; every
  key is optional (a ghost ring, five empty slots, a ghost dot).
  """
  @spec cells(size(), opts()) :: [{non_neg_integer(), non_neg_integer(), binary(), atom()}]
  def cells(size, opts \\ %{}) do
    frac = opts |> Map.get(:frac) |> clamp_frac()
    bars = opts |> Map.get(:bars, []) |> pad_bars()
    dot = Map.get(opts, :dot, :ghost)

    for {row, col, char, element} <- elements(size) do
      {row, col, char, role(element, frac, bars, dot)}
    end
  end

  @doc "The role of one element under the data (the whole of what is chosen at run time)."
  @spec role(term(), float() | nil, [bar()], :on | :off | :ghost) :: atom()
  def role(:dot, _frac, _bars, :on), do: :warning
  def role(:dot, _frac, _bars, _dot), do: :text_ghost

  def role({:bar, k, t_mid}, _frac, bars, _dot) do
    case Enum.at(bars, k) do
      nil -> :disabled
      {role, nil} -> role
      {role, progress} -> if t_mid <= progress / 100, do: role, else: :text_faint
    end
  end

  def role({:ring, f_mid}, frac, _bars, _dot), do: ring_role(frac, frac != nil and f_mid <= frac)

  def role({:ring_cap, :start}, frac, _bars, _dot),
    do: ring_role(frac, frac != nil and frac > 0.0)

  def role({:ring_cap, :end}, frac, _bars, _dot), do: ring_role(frac, frac != nil and frac >= 1.0)

  defp ring_role(_frac, false), do: :text_ghost
  defp ring_role(frac, true) when frac >= 1.0, do: :error
  defp ring_role(frac, true) when frac >= 0.9, do: :warning
  defp ring_role(_frac, true), do: :accent

  defp clamp_frac(nil), do: nil
  defp clamp_frac(frac) when is_number(frac), do: max(frac / 1, 0.0)

  defp pad_bars(bars), do: Enum.take(bars ++ List.duplicate(nil, 5), 5)

  @doc "The role a run of this kind draws in (`chat` is plain text)."
  @spec kind_role(atom()) :: atom()
  def kind_role(:goal), do: :run_goal
  def kind_role(:swarm), do: :run_swarm
  def kind_role(:workflow), do: :run_workflow
  def kind_role(:research), do: :run_research
  def kind_role(:consensus), do: :run_consensus_judge
  def kind_role(:ultra), do: :run_ultra
  def kind_role(_chat), do: :text_primary

  @doc """
  The compact inline glyph for a glyph tier (`:rich`, `:measured` or `:ascii`) as
  `[{text, role}]`: the ring (one segment), the five bars, a space and the dot.
  `opts` is the same map as `cells/2`; a bar's role is its run's whole, since one
  cell holds no progress.
  """
  @spec inline(:rich | :measured | :ascii, opts()) :: [{binary(), atom()}]
  def inline(tier, opts \\ %{}) when tier in [:rich, :measured, :ascii] do
    frac = opts |> Map.get(:frac) |> clamp_frac()
    bars = opts |> Map.get(:bars, []) |> pad_bars()
    dot = Map.get(opts, :dot, :ghost)

    ring_lit = if frac == nil, do: :text_ghost, else: ring_role(frac, frac > 0.0)

    ring =
      case tier do
        :ascii -> "()"
        _ -> "⢎⡁"
      end

    bar_cells =
      for {token, bar} <- Enum.zip([:spark_2, :spark_3, :spark_5, :spark_6, :spark_8], bars) do
        role =
          case bar do
            nil -> :disabled
            {role, _progress} -> role
          end

        {Glyph.get(token, tier), role}
      end

    dot_role = if dot == :on, do: :warning, else: :text_ghost

    [{ring, ring_lit}] ++ bar_cells ++ [{" ", :text_ghost}, {Glyph.get(:dot_on, tier), dot_role}]
  end
end
