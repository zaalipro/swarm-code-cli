defmodule SwarmCodeCLI.UI.Projector.Panel.Draw do
  @moduledoc """
  Row assembly for the side panel. A row is a list of segments
  `{text, role}` or `{text, role, modifiers}` on the left and the same on the
  right; `row/5` measures every segment with `Width.cells/2` under the
  state's ambiguous-width policy, elides the left side where it would meet
  the right one, and pads the row to exactly `width` cells, so no row can
  wrap or reach past the pane's edge (the owner's pass-70 bug). The optional
  background role (`:card` for the needs-you band) fills the whole row.
  """
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.Density
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph

  @doc "A style for `role` with `modifiers`, on `background` (a role) when given."
  def style(role, state, modifiers \\ [], background \\ nil) do
    caps = state.capabilities
    themed = Theme.style(role, caps)
    plain = Theme.style(:plain, caps)

    bg =
      cond do
        background -> Theme.style(background, caps).background
        true -> themed.background
      end

    modifiers =
      if caps.color_mode == :monochrome and role in [:on_accent, :on_warn],
        do: Enum.uniq([:reversed | modifiers]),
        else: modifiers

    %{plain | foreground: themed.foreground, background: bg, modifiers: modifiers}
  end

  @doc "Cells of `text` under the state's policy."
  def cells(text, state), do: Width.cells(text, state.capabilities.ambiguous_width)

  @doc "The glyph for `token` (see `Panel.Glyph`)."
  def g(token, state), do: Glyph.get(token, state)

  @doc "The kind mark of a run (R8): `Theme.run_mark/1` through `Support.glyph/2`."
  def mark(kind, state) do
    SwarmCodeCLI.UI.Projector.Support.glyph(Theme.run_mark(kind), state) |> SafeText.value()
  end

  @doc """
  One row exactly `width` cells wide: one blank cell, the left segments, the
  right segments flush against the last content cell, one blank cell.
  `opts`: `background:` a role for the whole row, `margin:` the blank cells on
  each side (default 1).
  """
  def row(left, right, width, state, opts \\ []) do
    bg = Keyword.get(opts, :background)
    margin = Keyword.get(opts, :margin, 1)
    inner = max(0, width - 2 * margin)
    right = normalize(right)
    right_cells = Enum.reduce(right, 0, fn {t, _, _}, acc -> acc + cells(t, state) end)

    {right, right_cells} =
      if right_cells > inner, do: {[], 0}, else: {right, right_cells}

    gap = if right == [], do: 0, else: 1
    room = max(0, inner - right_cells - gap)
    {left, left_cells} = fit(normalize(left), room, state)
    fill = inner - left_cells - right_cells

    spans =
      [pad(margin, state, bg)] ++
        Enum.map(left, &span(&1, state, bg)) ++
        [pad(fill, state, bg)] ++
        Enum.map(right, &span(&1, state, bg)) ++ [pad(margin, state, bg)]

    %Block.RichText{spans: Enum.reject(spans, &is_nil/1)}
  end

  @doc "A blank row (a single space: an empty text carries no cells)."
  def blank(width, state, opts \\ []), do: row([], [], width, state, opts)

  @doc "A row of `width` cells made of the rule glyph in `role`."
  def rule(width, state, role \\ :text_ghost) do
    inner = max(0, width - 2)
    row([{String.duplicate(g(:rule, state), inner), role}], [], width, state)
  end

  @doc "Takes segments while they fit `room` cells, eliding the one that does not."
  def fit(segments, room, state) do
    Enum.reduce_while(segments, {[], 0}, fn {text, role, mods}, {acc, used} ->
      c = cells(text, state)

      cond do
        used + c <= room ->
          {:cont, {[{text, role, mods} | acc], used + c}}

        room - used >= 1 ->
          elided = text |> Density.safe(state, room - used) |> SafeText.value()
          {:halt, {[{elided, role, mods} | acc], used + cells(elided, state)}}

        true ->
          {:halt, {acc, used}}
      end
    end)
    |> then(fn {acc, used} -> {Enum.reverse(acc), used} end)
  end

  @doc "Pads `text` on the right to `n` cells, eliding it when longer."
  def pad_to(text, n, state) do
    c = cells(text, state)

    cond do
      c == n -> text
      c < n -> text <> String.duplicate(" ", n - c)
      true -> text |> Density.safe(state, n) |> SafeText.value() |> pad_to(n, state)
    end
  end

  @doc "Elides `text` to at most `n` cells (the middle when `position` is `:middle`)."
  def elide(text, n, state, position \\ :end),
    do: text |> Density.safe(state, max(0, n), position) |> SafeText.value()

  @doc "Word-wraps `text` to `n` cells, at most `rows` rows; the last row is elided."
  def wrap(text, n, rows, state) do
    policy = state.capabilities.ambiguous_width
    safe = text |> Density.safe(state, 10_000) |> SafeText.value()
    lines = Width.wrap(safe, max(1, n), policy)

    if length(lines) <= rows do
      lines
    else
      {kept, [last | rest]} = Enum.split(lines, rows - 1)
      tail = Enum.join([last | rest], " ")
      kept ++ [elide(tail, n, state)]
    end
  end

  defp normalize(segments) do
    segments
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      {text, role} -> {text, role, []}
      {text, role, mods} -> {text, role, mods}
    end)
    |> Enum.reject(fn {text, _, _} -> text == "" end)
  end

  defp span({text, role, mods}, state, bg) do
    %Span{
      text: Density.safe(text, state, max(1, cells(text, state))),
      style: style(role, state, mods, bg)
    }
  end

  defp pad(n, _state, _bg) when n <= 0, do: nil

  defp pad(n, state, bg),
    do: %Span{
      text: Density.safe(String.duplicate(" ", n), state, n),
      style: style(:plain, state, [], bg)
    }
end
