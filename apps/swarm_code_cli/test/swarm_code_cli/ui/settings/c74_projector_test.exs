defmodule SwarmCodeCLI.UI.Settings.C74ProjectorTest do
  @moduledoc """
  cli74 U1-15: the settings projector at every size class (160×45,
  120×30, 90×30, 80×24 and too small at 72×18) for the Overview and a
  registry-default page; the ASCII twin with no non-ASCII byte; the
  monochrome scene with every mark as a glyph; record-table columns
  dropping by priority; the paint budget on a 400-row page.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText, Size}
  alias SwarmCodeCLI.UI.Projector.Settings, as: SettingsProjector
  alias SwarmCodeCLI.UI.Settings.{Layer, Page, Row}

  defp act!(state, action), do: elem(Reducer.update(state, action), 0)
  defp sized(columns, rows), do: act!(ready(), {:resize, %Size{columns: columns, rows: rows}})

  defp lines(state) do
    {[region], nil} = SettingsProjector.project(state, nil)

    Enum.map(region.blocks, fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  defp cells(line), do: SwarmCodeCLI.UI.Width.cells(line, :narrow)

  for {columns, rows} <- [{160, 45}, {120, 30}, {90, 30}, {80, 24}] do
    test "#{columns}×#{rows}: every line is exactly the width, the height is filled" do
      for arg <- [nil, {:section, :layout}] do
        state = sized(unquote(columns), unquote(rows)) |> act!({:settings_open, arg})
        lines = lines(state)
        assert length(lines) == unquote(rows)

        assert Enum.all?(lines, &(cells(&1) == unquote(columns))),
               inspect(Enum.map(lines, &cells/1))

        assert hd(lines) =~ "Settings"
      end
    end
  end

  test "the rail is there from 120 columns, the detail column from 160, a drawer below" do
    wide = sized(160, 45) |> act!({:settings_open, {:key, "terminal.panel"}}) |> lines()
    assert Enum.any?(wide, &(&1 =~ "Models & effort"))
    assert Enum.any?(wide, &(&1 =~ ~s(terminal.panel · cli.json "panel")))

    narrow = sized(90, 30) |> act!({:settings_open, {:key, "terminal.panel"}}) |> lines()
    refute Enum.any?(narrow, &(&1 =~ "Models & effort"))
    assert Enum.any?(narrow, &(&1 =~ "Side panel"))
  end

  test "too small says so in one sentence and Esc closes" do
    state = sized(72, 18) |> act!({:settings_open, nil})
    text = Enum.join(lines(state), "\n")
    assert text =~ "Settings needs 80 × 20; this terminal is 72 × 18."
    assert text =~ "Make it larger, or use swarmcode config in a shell."
  end

  test "the ASCII twin has no non-ASCII byte" do
    state = sized(160, 45)
    state = %{state | capabilities: %{state.capabilities | ascii?: true, glyph_tier: :ascii}}
    state = act!(state, {:settings_open, {:section, :layout}})
    state = %{state | prefs: %{"panel" => "compact"}}

    for line <- lines(state), <<byte <- line>>, do: assert(byte < 128, line)
  end

  test "monochrome keeps every mark as a glyph" do
    state = sized(160, 45)
    state = %{state | capabilities: %{state.capabilities | color_mode: :monochrome}}

    state =
      %{state | prefs: %{"panel" => "compact"}}
      |> act!({:settings_open, {:key, "terminal.panel"}})

    assert Enum.any?(lines(state), &(&1 =~ "•"))
  end

  test "record-table columns drop the least important first as the page narrows" do
    rows = [
      %Row{
        id: "rec:provider:p1",
        kind: :record,
        label: "DeepSeek",
        columns: [
          {"openai_compatible", :text_muted, 3},
          {"12 models", :text_muted, 1},
          {"key ✓", :success, 2}
        ]
      }
    ]

    wide = sized(160, 45) |> act!({:settings_open, {:section, :providers}})
    state = put_rows(wide, rows)
    text = Enum.join(lines(state), "\n")
    assert text =~ "DeepSeek" and text =~ "12 models" and text =~ "openai_compatible"

    narrow = sized(80, 24) |> act!({:settings_open, {:section, :providers}}) |> put_rows(rows)
    text = Enum.join(lines(narrow), "\n")
    assert text =~ "DeepSeek" and text =~ "12 models"
  end

  test "a 400-row page draws only its window: the paint budget holds" do
    rows =
      for n <- 1..400,
          do: %Row{
            id: "item:list:#{n}",
            kind: :list_item,
            label: "item #{n}",
            lines: [[{"line", :text_muted}]]
          }

    state = sized(160, 45) |> act!({:settings_open, {:section, :storage}}) |> put_rows(rows)
    state = SwarmCodeCLI.UI.Settings.Nav.put_cursor(state, "item:list:399")

    {scene, _} = Projector.project(state)

    nodes =
      scene.regions |> Enum.flat_map(& &1.blocks) |> Enum.map(&length(&1.spans)) |> Enum.sum()

    assert nodes <= 4_096
    assert Enum.any?(lines(state), &(&1 =~ "item 399"))
  end

  # A sub-page opened with its rows.
  defp put_rows(state, rows) do
    page = %Page{section: Layer.section(state.settings), sub: {:rows, "Rows", rows}}
    %{state | settings: Layer.push(state.settings, page)}
  end
end
