defmodule SwarmCodeCLI.UI.Settings.C75LayoutTest do
  @moduledoc """
  cli75 (pass 75, E) R20, R21, R23 on real `Fake.Settings` scenes: the grid
  at 160 × 45, air instead of rules, group spines in the hue of the layer
  that set each value, one focus band, the rail's band while it has the
  focus, the drawer at 140 columns and PgDn's step.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, except: [screen: 1]

  alias SwarmCodeCLI.UI.Pass73Helpers
  alias SwarmCodeCLI.UI.Projector.Settings.Page
  alias SwarmCodeCLI.UI.Settings.{Grid, Nav, Row}
  alias SwarmCodeCLI.UI.Width

  @forbidden [:border, :border_soft, :ticks_track, :text_ghost, :selection]

  # A truecolor terminal; `prefs` is cli.json and SWARM_THEME is set, so the
  # pages have a cli.json row, an env row, session rows and default rows.
  defp open(section, {columns, rows}, cursor \\ nil) do
    state = Pass73Helpers.ready([], columns: columns, rows: rows)

    state = %{
      rich(state)
      | prefs: %{"panel" => "compact"},
        launch_facts: %{
          env_overrides: %{"terminal.theme" => %{var: "SWARM_THEME", value: "light"}}
        }
    }

    {state, _fake} = opened(section, state: state)
    if cursor, do: Nav.put_cursor(state, cursor), else: state
  end

  # The screen line (and its spans) whose page column holds `label` first.
  defp row_line(state, label) do
    lines = lines(state)
    grid = Grid.for(state.size.columns, state.size.rows)

    index =
      Enum.find_index(lines, fn line ->
        line |> String.slice(grid.page.left + 3, grid.label_width) |> String.trim() == label
      end)

    assert index, "no line for #{label}:\n" <> Enum.join(lines, "\n")
    {index, Enum.at(line_spans(state), index)}
  end

  defp role_at(spans, col), do: spans |> span_at(col) |> elem(1) |> Map.fetch!(:role)

  describe "160 × 45 (R20.1)" do
    setup do
      %{state: open(:models_effort, {160, 45})}
    end

    test "the rows of the screen and every line exactly 160 cells", %{state: state} do
      lines = lines(state)
      assert length(lines) == 45
      assert Enum.all?(lines, &(Width.cells(&1, :narrow) == 160))
      assert hd(lines) =~ ~r/^  Settings ›/u
      assert Enum.at(lines, 1) =~ "/"
      assert Enum.at(lines, 1) =~ "search"

      for row <- [2, 41, 43],
          do: assert(String.trim(Enum.at(lines, row)) == "", "row #{row} is blank")

      assert Enum.at(lines, 44) =~ ~r/^  BROWSE/
    end

    test "air, never rules: no `│` in the gutters, groups on spines", %{state: state} do
      lines = lines(state)

      for line <- lines, col <- Enum.concat(26..29, 112..115) do
        refute cell(line, col) == "│", "a rule at column #{col}: #{line}"
      end

      page = page_lines(state, {160, 45})
      titles = for {line, i} <- Enum.with_index(page), String.starts_with?(line, "╭─ "), do: i
      assert length(titles) >= 2
      assert Enum.any?(page, &String.starts_with?(&1, "╰"))

      # one blank line before every group but the first, none after a title
      for i <- tl(titles) do
        assert String.trim(Enum.at(page, i - 1)) == ""
        refute String.trim(Enum.at(page, i - 2)) == ""
        refute String.trim(Enum.at(page, i + 1)) == ""
      end
    end

    test "the spine carries the hue of the layer that set the value (R21.4)", %{state: state} do
      {_, spans} = row_line(state, "Scheduled task model")
      assert role_at(spans, 30) == :text_faint

      {_, spans} = row_line(open(:models_effort, {160, 45}, "key:efforts.default"), "Title")
      assert role_at(spans, 30) == :agent_lane_1

      {_, spans} = row_line(open(:appearance, {160, 45}, "key:terminal.colors"), "Theme")
      assert role_at(spans, 30) == :agent_lane_4

      layout = open(:layout, {160, 45}, "key:terminal.composer_rows")
      {_, spans} = row_line(layout, "Side panel")
      assert role_at(spans, 30) == :run_consensus_judge
      # the whole tag takes the hue (R21.4)
      assert Enum.any?(spans, fn {text, style} ->
               text =~ "cli.json" and style.role == :run_consensus_judge
             end)
    end

    test "one band on the focused item, its label bold (R23.1-23.3)", %{state: state} do
      assert Nav.current(state).id == "key:models.chat"
      {index, spans} = row_line(state, "Chat model")
      page = spans_between(spans, 30, 111)
      assert page != []
      assert Enum.all?(page, &banded?/1)
      assert {"▌", _} = span_at(spans, 30)

      assert Enum.any?(page, fn {text, style} ->
               text =~ "Chat model" and :bold in style.modifiers
             end)

      banded =
        for {line, i} <- Enum.with_index(line_spans(state)),
            Enum.any?(spans_between(line, 30, 111), &banded?/1),
            do: i

      assert banded == Enum.to_list(index..(index + length(banded) - 1))
    end

    test "no span carries a role the settings layer remaps (R20.7)", %{state: state} do
      for section <- [:models_effort, :appearance, :storage, :providers, :overview] do
        roles = roles(open(section, {160, 45}))
        assert MapSet.disjoint?(roles, MapSet.new(@forbidden)), "#{section}: #{inspect(roles)}"
      end

      assert MapSet.disjoint?(roles(state), MapSet.new(@forbidden))
    end
  end

  test "a `▸ ` label and a `◐ ` value both leave their text; the slot draws `◐` (R22.1-22.2, 407)" do
    caps = rich(Pass73Helpers.ready([], columns: 160, rows: 45)).capabilities

    row = %Row{
      id: "act:fetch",
      label: "▸ Fetch models",
      value: [{"◐ fetching the model list", :text_primary}, {" · 6 s", :text_faint}]
    }

    hoisted = Page.hoist(row, caps)
    assert hoisted.label == "Fetch models"
    assert [{"fetching the model list", :text_primary}, {" · 6 s", :text_faint}] = hoisted.value
    assert :action in hoisted.marks and :running in hoisted.marks
    assert Page.mark(hoisted, caps, false) == {"◐", :info}
  end

  test "a value that wraps before a tag leaves two cells before it (R22.4, 407)" do
    state = open(:models_effort, {160, 45})
    grid = Grid.for(160, 45)

    row = %Row{
      id: "act:provider.test",
      kind: :action,
      label: "▸ Test connection",
      value: [{"lists the models with the saved values; writes nothing", :text_faint}],
      tag: [{"t", :key}]
    }

    [group] = Page.groups([row])

    [first | _] =
      for line <- Page.row_lines(state, row, group, grid), do: Enum.map_join(line, &elem(&1, 0))

    assert String.ends_with?(first, "  t ")
    refute first =~ "writes t"
  end

  test "a focused row whose tag names its Enter key draws no second hint (R22.8, 407)" do
    state = open(:models_effort, {160, 45})
    grid = Grid.for(160, 45)

    row = %Row{
      id: "fld:mcp:m1:env",
      kind: :field,
      label: "Environment",
      value: [{"none", :text_faint}],
      tag: [{"Enter", :key}, {" edit", :text_faint}],
      keys: [{"Enter", :open_row, "edit"}]
    }

    [group] = Page.groups([row])

    [first | _] =
      for line <- Page.row_lines(state, row, group, grid, focus?: true),
          do: Enum.map_join(line, &elem(&1, 0))

    assert first =~ "Enter edit"
    refute first =~ ~r/Enter edit\s+Enter edit/
  end

  test "with the focus on the rail the band and `▌` move there (D9)" do
    state = open(:models_effort, {160, 45})
    {state, _} = verb(state, :previous_region)
    assert state.settings.region == :rail

    lines = line_spans(state)

    rail_banded =
      for line <- lines, span <- spans_between(line, 2, 25), banded?(span), do: span

    page_banded =
      for line <- lines, span <- spans_between(line, 30, 111), banded?(span), do: span

    assert rail_banded != []
    assert page_banded == []
    assert Enum.any?(rail_lines(state, {160, 45}), &String.starts_with?(&1, "▌"))
  end

  test "at 140 × 40: a page of columns - 32 cells, no note, the drawer under the focus" do
    state = open(:models_effort, {140, 40})
    grid = Grid.for(140, 40)
    assert grid.page == %{left: 30, width: 108}
    assert grid.note == nil
    assert note_lines(state, {140, 40}) == []
    assert Enum.all?(lines(state), &(Width.cells(&1, :narrow) == 140))

    page = page_lines(state, {140, 40})
    focus = Enum.find_index(page, &String.starts_with?(&1, "▌"))
    assert focus
    # the drawer: 3 lines on the group's spine, not banded, `╰─` first (R24.5)
    drawer = Enum.slice(page, focus + 1, 3)
    assert String.slice(Enum.at(drawer, 0), 1, 2) == "╰─"
    assert Enum.at(drawer, 2) =~ "i the whole detail"

    for i <- (focus + 1)..(focus + 3) do
      spans = Enum.at(line_spans(state), grid.body_top + i)
      refute Enum.any?(spans_between(spans, 30, 137), &banded?/1)
    end
  end

  test "PgDn steps the cursor by the grid's 38 body rows at 160 × 45 (R20.9)" do
    state = open(:models_effort, {160, 45})
    assert Nav.page_height(state) == 38

    focusable = state |> Nav.rows() |> Enum.filter(&Row.focusable?/1)
    state = Nav.put_cursor(state, hd(focusable).id)
    {state, _} = verb(state, :page_down)
    index = Enum.find_index(focusable, &(&1.id == Nav.current(state).id))
    assert index == min(38, length(focusable) - 1)
  end
end
