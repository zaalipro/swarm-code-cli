defmodule SwarmCodeCLI.UI.Home.Mark.Raster do
  @moduledoc """
  orbit U3: the ncode mark rasterised to braille cells. A port of the designer's
  `d_mark.py` (`~/.cache/ncode/cli-dash/d_mark.py`), run once at compile time by
  `SwarmCodeCLI.UI.Home.Mark`; nothing here runs per frame.

  The geometry is the desktop logo's (`Frame.logo_mark/1`, viewBox `-30 0 520 520`,
  stroke 36, round caps): an open ring with its gap on the right, five rising
  bars (the middle one split around the dot) and the dot at (259.3, 319.4).

  `classify/6` says which element one sample point hits, without any data:
  `:dot`, `{:bar, k, t}` (t is the projection along bar k, bottom to top),
  `{:ring, f}` (f is the arc fraction from P1), `{:ring_cap, :start | :end}`
  or `nil`. `cells/2` samples a W x H cell box 3 x 3 per braille dot and keeps
  a dot when at least 4 of its 9 samples hit. Which dots are set is
  data-independent; only the role of a cell depends on the ring fraction and the
  bar progress, so each cell stores its dominant element and `Mark` picks the
  role at run time.

  Unlike `d_mark.py`, a cell's lit/unlit state is not counted per sample but
  decided from the cell's mean `t` or `f` (`t_mid`, `f_mid`): the same answer
  except where a progress boundary falls inside one cell, and the cell is then
  lit or unlit as a whole.
  """

  @p1 {313.1, 41.3}
  @p2 {365.1, 455.5}
  @rr 223.5
  @sw 36.0
  # bottom -> top for each bar; bar 3 (index 2) is drawn as two segments around the dot
  @bars [
    {{124.5, 353.9}, {131.9, 303.9}},
    {{182.0, 393.9}, {201.2, 265.1}},
    {{247.5, 416.5}, {276.8, 218.5}},
    {{317.3, 404.2}, {351.7, 173.4}},
    {{387.3, 367.7}, {424.7, 117.9}}
  ]
  @bar3_segs [{{247.5, 416.5}, {254.9, 367.5}}, {{268.2, 275.5}, {276.8, 218.5}}]
  @dot {259.3, 319.4, 22.5}
  @bit %{
    {0, 0} => 0x01,
    {0, 1} => 0x02,
    {0, 2} => 0x04,
    {1, 0} => 0x08,
    {1, 1} => 0x10,
    {1, 2} => 0x20,
    {0, 3} => 0x40,
    {1, 3} => 0x80
  }
  @ss 3
  @cover 4
  @halo_dots 0.8

  @type element :: :dot | {:bar, 0..4, float()} | {:ring, float()} | {:ring_cap, :start | :end}

  @doc "The ring's centre and the arc's start angle and span, in logo units and degrees."
  @spec geometry() :: %{cx: float(), cy: float(), a1: float(), span: float()}
  def geometry do
    {p1x, p1y} = @p1
    {p2x, p2y} = @p2
    mx = (p1x + p2x) / 2
    my = (p1y + p2y) / 2
    dx = p2x - p1x
    dy = p2y - p1y
    len = hypot(dx, dy)
    h = :math.sqrt(@rr * @rr - len / 2 * (len / 2))
    cx = mx - dy / len * h
    cy = my + dx / len * h
    a1 = angle(cx, cy, p1x, p1y)
    %{cx: cx, cy: cy, a1: a1, span: mod360(angle(cx, cy, p2x, p2y) - a1)}
  end

  @doc "The ring's radius in logo units."
  def ring_radius, do: @rr

  @doc """
  Which element the point `(u, v)` (logo units) hits. `thick` scales the stroke,
  `dotk` the dot, `halo` is the bar-3 clearance around the dot.
  """
  @spec classify(float(), float(), map(), float(), float(), float()) :: element() | nil
  def classify(u, v, geo, thick, dotk, halo) do
    hw = @sw / 2 * thick
    {dot_x, dot_y, dot_r} = @dot
    dd = hypot(u - dot_x, v - dot_y)

    if dd <= dot_r * dotk do
      :dot
    else
      case bar_hit(u, v, hw, dd <= dot_r * dotk + halo) do
        :cleared -> nil
        {:bar, _, _} = bar -> bar
        nil -> ring_hit(u, v, geo, hw)
      end
    end
  end

  defp bar_hit(u, v, hw, near_dot?) do
    @bars
    |> Enum.with_index()
    |> Enum.find_value(fn {{a, b}, k} ->
      segs = if k == 2, do: @bar3_segs, else: [{a, b}]

      if Enum.any?(segs, fn {sa, sb} -> elem(seg(u, v, sa, sb), 0) <= hw end) do
        if k == 2 and near_dot?, do: :cleared, else: {:bar, k, elem(seg(u, v, a, b), 1)}
      end
    end)
  end

  defp ring_hit(u, v, %{cx: cx, cy: cy, a1: a1, span: span}, hw) do
    d = hypot(u - cx, v - cy)
    f = mod360(angle(cx, cy, u, v) - a1) / span
    {p1x, p1y} = @p1
    {p2x, p2y} = @p2

    cond do
      abs(d - @rr) <= hw and f <= 1.0 -> {:ring, f}
      hypot(u - p1x, v - p1y) <= hw -> {:ring_cap, :start}
      hypot(u - p2x, v - p2y) <= hw -> {:ring_cap, :end}
      true -> nil
    end
  end

  # distance from (px, py) to the segment a-b, and the unclamped projection t
  defp seg(px, py, {ax, ay}, {bx, by}) do
    vx = bx - ax
    vy = by - ay
    t = ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)
    tc = max(0.0, min(1.0, t))
    {hypot(px - (ax + tc * vx), py - (ay + tc * vy)), t}
  end

  defp hypot(x, y), do: :math.sqrt(x * x + y * y)

  defp angle(cx, cy, x, y), do: mod360(:math.atan2(-(y - cy), x - cx) * (180.0 / :math.pi()))

  defp mod360(x) do
    m = :math.fmod(x, 360.0)
    if m < 0.0, do: m + 360.0, else: m
  end

  @doc """
  The mark in a `w` x `h` cell box as `[{row, col, char, element}]`, row-major.
  `element` is `:dot`, `{:bar, k, t_mid}`, `{:ring, f_mid}` or `{:ring_cap, side}`.
  """
  @spec cells(pos_integer(), pos_integer()) :: [
          {non_neg_integer(), non_neg_integer(), binary(), element()}
        ]
  def cells(w, h) do
    geo = geometry()
    s = min(2 * w, 4 * h) / 520.0
    ox = (2 * w - 520 * s) / 2
    oy = (4 * h - 520 * s) / 2
    halo = @halo_dots / s

    grid =
      for j <- 0..(4 * h - 1), i <- 0..(2 * w - 1), reduce: %{} do
        acc ->
          samples =
            for a <- 0..(@ss - 1), b <- 0..(@ss - 1), reduce: [] do
              hits ->
                u = (i + (a + 0.5) / @ss - ox) / s - 30
                v = (j + (b + 0.5) / @ss - oy) / s

                case classify(u, v, geo, 1.0, 1.0, halo) do
                  nil -> hits
                  element -> [element | hits]
                end
            end
            |> Enum.reverse()

          if length(samples) < @cover, do: acc, else: add_dot(acc, i, j, samples)
      end

    grid
    |> Enum.sort()
    |> Enum.map(fn {{row, col}, %{bits: bits, els: els}} ->
      {row, col, <<0x2800 + bits::utf8>>, cell_element(els)}
    end)
  end

  # The dot's dominant element (dot > bar > ring on ties, then first seen), and
  # its samples' mean parameter, added to the cell.
  defp add_dot(acc, i, j, samples) do
    keys = Enum.map(samples, &key/1)
    freq = Enum.frequencies(keys)

    winner =
      keys
      |> Enum.uniq()
      |> Enum.max_by(fn k -> {Map.fetch!(freq, k), k == :dot, match?({:bar, _}, k)} end)

    params = for sample <- samples, key(sample) == winner, do: param(sample)
    n = length(params)
    sum = Enum.sum(params)
    cell = {div(j, 4), div(i, 2)}
    bit = Map.fetch!(@bit, {rem(i, 2), rem(j, 4)})

    Map.update(
      acc,
      cell,
      %{bits: bit, els: %{winner => {1, n, sum}}},
      fn %{bits: bits, els: els} ->
        els =
          Map.update(els, winner, {1, n, sum}, fn {dots, count, total} ->
            {dots + 1, count + n, total + sum}
          end)

        %{bits: Bitwise.bor(bits, bit), els: els}
      end
    )
  end

  defp key(:dot), do: :dot
  defp key({:bar, k, _t}), do: {:bar, k}
  defp key({:ring, _f}), do: :ring
  defp key({:ring_cap, side}), do: {:ring_cap, side}

  defp param({:bar, _k, t}), do: t
  defp param({:ring, f}), do: f
  defp param({:ring_cap, :start}), do: 0.0
  defp param({:ring_cap, :end}), do: 1.0
  defp param(:dot), do: 0.0

  # The cell's element: a dot wins, then the bar with most dots, then the ring.
  defp cell_element(els) do
    bars = for {{:bar, k}, stat} <- els, do: {k, stat}

    cond do
      Map.has_key?(els, :dot) ->
        :dot

      bars != [] ->
        {k, {_dots, n, total}} = Enum.max_by(bars, fn {k, {dots, _, _}} -> {dots, -k} end)
        {:bar, k, total / n}

      Map.has_key?(els, :ring) ->
        {_dots, n, total} = ring_mass(els)
        {:ring, total / n}

      true ->
        {side, _} =
          els
          |> Enum.filter(&match?({{:ring_cap, _}, _}, &1))
          |> Enum.map(fn {{:ring_cap, side}, {dots, _, _}} -> {side, dots} end)
          |> Enum.max_by(&elem(&1, 1))

        {:ring_cap, side}
    end
  end

  # the ring's samples and the caps' (a cap counts as the arc's end it closes)
  defp ring_mass(els) do
    for {key, {dots, n, total}} <- els,
        key == :ring or match?({:ring_cap, _}, key),
        reduce: {0, 0, 0.0} do
      {d, c, t} -> {d + dots, c + n, t + total}
    end
  end
end
