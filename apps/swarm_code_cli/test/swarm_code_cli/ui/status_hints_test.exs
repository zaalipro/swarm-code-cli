defmodule SwarmCodeCLI.UI.StatusHintsTest do
  @moduledoc """
  The status row (ux M5) says what the session is set to on the left and, on
  the right, the two keys worth a reminder in this context (one on narrow
  rows), read off the binding table. It never overflows, never names a focus
  and leads with the vim mode when vim is on.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Layout,
    Paint,
    Projector,
    SafeText,
    Size,
    Vim,
    Width
  }

  alias SwarmCodeCLI.UI.Keymap.{Bindings, Context}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{KeyLabel, Shell, Status}

  @sizes [{170, 40}, {150, 30}, {120, 30}, {80, 24}, {50, 16}, {50, 14}]

  describe "hints" do
    for {columns, rows} <- @sizes, focus <- ["composer"] do
      test "#{focus} at #{columns}x#{rows}: the strongest hints, and the row never overflows" do
        state = fixture({unquote(columns), unquote(rows)}, unquote(focus))
        class = Layout.classify(state.size)
        [%{spans: spans}] = Status.project(state, class, state.size.columns)
        assert cells(spans, state) <= state.size.columns

        budget = if class in [:xl, :wide, :medium], do: 2, else: 1
        pairs = hint_pairs(state)
        row = paint_last_row(state)

        for pair <- Enum.take(pairs, budget), do: assert(row =~ pair)
        for pair <- Enum.drop(pairs, budget), do: refute(row =~ pair)
      end
    end

    test "every hinted key is one the resolver routes in that context" do
      state = fixture({170, 40}, "composer")
      row = paint_last_row(state)

      # ? types in the composer, so help is hinted as F1 there or not at all.
      refute row =~ "? "

      assert Enum.any?(hint_pairs(state), &(row =~ &1))
    end

    for {columns, rows} <- @sizes do
      test "select mode at #{columns}x#{rows}: SELECT leads, its keys follow, nothing overflows" do
        state = fixture({unquote(columns), unquote(rows)}, "main")
        class = Layout.classify(state.size)
        [%{spans: spans}] = Status.project(state, class, state.size.columns)
        assert cells(spans, state) <= state.size.columns

        row = paint_last_row(state)
        assert String.starts_with?(row, " SELECT  Build")

        down = :move_next |> Bindings.keys_for() |> hd() |> KeyLabel.label()
        up = :move_previous |> Bindings.keys_for() |> hd() |> KeyLabel.label()
        assert row =~ down <> "/" <> up <> " move"
        assert row =~ "Enter open"
        assert row =~ "Esc back"
      end
    end

    test "Esc interrupt is offered only while a turn streams (pass70 Q7)" do
      state = fixture({170, 40}, "composer")
      assert paint_last_row(state) =~ "Esc interrupt"

      runs = Map.new(state.read_model.runs, fn {id, run} -> {id, %{run | state: :done}} end)
      idle = put_in(state.read_model.runs, runs)
      refute paint_last_row(idle) =~ "interrupt"
      assert paint_last_row(idle) =~ "send"
    end

    test "the strongest hints come first: Send leads the composer" do
      composer = paint_last_row(fixture({170, 40}, "composer"))
      assert composer =~ "send"
    end

    test "the row never names a focus or carries a cue prefix in colour" do
      for focus <- ["main", "composer"] do
        row = paint_last_row(fixture({120, 30}, focus))
        refute row =~ "Focus"
        refute row =~ "KEY"
        refute row =~ ">"
      end
    end

    test "the left side is the session's mode, then its facts, joined by quiet dots" do
      row = paint_last_row(fixture({170, 40}, "composer"))
      assert String.starts_with?(row, " Build")
      assert row =~ " · "
    end
  end

  describe "vim" do
    test "the mode word leads the row and the pending keys follow it" do
      state = %{
        fixture({120, 30}, "composer")
        | keymap: :vim,
          vim: %Vim{mode: :normal, pending: "d", count: 2}
      }

      row = paint_last_row(state)
      assert String.starts_with?(row, " NORMAL 2d  ")

      insert = %{state | vim: %Vim{mode: :insert}}
      assert String.starts_with?(paint_last_row(insert), " INSERT  ")

      visual = %{state | vim: %Vim{mode: :visual}}
      assert String.starts_with?(paint_last_row(visual), " VISUAL  ")
    end

    test "the mode word is bold and styled without a role cue, so it prints once" do
      state = %{fixture({120, 30}, "composer") | keymap: :vim, vim: %Vim{mode: :normal}}
      [%{spans: [_gap, mode | _]}] = Status.project(state, :medium, 120)
      assert SafeText.value(mode.text) == "NORMAL"
      assert mode.style.role == :plain
      assert :bold in mode.style.modifiers
    end

    test "with the default keymap the row leads with the session's mode" do
      state = fixture({120, 30}, "composer")
      assert String.starts_with?(paint_last_row(state), " Build")
    end
  end

  describe "the tab row hint" do
    test "spells the run switcher's chord from the table" do
      state = fixture({170, 40}, "main")
      {_shown, _overflow, hint} = Shell.tabline_plan(state, 170)
      assert String.contains?(hint, KeyLabel.primary(Bindings.fetch(:run_palette)))
    end
  end

  # ------------------------------------------------------------------ helpers

  defp fixture({columns, rows}, focus) do
    size = %Size{columns: columns, rows: rows}
    %{Fixtures.representative(:chat, size, %Capabilities{size: size}) | focus: focus}
  end

  defp hint_pairs(state) do
    context = Context.of(state)

    context
    |> Bindings.hinted()
    |> Enum.flat_map(fn binding ->
      case Bindings.key_in_context(binding, context) do
        nil -> []
        key -> [KeyLabel.label(key, false) <> " " <> String.downcase(binding.label)]
      end
    end)
  end

  defp cells(spans, state) do
    Enum.reduce(spans, 0, fn span, sum ->
      sum + Width.cells(SafeText.value(span.text), state.capabilities.ambiguous_width)
    end)
  end

  defp paint_last_row(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})
    y = state.size.rows - 1

    0..(state.size.columns - 1)
    |> Enum.map_join("", fn x ->
      case Plan.cell(plan, x, y) do
        {:glyph, g, _, _} -> g
        _ -> " "
      end
    end)
  end
end
