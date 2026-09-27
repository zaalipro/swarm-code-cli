defmodule SwarmCodeCLI.UI.Settings.C75NoteTest do
  @moduledoc """
  cli75 (pass 75, E) R24 and the narrow layouts of R20: where the note
  sits and how it joins the focus at 160 columns, its body and ladder, the
  enum editor's note, the drawers at 90 × 30 and 80 × 24, the `i` page and
  the scroll hints. Asserted by grid slices and roles.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, except: [screen: 1]

  alias SwarmCodeCLI.UI.Pass73Helpers
  alias SwarmCodeCLI.UI.Projector.Settings.Note
  alias SwarmCodeCLI.UI.Settings.{Editors, Grid, Nav}

  # A truecolor terminal with the rich glyphs; SWARM_THEME is set, so the
  # theme's ladder has an env line.
  defp open(section, {columns, rows}, cursor \\ nil) do
    state = Pass73Helpers.ready([], columns: columns, rows: rows)

    state = %{
      rich(state)
      | launch_facts: %{
          env_overrides: %{"terminal.theme" => %{var: "SWARM_THEME", value: "light"}}
        }
    }

    {state, _fake} = opened(section, state: state)
    if cursor, do: Nav.put_cursor(state, cursor), else: state
  end

  defp style_at(spans, col), do: spans |> span_at(col) |> elem(1)
  defp role_at(spans, col), do: style_at(spans, col).role

  defp focus_index(page), do: Enum.find_index(page, &String.starts_with?(&1, "▌"))

  # The note at 160 × 45: `{body index, text after the spine, the line's spans}`.
  defp note(state) do
    grid = Grid.for(160, 45)
    spans = line_spans(state)

    state
    |> note_lines({160, 45})
    |> Enum.with_index()
    |> Enum.reject(fn {line, _at} -> String.trim(line) == "" end)
    |> Enum.map(fn {line, at} ->
      {at, String.slice(line, 2, grid.note.width), Enum.at(spans, grid.body_top + at)}
    end)
  end

  defp find_note(note, pattern), do: Enum.find(note, fn {_at, text, _} -> text =~ pattern end)

  test "a detail-less action row's note is titled without its `▸ ` (F6b, 407)" do
    state = open(:models_effort, {160, 45})

    row = %SwarmCodeCLI.UI.Settings.Row{
      id: "act:env:add",
      kind: :action,
      label: "▸ Add a variable"
    }

    [title | _] = Note.body(state, row, 40)
    assert Enum.map_join(title, &elem(&1, 0)) =~ ~r/^Add a variable/
  end

  test "Note.placement/4: the group's top, slid up for the body, never past the focus" do
    assert Note.placement(4, 7, 20, 38) == 4
    assert Note.placement(30, 33, 20, 38) == 18
    # taller than the body: the top clamps at 0, the focus is still inside
    assert Note.placement(0, 30, 40, 38) == 0
    assert Note.placement(10, 12, 5, 38) == 10
    # the focus below the note's reach pulls it down to end on the focus
    assert Note.placement(0, 30, 10, 38) == 21
  end

  describe "160 × 45 (R24.1-24.4)" do
    test "the note starts on the group's title line and joins the focus" do
      state = open(:models_effort, {160, 45})
      grid = Grid.for(160, 45)
      page = page_lines(state, {160, 45})
      focus = focus_index(page)

      group =
        page
        |> Enum.take(focus + 1)
        |> Enum.with_index()
        |> Enum.filter(fn {line, _} -> String.starts_with?(line, "╭─ ") end)
        |> List.last()
        |> elem(1)

      [{first, _, _} | _] = note(state)
      assert first == group
      assert state |> note_lines({160, 45}) |> Enum.at(first) |> String.starts_with?("╭ ")

      focus_line = state |> lines() |> Enum.at(grid.body_top + focus)
      assert String.slice(focus_line, 113, 3) == "───"
      assert cell(focus_line, 116) == if(first == focus, do: "╮", else: "┤")
    end

    test "the body in order: title, key line, description, facts, ladder, keys" do
      note = note(open(:models_effort, {160, 45}))
      {_, title, spans} = hd(note)
      assert title =~ "Chat model · global"
      assert :bold in style_at(spans, 118).modifiers

      {key_at, _, spans} = find_note(note, ~r/^models\.chat/)
      assert role_at(spans, 118) == :text_faint
      {description, _, spans} = find_note(note, ~r/^The model a new conversation/)
      assert role_at(spans, 118) == :text_muted
      {where, _, _} = find_note(note, ~r/^where it comes from/)
      assert key_at < description and description < where

      # the key line wraps, then one blank line before the description
      assert blank?(note, description - 1)

      {_, winner, spans} = find_note(note, ~r/^› global/)
      assert winner =~ ~r/✓$/
      assert role_at(spans, 118) == :accent
      check = 118 + String.length(String.trim_trailing(winner)) - 1
      assert {"✓", %{role: :success}} = span_at(spans, check)

      {last, text, spans} = List.last(note)
      assert text =~ "r reset to the default"
      assert role_at(spans, 118) == :key
      assert cell(lines_row(spans), 116) == "╰"
      assert last > where
    end

    test "a layer word wider than its 10 cells keeps one space before the value (407)" do
      note = note(open(:models_effort, {160, 45}, "key:efforts.default"))
      {_, text, _} = find_note(note, ~r/^  project file/)
      assert text =~ ~r/^  project file \S/
      {_, text, _} = find_note(note, ~r/^(› |  )default/)
      assert text =~ ~r/^(› |  )default   \S/
    end

    test "the ladder's env line takes the env hue on the note's spine" do
      note = note(open(:appearance, {160, 45}, "key:terminal.theme"))
      {_, text, spans} = find_note(note, ~r/^› env/)
      # the choice's label, as the page draws it (407)
      assert text =~ "Light"
      assert role_at(spans, 116) == :agent_lane_4
    end

    test "an enum's ladder and facts name the choice's label, never the stored word (407)" do
      state = open(:approvals, {160, 45})
      row = Enum.find(Nav.rows(state), &match?({Editors.Enum, _}, &1.editor))
      note = note(Nav.put_cursor(state, row.id))
      texts = for {_, text, _} <- note, do: text

      assert Enum.any?(texts, &(&1 =~ ~r/^(› |  )project   Auto /))
      assert Enum.any?(texts, &(&1 =~ ~r/^value    Auto/))
      refute Enum.any?(texts, &(&1 =~ ~r/read_only|full_access|(project|default) +auto/))
    end

    test "an open enum editor's note lists every choice, marks and hints (R24.4)" do
      state = open(:approvals, {160, 45})
      row = Enum.find(Nav.rows(state), &match?({Editors.Enum, _}, &1.editor))
      {state, _} = state |> Nav.put_cursor(row.id) |> verb(:enter)
      {moved, _} = verb(state, :right)

      note = note(state)
      {_, title, _} = hd(note)
      assert title =~ ~r/ · editing\s*$/

      choices = for {_, text, _} <- note, text =~ ~r/^(✓ |› |  )[A-Z]/, do: text
      assert Enum.map(choices, &String.trim/1) == ["Read-only", "✓ Auto", "Full access"]

      {at, _, _} = find_note(note, ~r/^✓ Auto/)
      {hint, _, _} = find_note(note, ~r/^  edits go ahead/)
      assert hint == at + 1

      # after a step the candidate is `›` and the saved choice keeps `✓`
      moved = note(moved)
      assert find_note(moved, ~r/^› Full access/)
      assert find_note(moved, ~r/^✓ Auto/)
    end
  end

  describe "90 × 30 (R20.4, R24.5, R24.7)" do
    setup do
      state = open(:models_effort, {90, 30})

      effort =
        Enum.find(Nav.rows(state), &(&1.label =~ "Effort" and &1.id =~ "session")) ||
          Enum.find(Nav.rows(state), &(&1.label =~ "Effort"))

      %{state: Nav.put_cursor(state, effort.id)}
    end

    test "the strip on row 2, the body from row 4, a 3-line drawer", %{state: state} do
      lines = lines(state)
      assert Enum.at(lines, 2) =~ "‹"
      assert Enum.at(lines, 2) =~ "›"
      assert String.trim(Enum.at(lines, 3)) == ""
      assert Enum.at(lines, 4) =~ "↑ "

      page = page_lines(state, {90, 30})
      focus = focus_index(page)
      [one, two, three] = Enum.slice(page, focus + 1, 3)

      assert String.slice(one, 1, 3) == "╰─ "
      assert one =~ "Reasoning effort of this conversation"
      assert two =~ "▎session high ✓"
      assert two =~ "▎global medium"

      assert String.trim_trailing(two)
             |> String.ends_with?("session.effort · conversations.effort")

      assert three =~ "r reset to the default"
      assert String.trim_trailing(three) |> String.ends_with?("i the whole detail")

      spans = Enum.at(line_spans(state), Grid.for(90, 30).body_top + focus + 1)
      assert role_at(spans, 3) == :text_faint
      refute Enum.any?(spans, &banded?/1)
    end

    test "`i` opens the whole detail as the page, `i` again brings the rows back",
         %{state: state} do
      before = lines(state)
      {detail, _} = verb(state, :info)
      assert detail.settings.detail_open

      lines = lines(detail)
      assert hd(lines) |> String.trim_trailing() |> String.ends_with?("Esc back")
      refute hd(before) |> String.trim_trailing() |> String.ends_with?("Esc back")

      page = page_lines(detail, {90, 30})
      assert hd(page) =~ ~r/^╭─ Effort/
      assert Enum.any?(page, &(&1 =~ "where it comes from · strongest first"))
      last = page |> Enum.reject(&(String.trim(&1) == "")) |> List.last()
      assert last =~ ~r/^╰\s+r reset to the default/
      refute Enum.any?(page, &String.starts_with?(&1, "▌"))

      {back, _} = verb(detail, :info)
      assert lines(back) == before
    end

    test "scroll hints: `↑ … rows above` first, `↓ … rows below` last", %{state: state} do
      page = page_lines(state, {90, 30})
      assert page |> hd() |> String.trim() =~ ~r/^↑ .* rows? above$/
      assert page |> List.last() |> String.trim() =~ ~r/^↓ .* rows? below$/
    end
  end

  test "140 columns: a detail longer than the body says how many lines are below (R22.4)" do
    detail = fn rows ->
      state = open(:models_effort, {140, rows})
      effort = Enum.find(Nav.rows(state), &(&1.label =~ "Effort"))
      {detail, _} = state |> Nav.put_cursor(effort.id) |> verb(:info)
      page_lines(detail, {140, rows})
    end

    whole = detail.(45) |> Enum.reject(&(String.trim(&1) == ""))
    refute Enum.any?(whole, &(&1 =~ "below"))

    grid = Grid.for(140, 20)
    assert grid.class == :rail
    assert length(whole) > grid.body_rows

    page = detail.(20)
    assert length(page) == grid.body_rows
    assert Enum.take(page, grid.body_rows - 1) == Enum.take(whole, grid.body_rows - 1)
    hidden = length(whole) - (grid.body_rows - 1)
    assert page |> List.last() |> String.trim() == "↓ #{hidden} lines below"
  end

  test "80 × 24: a 2-line drawer and a 19-cell label column (R24.6, R20.5)" do
    state = open(:models_effort, {80, 24})
    effort = Enum.find(Nav.rows(state), &(&1.label =~ "Effort"))
    state = Nav.put_cursor(state, effort.id)
    grid = Grid.for(80, 24)
    lines = lines(state)
    page = page_lines(state, {80, 24})
    focus = focus_index(page)

    focus_line = Enum.at(lines, grid.body_top + focus)
    assert String.slice(focus_line, 4, 19) |> String.trim() == "Effort"
    assert cell(focus_line, 23) == " "
    assert String.slice(focus_line, 24, 4) == "high"

    [one, two, three] = Enum.slice(page, focus + 1, 3)
    assert one =~ ~r/^.╰─ session\.effort · conversations\.effort ▎session high ✓/u
    assert two =~ "r reset to the default"
    assert String.trim_trailing(two) |> String.ends_with?("i the whole detail")
    refute three =~ "i the whole detail"
  end

  defp blank?(note, at) do
    {_, text, _} = Enum.find(note, fn {i, _, _} -> i == at end)
    String.trim(text) == ""
  end

  defp lines_row(spans), do: Enum.map_join(spans, "", &elem(&1, 0))
end
