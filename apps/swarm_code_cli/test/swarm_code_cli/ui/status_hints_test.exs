defmodule SwarmCodeCLI.UI.StatusHintsTest do
  @moduledoc """
  The status row reads its hints off the binding table: as many as the layout
  class allows, never wider than the row, and led by the vim mode when vim is on.
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
  alias SwarmCodeCLI.UI.Projector.{Density, KeyLabel, Shell, Status}

  @sizes [{170, 40}, {150, 30}, {120, 30}, {80, 24}, {50, 16}, {50, 14}]

  describe "hints" do
    for {columns, rows} <- @sizes, focus <- ["main", "composer"] do
      test "#{focus} at #{columns}x#{rows}: budget plus one, and the row never overflows" do
        state = fixture({unquote(columns), unquote(rows)}, unquote(focus))
        class = Layout.classify(state.size)
        [%{spans: spans}] = Status.project(state, class, state.size.columns)
        context = Context.of(state)

        assert cells(spans, state) <= state.size.columns

        expected = min(Density.budget(class).bindings + 1, length(Bindings.hinted(context)))
        assert Enum.count(spans, &(&1.style.role == :key)) == expected
      end
    end

    test "every hinted key is one the resolver routes in that context" do
      state = fixture({170, 40}, "composer")
      [%{spans: spans}] = Status.project(state, :xl, 170)
      keys = spans |> Enum.filter(&(&1.style.role == :key)) |> Enum.map(&SafeText.value(&1.text))

      # ? types in the composer, so help is hinted as F1 there or not at all.
      refute "?" in keys

      for key <- keys do
        assert Enum.any?(Bindings.hinted(:composer), fn binding ->
                 KeyLabel.label(Bindings.key_in_context(binding, :composer)) == key
               end)
      end
    end

    test "the strongest hints come first: Send leads the composer, Compose leads main" do
      composer = fixture({170, 40}, "composer")
      [%{spans: spans}] = Status.project(composer, :xl, 170)
      assert hd(labels(spans)) == "Send"

      main = fixture({170, 40}, "main")
      [%{spans: spans}] = Status.project(main, :xl, 170)
      assert hd(labels(spans)) == "Compose"
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
      assert String.starts_with?(row, "NORMAL 2d  ")

      insert = %{state | vim: %Vim{mode: :insert}}
      assert String.starts_with?(paint_last_row(insert), "INSERT  ")

      visual = %{state | vim: %Vim{mode: :visual}}
      assert String.starts_with?(paint_last_row(visual), "VISUAL  ")
    end

    test "the mode word is styled without a role cue, so it prints once" do
      state = %{fixture({120, 30}, "composer") | keymap: :vim, vim: %Vim{mode: :normal}}
      [%{spans: [mode | _]}] = Status.project(state, :medium, 120)
      assert SafeText.value(mode.text) == "NORMAL"
      assert mode.style.role == :plain
      assert :bold in mode.style.modifiers
    end

    test "with the default keymap the row still says Focus" do
      state = fixture({120, 30}, "composer")
      assert String.starts_with?(paint_last_row(state), "Focus: composer  ")
    end
  end

  describe "the tab row hint" do
    test "spells the three chords the table binds" do
      state = fixture({170, 40}, "main")
      {_shown, _overflow, hint} = Shell.tabline_plan(state, 170)

      for id <- [:run_palette, :runs_dashboard, :command_palette] do
        assert String.contains?(hint, KeyLabel.primary(Bindings.fetch(id)))
      end
    end
  end

  # ------------------------------------------------------------------ helpers

  defp fixture({columns, rows}, focus) do
    size = %Size{columns: columns, rows: rows}
    %{Fixtures.representative(:chat, size, %Capabilities{size: size}) | focus: focus}
  end

  defp cells(spans, state) do
    Enum.reduce(spans, 0, fn span, sum ->
      sum + Width.cells(SafeText.value(span.text), state.capabilities.ambiguous_width)
    end)
  end

  defp labels(spans) do
    spans
    |> Enum.filter(&(&1.style.role == :text_muted))
    |> Enum.map(&String.trim(SafeText.value(&1.text)))
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
