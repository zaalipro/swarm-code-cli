defmodule SwarmCodeCLI.UI.HelpSheetTest do
  @moduledoc """
  The `?` sheet, judged on the painted grid: every binding of the context it
  was opened from is on it exactly once, every row stays inside the box, and
  the box uses the width it is given.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Input,
    Keymap,
    Layout,
    Paint,
    Projector,
    Size,
    Vim
  }

  alias SwarmCodeCLI.UI.Keymap.{Bindings, Context}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{Dialog, KeyLabel}

  @sizes [{80, 24}, {100, 30}, {170, 40}]

  describe "the sheet lists the context it was opened from" do
    for {columns, rows} <- @sizes do
      test "main: every binding once, every row inside the box, at #{columns}x#{rows}" do
        state = help_over(:main, {unquote(columns), unquote(rows)})
        assert Context.of(%{state | layers: []}) == :main
        check_sheet(state, :main)
      end
    end

    test "a picker underneath gives the picker's keys, not main's" do
      state = help_over(:picker, {170, 40})
      rows = check_sheet(state, :picker)
      refute Enum.any?(rows, &key_row?(&1, "i")), "main's i leaked into the picker sheet"
      assert Enum.any?(rows, &key_row?(&1, "↓ / Ctrl-N"))
    end

    test "a dialog underneath gives the dialog's keys" do
      state = help_over(:dialog, {120, 30})
      rows = check_sheet(state, :dialog)
      assert Enum.any?(rows, &key_row?(&1, "y"))
      assert Enum.any?(rows, &key_row?(&1, "n"))
    end

    test "the composer sheet lists F1 for help, because ? types there" do
      state = help_over(:composer, {170, 40})
      rows = check_sheet(state, :composer)
      assert Enum.any?(rows, &key_row?(&1, "F1"))
      refute Enum.any?(rows, &key_row?(&1, "? / F1"))
    end

    test "the vim NORMAL sheet leads with the vim group" do
      state = help_over(:composer_normal, {120, 30})
      rows = check_sheet(state, :composer_normal)
      assert hd(rows) == "Vim"
      assert Enum.any?(rows, &key_row?(&1, "1-9"))
    end
  end

  describe "the box" do
    test "runs two columns at 170 and one below" do
      wide = help_over(:main, {170, 40}) |> sheet_rows()
      assert Enum.any?(wide, &(key_row?(&1, "j / ↓") and String.contains?(&1, "k / ↑")))

      for size <- [{80, 24}, {100, 30}, {120, 30}] do
        rows = help_over(:main, size) |> sheet_rows()
        refute Enum.any?(rows, &(key_row?(&1, "j / ↓") and String.contains?(&1, "k / ↑")))
      end
    end

    test "scrolls with the dialog keys and reaches the last line" do
      state = help_over(:main, {80, 24})
      dialog = project(state)
      assert dialog.body_total_count > elem(dialog.body_visible_range, 1)

      {scrolled, _} =
        SwarmCodeCLI.UI.Reducer.update(state, {:scroll, "dialog", :last})

      dialog = project(scrolled)
      assert elem(dialog.body_visible_range, 1) == dialog.body_total_count
      assert dialog.body_scroll > 0
    end

    test "? closes the sheet it opened" do
      state = help_over(:main, {120, 30})

      assert {:ok, :close_top_layer} =
               Keymap.resolve(Input.text_fragment(:press, "?", []), state, %{})

      assert {:ok, :close_top_layer} = Keymap.resolve(Input.key({:function, 1}), state, %{})
    end
  end

  # ------------------------------------------------------------------ helpers

  # A representative shell with the help layer on top of `context`, and the
  # focus the reducer would have saved when the layer opened.
  defp help_over(context, {columns, rows}) do
    size = %Size{columns: columns, rows: rows}
    state = Fixtures.representative(:chat, size, %Capabilities{size: size})

    {focus, layers, extra} =
      case context do
        :main -> {"main", [], %{}}
        :composer -> {"composer", [], %{}}
        :composer_normal -> {"composer", [], %{keymap: :vim, vim: %Vim{mode: :normal}}}
        :picker -> {"query", [{:runs_dashboard, "dash"}], %{}}
        :dialog -> {"cancel", [{:confirm_intent, {:run_control, :stop, "run-1"}}], %{}}
      end

    state = Map.merge(state, extra)

    %{
      state
      | focus: "dialog",
        layers: [:help | layers],
        layer_contexts: [%{focus: focus, hidden_focus: nil}]
    }
  end

  defp project(state), do: Dialog.project(state, Layout.classify(state.size))

  # The rows of the sheet across every scroll position, read back off the
  # painted grid with the borders stripped; the right border must be intact on
  # every row, which is what proves nothing wrapped.
  defp sheet_rows(state) do
    dialog = project(state)
    {first, last} = dialog.body_visible_range
    height = max(1, last - first)

    0..dialog.body_total_count//height
    |> Enum.flat_map(fn offset ->
      scrolled = %{state | selection: Map.put(state.selection, "dialog_scroll", offset)}
      painted_rows(scrolled, project(scrolled))
    end)
    |> Enum.uniq()
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp painted_rows(state, dialog) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})
    rect = dialog.rect
    {first, last} = dialog.body_visible_range

    for y <- (rect.y + 1)..(rect.y + (last - first)) do
      assert glyph(plan, rect.x, y) == "│", "left border broken on row #{y}"
      assert glyph(plan, rect.x + rect.width - 1, y) == "│", "right border broken on row #{y}"

      (rect.x + 1)..(rect.x + rect.width - 2)
      |> Enum.map_join("", &glyph(plan, &1, y))
      |> String.trim_trailing()
    end
  end

  defp glyph(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, g, _, _} -> g
      _ -> " "
    end
  end

  # Every binding reachable in `context` has its key cell on exactly one row.
  # The cell is matched by its first spelling: a long alias list is elided on
  # screen, and the first spelling is what survives.
  defp check_sheet(state, context) do
    rows = sheet_rows(state)

    for binding <- Bindings.for_context(context) do
      keys = binding |> Bindings.keys_in_context(context) |> KeyLabel.joined()
      count = Enum.count(rows, &key_row?(&1, keys))
      assert count == 1, "#{binding.id} (#{keys}) appears #{count} times in the #{context} sheet"
    end

    rows
  end

  # A key cell starts a column, at the row start or after the two-cell gutter,
  # and its first spelling is followed either by the next spelling or by the
  # padding that separates it from its help text.
  defp key_row?(row, keys) do
    first = keys |> String.split(" / ") |> hd()
    Regex.match?(~r/(^|\s{2})#{Regex.escape(first)}( \/ |\s{2,}|$)/u, row)
  end
end
