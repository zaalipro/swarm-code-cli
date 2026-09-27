defmodule SwarmCodeCLI.C75Helpers do
  @moduledoc """
  cli75 (pass 75, E): read a projected settings screen by the regions of its
  `Settings.Grid`, so the tests assert rows, cells and roles rather than
  whole-screen strings (merge M12). The screen is `Projector.Settings`'s
  one region; each block is one terminal line.

  A span is `{text, %Scene.Style{}}`: the style keeps the segment's role
  (`style.role`, the inner role of `{role, mods}` and `{role, :on, bg}`), its
  modifiers and its resolved background.
  """

  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Theme}
  alias SwarmCodeCLI.UI.Projector.Settings, as: SettingsProjector
  alias SwarmCodeCLI.UI.Settings.Grid

  @doc "The state at `{columns, rows}` (its size and its capabilities' size)."
  def sized(state, {columns, rows}) do
    size = %{state.size | columns: columns, rows: rows}
    %{state | size: size, capabilities: %{state.capabilities | size: size}}
  end

  @doc "The state drawn on a truecolor terminal with the rich glyphs."
  def rich(state),
    do: %{
      state
      | capabilities: %{state.capabilities | color_mode: :truecolor, glyph_tier: :rich}
    }

  @doc "Every screen line of the settings layer as text."
  def lines(state),
    do: state |> line_spans() |> Enum.map(fn spans -> Enum.map_join(spans, "", &elem(&1, 0)) end)

  @doc "Every screen line as its spans `{text, style}`."
  def line_spans(state) do
    {[region], nil} = SettingsProjector.project(state, nil)

    Enum.map(region.blocks, fn block ->
      Enum.map(block.spans, &{SafeText.value(&1.text), &1.style})
    end)
  end

  @doc "The body lines cut to the grid's page span (by graphemes)."
  def page_lines(state, {columns, rows} = size) do
    grid = Grid.for(columns, rows)
    state |> sized(size) |> body() |> Enum.map(&String.slice(&1, grid.page.left, grid.page.width))
  end

  @doc "The body lines cut to the rail's 24 cells (none under 120 columns)."
  def rail_lines(state, {columns, rows} = size) do
    case Grid.for(columns, rows) do
      %Grid{rail: %{left: left, width: width}} ->
        state |> sized(size) |> body() |> Enum.map(&String.slice(&1, left, width))

      %Grid{} ->
        []
    end
  end

  @doc "The body lines cut to the note: its spine cell, a space and its text."
  def note_lines(state, {columns, rows} = size) do
    case Grid.for(columns, rows) do
      %Grid{note: %{spine: spine, width: width}} ->
        state |> sized(size) |> body() |> Enum.map(&String.slice(&1, spine, width + 2))

      %Grid{} ->
        []
    end
  end

  @doc "The grapheme at `col` of `line` (\"\" past its end)."
  def cell(line, col), do: String.at(line, col) || ""

  @doc "The span covering column `col` of a line's spans (nil past its end)."
  def span_at(spans, col) do
    Enum.reduce_while(spans, 0, fn {text, _style} = span, at ->
      width = String.length(text)
      if col < at + width, do: {:halt, span}, else: {:cont, at + width}
    end)
    |> case do
      at when is_integer(at) -> nil
      span -> span
    end
  end

  @doc "The spans of `line_spans` that cover columns `from..to` (inclusive)."
  def spans_between(spans, from, to) do
    {kept, _} =
      Enum.reduce(spans, {[], 0}, fn {text, _style} = span, {acc, at} ->
        last = at + String.length(text) - 1

        if last >= from and at <= to and text != "",
          do: {[span | acc], last + 1},
          else: {acc, last + 1}
      end)

    Enum.reverse(kept)
  end

  @doc "Every span of the screen."
  def spans(state), do: state |> line_spans() |> Enum.concat()

  @doc "The set of roles the screen's spans carry."
  def roles(state), do: state |> spans() |> MapSet.new(fn {_text, style} -> style.role end)

  @doc "Whether a span sits on the focus band (its background, or reverse video)."
  def banded?({_text, style}) do
    :reversed in (style.modifiers || []) or
      (style.background != nil and style.background in band_backgrounds())
  end

  defp band_backgrounds do
    for mode <- [:truecolor, :ansi256],
        do: Theme.style(:chip_accent, %Capabilities{size: nil, color_mode: mode}).background
  end

  defp body(state) do
    grid = Grid.for(state.size.columns, state.size.rows)
    state |> lines() |> Enum.slice(grid.body_top, grid.body_rows)
  end
end
