defmodule SwarmCodeCLI.Cli020EHelpers do
  @moduledoc false
  # cli020 lane E: paint a state and read the screen as text rows.

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  def fixture(kind \\ :chat, {columns, rows} \\ {120, 30}, caps \\ []) do
    size = %Size{columns: columns, rows: rows}
    Fixtures.representative(kind, size, struct!(%Capabilities{size: size}, caps))
  end

  def sized(state, {columns, rows}) do
    size = %{state.size | columns: columns, rows: rows}
    %{state | size: size, capabilities: %{state.capabilities | size: size}}
  end

  def workspace(state), do: Map.get(state.read_model.snapshots, :workspace)

  def put_workspace(state, fields) do
    # Map.merge, not struct!: a field another lane adds to the DTO (§8.2) can
    # be put before that lane lands (a stub the finisher keeps working).
    base = workspace(state) || struct(SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot)
    ws = Map.merge(base, Map.new(fields))
    put_in(state.read_model.snapshots[:workspace], ws)
  end

  @doc "Every screen row as text (one grapheme per cell, wide glyphs once)."
  def screen(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})

    for y <- 0..(state.size.rows - 1) do
      0..(state.size.columns - 1)
      |> Enum.map_join("", fn x ->
        case Plan.cell(plan, x, y) do
          {:glyph, g, _, _} -> g
          {:continuation, _, _} -> ""
          _ -> " "
        end
      end)
      |> String.trim_trailing()
    end
  end

  def screen_text(state), do: state |> screen() |> Enum.join("\n")

  @doc "The painted plan (truecolor)."
  def plan(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})
    plan
  end

  @doc "The palette style of the cell at `{x, y}`."
  def cell_style(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, _, _, index} -> elem(plan.palette, index)
      _ -> nil
    end
  end

  @doc "`{x, y}` of the first cell of `needle` on the screen."
  def locate(state, needle) do
    state
    |> screen()
    |> Enum.with_index()
    |> Enum.find_value(fn {row, y} ->
      case String.split(row, needle, parts: 2) do
        [before, _] -> {SwarmCodeCLI.UI.Width.cells(before, :narrow), y}
        _ -> nil
      end
    end)
  end

  @doc "A transcript item of run `s` in conversation `c` (Pass73Helpers' ids)."
  def item(id, fields) do
    struct!(
      %SwarmCodeCLI.UI.DataSource.DTO.TranscriptItem{
        id: id,
        run_id: "s",
        conversation_id: "c",
        node_id: "lead",
        revision: 1,
        role: :assistant,
        state: :done,
        text: "",
        reasoning: "",
        attempt_id: "a",
        allowed_actions: [],
        at: 1
      },
      fields
    )
  end
end
