defmodule SwarmCodeCLI.UI.Settings.C75EditorsPopoverTest do
  @moduledoc """
  cli75 (pass 75, E) R22.3/22.7/22.8, R26 and R27 on real `Fake.Settings`
  scenes: the enum as a segmented control, the toggle as a switch, the
  pasted secret's well, the help sheet's frame and scrim, and the model
  picker's frame, groups, price marks and legend.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.C75Helpers
  import SwarmCodeCLI.UI.C74U3Helpers, except: [screen: 1]

  alias SwarmCodeCLI.UI.{Pass73Helpers, Theme}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations
  alias SwarmCodeCLI.UI.Reducer.Settings.Ops
  alias SwarmCodeCLI.UI.Settings.{Editors, Grid, Nav}

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"
  @words [:text_primary, :text_muted]

  defp open(section, opts \\ []) do
    {columns, rows} = Keyword.get(opts, :size, {160, 45})
    state = rich(Pass73Helpers.ready([], columns: columns, rows: rows))
    state = Keyword.get(opts, :with, & &1).(state)
    opened(section, state: state, fake: Keyword.get(opts, :fake, FakeSettings.seed()))
  end

  defp grid(state), do: Grid.for(state.size.columns, state.size.rows)

  # The banded lines of the page: `{screen row, text, spans}` in order.
  defp band(state) do
    grid = grid(state)

    for {{text, spans}, row} <- Enum.with_index(Enum.zip(lines(state), line_spans(state))),
        cell(text, grid.page.left) == "▌",
        do: {row, text, spans}
  end

  defp status(state), do: List.last(lines(state))
  defp message(state), do: Enum.at(lines(state), state.size.rows - 3)

  defp styled?(spans, text, role, modifier) do
    Enum.any?(spans, fn {t, style} ->
      String.contains?(t, text) and style.role == role and
        (modifier == nil or modifier in style.modifiers)
    end)
  end

  test "an enum edits as a segmented control; a step shows `not saved` (R22.3, R22.7)" do
    {state, _fake} = open(:approvals)
    row = Enum.find(Nav.rows(state), &match?({Editors.Enum, _}, &1.editor))
    {state, _} = state |> Nav.put_cursor(row.id) |> verb(:enter)
    {state, _} = verb(state, :right)

    [{_, text, spans}, {_, hint, hint_spans} | _] = band(state)
    assert styled?(spans, " Full access", :on_accent, :bold)
    assert styled?(spans, "Auto", :text_primary, :underline)
    assert styled?(spans, "Read-only", :text_muted, nil)
    refute text =~ "‹"
    refute text =~ "›"

    assert hint =~ "commands and edits go ahead"
    assert {"not saved", %{role: :warning}} = last_on_page(state, hint_spans)

    assert message(state) =~ "Approvals Auto → Full access for the project once you press Enter"
    assert status(state) =~ ~r/^  EDIT /
  end

  test "a toggle is a switch; the row's hint is `Space switch`; Space flips it (R22.8)" do
    {state, fake} = open(:layout)
    state = Nav.put_cursor(state, "key:terminal.show_diffs")

    [{_, text, spans} | _] = band(state)
    assert text =~ "──● on"
    assert text =~ "Space switch"
    assert styled?(spans, "──", :text_muted, nil)
    assert styled?(spans, "●", :success, nil)
    # a row at its default is drawn muted (R21.3); the switch keeps its hues
    assert Enum.any?(spans, &match?({" on", %{role: role}} when role in @words, &1))

    {state, _fake} = state |> verb(:toggle) |> serve(fake)
    [{_, text, spans} | _] = band(state)
    assert text =~ "○── off"
    # the track is muted (a muted row draws its words in the same span)
    assert Enum.any?(spans, fn {text, style} ->
             String.starts_with?(text, "○──") and style.role == :text_muted
           end)
  end

  test "a pasted secret: dots and words on the row, `not saved` on the next line (R22.7)" do
    target = %{
      row_id: "key:terminal.panel",
      action: "search.set_key",
      target: %{"id" => "tavily"},
      attributes: %{},
      slot: "api_key",
      label: "Tavily API key",
      set?: false
    }

    fake = FakeSettings.seed()
    state = rich(Pass73Helpers.ready([], columns: 160, rows: 45))
    state = %{state | capabilities: %{state.capabilities | paste: :supported}}
    {state, _fake} = state |> act({:settings_open, {:key, "terminal.panel"}}) |> serve(fake)
    {state, _} = Ops.run(state, [{:paste, target}])
    state = act!(state, {:settings, {:paste, @canary}})

    band = band(state)
    assert Enum.any?(band, fn {_, text, _} -> text =~ "●●●●●●●● pasted · not shown" end)
    {_, _, spans} = Enum.find(band, fn {_, text, _} -> text =~ "pasted · not shown · 1 line" end)
    assert {"not saved", %{role: :warning}} = last_on_page(state, spans)
    assert status(state) =~ ~r/^  SECRET /

    text = Enum.join(lines(state), "\n")
    refute text =~ @canary
    refute text =~ String.slice(@canary, -4, 4)
  end

  describe "the help sheet (R27.1, R27.4)" do
    setup do
      {state, _fake} = open(:models_effort)
      {help, _} = verb(state, :help)
      %{state: state, help: help}
    end

    test "a rounded frame, faint on the popover background", %{help: help} do
      popover = Theme.style(:popover, help.capabilities).background
      assert popover

      framed =
        for {text, spans} <- Enum.zip(lines(help), line_spans(help)),
            left = first_col(text),
            left != nil,
            do: {text, spans, left}

      {top, top_spans, left} = hd(framed)
      assert cell(top, left) == "╭"
      {bottom, bottom_spans, ^left} = List.last(framed)
      assert cell(bottom, left) == "╰"

      for {spans, col} <- [{top_spans, left}, {bottom_spans, left}] do
        {_, style} = span_at(spans, col)
        assert style.role == :text_faint
        assert style.background == popover
      end
    end

    test "the page around the box is scrimmed; Esc restores every role",
         %{state: state, help: help} do
      grid = grid(help)
      body = grid.body_top..(grid.body_top + grid.body_rows - 1)
      lines = lines(help)
      spans = line_spans(help)
      left = lines |> Enum.find_value(&first_col/1)
      top = Enum.find_index(lines, &first_col/1)
      bottom = length(lines) - 1 - (lines |> Enum.reverse() |> Enum.find_index(&first_col/1))

      outside =
        for row <- body,
            line = Enum.at(spans, row),
            span <-
              if(row < top or row > bottom,
                do: line,
                else: spans_between(line, 0, left - 1)
              ),
            not blank?(span),
            do: span

      assert outside != []
      assert Enum.all?(outside, fn {_, style} -> style.role == :text_faint end)

      refute Enum.all?(Enum.slice(line_spans(state), body), fn line ->
               Enum.all?(line, fn {_, style} -> style.role == :text_faint end)
             end)

      {back, _} = verb(help, :back)
      assert back.settings.popover == nil
      assert line_spans(back) == line_spans(state)
    end
  end

  describe "the model picker (R26.1-26.4)" do
    setup do
      # more models on Ollama: the picker windows, and the new ones are
      # unpriced but used by no conversation
      ollama = SettingsIntegrations.ids().ollama
      extra = for i <- 1..12, do: "local-#{String.pad_leading("#{i}", 2, "0")}"
      fake = FakeSettings.seed()

      fake =
        update_in(fake, [:integrations, :providers, ollama, "models"], &(&1 ++ extra))

      # 24 rows: the 17 models and their headings do not fit the box
      {state, fake} = open(:models_effort, fake: fake, size: {100, 24})
      {picker, _fake} = state |> Nav.put_cursor("key:models.chat") |> verb(:enter) |> serve(fake)
      %{picker: picker}
    end

    test "PICK keys in the status line, the frame's title, counts and legend", %{picker: picker} do
      lines = lines(picker)
      assert status(picker) =~ ~r/^\s+PICK /
      assert status(picker) =~ "↑↓ move"

      top = Enum.find_index(lines, &(&1 =~ "╭─ Chat model"))
      bottom = Enum.find_index(lines, &(&1 =~ "Esc close ─╯"))
      assert top && bottom && bottom > top
      assert Enum.at(lines, top) =~ ~r/Chat model ─+ 3 providers · 17 models ─╮/u
      assert Enum.at(lines, bottom) =~ ~r/╰─ ✓ current   ! used but unpriced ─+ Esc close ─╯/u

      inside = Enum.slice(lines, (top + 1)..(bottom - 1))
      refute Enum.any?(inside, &(&1 =~ "↑↓ move"))
      refute Enum.any?(inside, &(&1 =~ ~r/[─]{2,}/u))
      assert Enum.any?(inside, &(&1 =~ ~r/\+\d+ more · type to filter/))
    end

    test "provider headings carry `N models` right; `no price` warns only when used",
         %{picker: picker} do
      lines = lines(picker)
      spans = line_spans(picker)

      heading = Enum.find(lines, &(&1 =~ "╭─ Anthropic"))
      assert heading =~ ~r/│  ╭─ Anthropic .* 2 models  │/u

      price_role = fn model ->
        row = Enum.find_index(lines, &(&1 =~ model))
        assert row, model

        Enum.find_value(Enum.at(spans, row), fn {text, style} ->
          if text =~ "no price", do: style.role
        end)
      end

      assert price_role.("claude-sonnet-5") == :warning
      assert price_role.("local-01") == :text_muted
    end
  end

  # The first column holding a frame corner `╭`/`│`/`╰` of a centred box.
  defp first_col(text) do
    case Regex.run(~r/^(\s*)[╭│╰]/u, text) do
      [_, pad] when byte_size(pad) >= 4 -> String.length(pad)
      _ -> nil
    end
  end

  defp blank?({text, _}), do: String.trim(text) == ""

  # The last visible span of a line inside the page's columns.
  defp last_on_page(state, spans) do
    %{page: %{left: left, width: width}} = grid(state)
    spans |> spans_between(left, left + width - 1) |> Enum.reject(&blank?/1) |> List.last()
  end
end
