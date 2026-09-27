defmodule SwarmCodeCLI.UI.Settings.C75ChromeSearchTest do
  @moduledoc """
  cli75 (pass 75, E) R25 and the storage bar on real `Fake.Settings` scenes:
  the measured overview's texture strip and legend, the search results
  (filters, key lines, chips, links, the rail's counts, the well), the
  well's counts at 160 and 90 columns and the status line's legend.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, except: [screen: 1]

  alias SwarmCodeCLI.Test.C74U2Tasks
  alias SwarmCodeCLI.UI.Pass73Helpers
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations
  alias SwarmCodeCLI.UI.Settings.Grid

  @textures ["█", "▓", "▒", "░", "▄"]

  defp ready({columns, rows}), do: rich(Pass73Helpers.ready([], columns: columns, rows: rows))

  defp with_env(state),
    do: %{
      state
      | launch_facts: %{
          env_overrides: %{"terminal.theme" => %{var: "SWARM_THEME", value: "light"}}
        }
    }

  defp typed(state, text),
    do:
      Enum.reduce(
        String.graphemes(text),
        state,
        &Pass73Helpers.press!(&2, Pass73Helpers.letter(&1))
      )

  defp searched(query) do
    ready({160, 45})
    |> act!({:settings_open, nil})
    |> Pass73Helpers.press!(Pass73Helpers.letter("/"))
    |> typed(query)
  end

  # `{screen row, text, spans}` of the lines whose page slice matches.
  defp page_rows(state, pattern) do
    %Grid{page: page} = Grid.for(state.size.columns, state.size.rows)

    for {{text, spans}, row} <- Enum.with_index(Enum.zip(lines(state), line_spans(state))),
        String.slice(text, page.left, page.width) =~ pattern,
        do: {row, text, spans}
  end

  defp visible(spans), do: Enum.reject(spans, fn {text, _} -> String.trim(text) == "" end)

  describe "storage (R22.6)" do
    setup do
      {state, _fake} = opened(:storage, state: ready({160, 45}))

      # the measure finished: its summary is the fake's own
      {_store, id, task, _rows} =
        C74U2Tasks.run(SettingsIntegrations.seed(), "storage.measure", nil, %{}, :run, "m-1")

      task = Map.merge(%{received_at_ms: 0, elapsed_ms: 400}, task)
      %{state: put_in(state.settings.tasks, %{id => task})}
    end

    test "the bar: textures only, two quiet roles, 78 cells at 160 × 45", %{state: state} do
      [{_row, _text, spans}] = page_rows(state, ~r/[█▓▒░▄]{8,}/u)
      bar = spans |> spans_between(33, 111) |> visible()

      assert bar
             |> Enum.map_join(&elem(&1, 0))
             |> String.graphemes()
             |> Enum.uniq()
             |> Kernel.--(@textures) == []

      assert Enum.all?(bar, fn {_, style} -> style.role in [:text_muted, :text_faint] end)
      assert bar |> Enum.map(&String.length(elem(&1, 0))) |> Enum.sum() == 78
    end

    test "the legend: a swatch in the mark slot, `count · size` right-aligned", %{state: state} do
      legend = page_rows(state, ~r/^.[█▓▒░▄] [A-Z]/u)
      assert length(legend) == 6

      dots =
        for {_row, text, spans} <- legend do
          assert cell(text, 31) in @textures
          {_, style} = span_at(spans, 31)
          assert style.role in [:text_muted, :text_faint]
          assert text =~ ~r/\d+ ·\s+\d+(\.\d+)? [KMG]?B/
          text |> String.split(" · ") |> hd() |> String.length()
        end

      assert length(Enum.uniq(dots)) == 1, "the ` · ` of every legend row on one column"
    end

    test "the overview heading's tag says when it was measured", %{state: state} do
      assert [{_row, text, _}] = page_rows(state, ~r/^╭─ overview/u)
      assert text =~ ~r/measured \d\d:\d\d/
    end
  end

  describe "search `/theme` (R27.4)" do
    setup do
      %{state: searched("theme")}
    end

    test "the filters line first; key results carry their key faint", %{state: state} do
      grid = Grid.for(160, 45)
      first = state |> lines() |> Enum.at(grid.body_top)

      assert first |> String.slice(grid.page.left, grid.page.width) |> String.trim() =~
               ~r/^filters /

      [{row, _, _} | _] = page_rows(state, ~r/^.  Theme\s+Follow the desktop app/u)
      key = state |> line_spans() |> Enum.at(row + 1)
      assert Enum.any?(key, &match?({"terminal.", %{role: :text_faint}}, &1))
      assert Enum.any?(key, fn {text, style} -> text =~ "theme" and style.role == :chip_info end)
    end

    test "the query's word is a `chip_info` chip on the label", %{state: state} do
      [{_, _, spans} | _] = page_rows(state, ~r/^.  Theme\s+Follow the desktop app/u)

      assert Enum.any?(spans, fn {text, style} -> text =~ "Theme" and style.role == :chip_info end)
    end

    test "the rail dims sections without matches and counts the rest", %{state: state} do
      rail = line_spans(state)

      rows =
        for line <- rail,
            spans = line |> spans_between(2, 25) |> visible(),
            spans != [],
            do: spans

      appearance = Enum.find(rows, &match?([{"Appearance", _} | _], &1))
      assert [{"Appearance", %{role: :text_muted}}, {"2", %{role: :text_muted}}] = appearance
      pricing = Enum.find(rows, &match?([{"Pricing", _} | _], &1))
      assert [{"Pricing", %{role: :text_faint}}] = pricing
    end

    test "the well reads `N of M · K sections`", %{state: state} do
      assert state |> lines() |> Enum.at(1) =~ ~r/\d+ of \d+ · \d+ sections\s*$/
    end
  end

  test "a section result is a link: `→` in the mark slot, its section title as the tag" do
    state = searched("storage")
    [{_row, text, spans}] = page_rows(state, ~r/^.→ /u)
    assert {"→", %{role: :text_muted}} = span_at(spans, 31)
    assert String.slice(text, 30, 82) |> String.trim_trailing() |> String.ends_with?("Storage")

    assert {"Storage", %{role: :text_muted}} =
             spans |> spans_between(30, 111) |> visible() |> List.last()
  end

  describe "the well's counts (R25.2)" do
    test "at 160: changed, the attention chip and env, three spaces apart" do
      {state, _fake} = opened(:overview, state: with_env(ready({160, 45})))
      [line | _] = state |> lines() |> Enum.drop(1)

      assert line =~
               ~r/• \d+ changed from default    ! 3 need attention    \d+ from env\s*$/u

      spans = state |> line_spans() |> Enum.at(1)
      assert Enum.any?(spans, &match?({" ! 3 need attention ", %{role: :chip_warn}}, &1))
    end

    test "at 90: the short forms" do
      {state, _fake} = opened(:overview, state: with_env(ready({90, 30})))
      assert state |> lines() |> Enum.at(1) =~ ~r/• \d+    ! 3    \d+ env\s*$/u
      spans = state |> line_spans() |> Enum.at(1)
      assert Enum.any?(spans, &match?({" ! 3 ", %{role: :chip_warn}}, &1))
    end
  end

  describe "the status line's legend (R25.6)" do
    test "names the project when the workspace does, then the conversation" do
      state = ready({160, 45})
      snapshots = Map.put(state.read_model.snapshots, :workspace, %{project: "ailogic"})
      state = put_in(state.read_model.snapshots, snapshots)
      {state, _fake} = opened(:models_effort, state: state)

      assert state
             |> lines()
             |> List.last()
             |> String.trim_trailing()
             |> String.ends_with?("project ailogic · conversation Refactor the parser")
    end

    test "the conversation alone without a project name" do
      {state, _fake} = opened(:models_effort, state: ready({160, 45}))
      last = state |> lines() |> List.last() |> String.trim_trailing()
      assert String.ends_with?(last, "conversation Refactor the parser")
      refute last =~ "project "
    end
  end
end
