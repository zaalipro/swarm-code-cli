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
end
