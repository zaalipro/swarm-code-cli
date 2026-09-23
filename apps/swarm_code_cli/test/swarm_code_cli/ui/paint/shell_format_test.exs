defmodule SwarmCodeCLI.UI.Paint.ShellFormatTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Paint,
    Projector,
    SafeText,
    Size,
    Theme
  }

  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp fixture(kind, {columns, rows}, opts \\ []) do
    color = Keyword.get(opts, :color, :truecolor)
    ascii = Keyword.get(opts, :ascii, false)
    policy = Keyword.get(opts, :policy, :narrow)
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, ambiguous_width: policy, color_mode: color, ascii?: ascii}
    state = Fixtures.representative(kind, size, caps)

    case Keyword.get(opts, :banner) do
      nil -> state
      banner -> %{state | banner: banner}
    end
  end

  defp paint(state) do
    {scene, _table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)
    plan
  end

  defp row(plan, y, x \\ 0, width \\ nil) do
    width = width || plan.size.columns

    for column <- x..(x + width - 1), reduce: "" do
      text ->
        case Plan.cell(plan, column, y) do
          {:glyph, glyph, _, _} -> text <> glyph
          _ -> text
        end
    end
  end

  defp screen(plan) do
    for y <- 0..(plan.size.rows - 1), into: "", do: row(plan, y) <> "\n"
  end

  defp cell_style(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, _, _, style_idx} -> elem(plan.palette, style_idx)
      _ -> nil
    end
  end

  # One row for the title and the runs (ux M5): the mark and the project (or
  # the launcher's banner), then the run tabs and the switcher key. The mode,
  # model, tokens and cost live on the status line.
  # "Key label" pairs the status row may show, strongest first.
  defp hints(state) do
    context = SwarmCodeCLI.UI.Keymap.Context.of(state)

    context
    |> SwarmCodeCLI.UI.Keymap.Bindings.hinted()
    |> Enum.flat_map(fn binding ->
      case SwarmCodeCLI.UI.Keymap.Bindings.key_in_context(binding, context) do
        nil ->
          []

        key ->
          [
            SwarmCodeCLI.UI.Projector.KeyLabel.label(key, false) <>
              " " <> String.downcase(binding.label)
          ]
      end
    end)
  end

  describe "title bar (row 0)" do
    test "the logo mark leads the banner at xl" do
      state = fixture(:chat, {170, 34})
      title = row(paint(state), 0)
      assert String.starts_with?(title, " ⬢ FAKE DEMO — NO USER DATA   ")
    end

    test "a saved session reads as SwarmCode until the daemon names the project" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      title = row(paint(state), 0)
      assert String.starts_with?(title, " ⬢ SwarmCode   ")
      refute title =~ "SWARMCODE"
    end

    test "medium uses the compact banner and still carries the run tab" do
      state = fixture(:chat, {120, 40})
      title = row(paint(state), 0)
      assert title =~ "⬢ FAKE — NO USER DATA"
      assert title =~ "Streaming conversation"
      assert String.ends_with?(title, "Ctrl-R runs")
    end

    test "narrow keeps the banner and the tab on one row" do
      state = fixture(:chat, {80, 24})
      title = row(paint(state), 0)
      assert String.starts_with?(String.trim(title), "⬢ FAKE — NO USER DATA")
      assert title =~ "Streaming conversation"
    end

    test "small folds the tab into a count rather than a stub" do
      state = fixture(:chat, {50, 16})
      title = row(paint(state), 0)
      assert title =~ "FAKE"
      assert title =~ "+1"
    end

    test "the title row carries no mode, tokens or cost" do
      state = fixture(:chat, {170, 34})
      title = row(paint(state), 0)
      refute title =~ "Build"
      refute title =~ "tok"
      refute title =~ "$"
    end

    test "the logo mark is accent bold" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      style = cell_style(plan, 1, 0)
      assert :bold in style.modifiers
    end
  end

  describe "status bar (last row)" do
    test "the session's mode leads the row at xl, then its facts" do
      state = fixture(:chat, {170, 34})
      status = row(paint(state), 33)
      assert String.starts_with?(status, " Build · ctx 2k · $0.02")
      refute status =~ "Focus"
    end

    test "the mode leads at medium" do
      state = fixture(:chat, {120, 40})
      status = row(paint(state), 39)
      assert String.starts_with?(status, " Build")
    end

    test "key names are bold at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      status = row(plan, 33)
      {enter, _} = :binary.match(status, "Enter")
      assert :bold in cell_style(plan, enter, 33).modifiers
    end

    test "xl and medium show two hints for composer focus" do
      for {size, y} <- [{{170, 34}, 33}, {{120, 40}, 39}] do
        state = fixture(:chat, size)
        status = row(paint(state), y)
        [first, second | _] = hints(state)
        assert status =~ first
        assert status =~ second
      end
    end

    # The old row hinted "?" here, a key that types a question mark in the
    # composer; hints come from the binding table for the composer context.
    test "narrow and small show the one strongest hint" do
      for {size, y} <- [{{80, 24}, 23}, {{50, 16}, 15}] do
        state = fixture(:chat, size)
        status = row(paint(state), y)
        [first, second | _] = hints(state)
        assert status =~ first
        refute status =~ second
        refute status =~ "?"
      end
    end

    test "facts are separated by a quiet middle dot, never a focus label" do
      state = fixture(:chat, {170, 34})
      status = row(paint(state), 33)
      assert status =~ "Build · "
      refute status =~ "Focus: composer"
    end
  end

  # The navigator owned columns 0..25: a WORKSPACE heading on row 1, a list of
  # destinations, a RUNS heading and the run rows. The dock is gone. The runs
  # are tabs on the title row, main starts flush at column 0 on row 1, and the
  # destinations that used to be listed are reached through Ctrl-R and Ctrl-P.
  describe "the shell body after the navigator was removed" do
    test "no WORKSPACE heading: row 0 carries the run tabs and row 1 the prompt" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      refute screen(plan) =~ "WORKSPACE"
      assert row(plan, 0) =~ "Ctrl-R runs"
      assert row(plan, 1) =~ "Review this synthetic project"
    end

    test "no destination entries: main's band owns columns 0..25 from row 1 down" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      {scene, _} = Projector.project(state)
      main = Enum.find(scene.regions, &(&1.role == :main))

      # Main's band starts at column 0 and main takes all of it: the columns the
      # navigator used to own are the transcript's now, not a gutter or a dock.
      assert main.rect.x == 0
      assert main.rect.y == 1
      assert row(plan, 1, main.rect.x, main.rect.width) =~ "Review this synthetic project"
      refute screen(plan) =~ "◉ Conversation"
      refute screen(plan) =~ "◌ Activity"
    end

    test "no library destinations with a live banner" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      pixels = screen(paint(state))

      for label <- ["WORKSPACE", "Workflows", "Research", "Memory"] do
        refute pixels =~ label, "#{label} survived the navigator's removal"
      end
    end

    test "no RUNS heading with banner=nil: the tab row is the runs affordance" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      refute screen(plan) =~ "RUNS"
      assert row(plan, 0) =~ "Ctrl-R runs"
    end

    test "no RUNS heading with live banner either" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      plan = paint(state)
      refute screen(plan) =~ "RUNS"
      assert row(plan, 0) =~ "Ctrl-R runs"
    end

    test "the run is a tab on the title row carrying its kind mark" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      tab_row = row(plan, 0)
      assert tab_row =~ "Streaming conversation"
      assert tab_row =~ SafeText.value(SafeText.chrome(Theme.run_mark(:assistant)))
      assert tab_row =~ SafeText.value(SafeText.chrome(:dot))
    end

    test "with no runs the title row still offers the keys and main says what to do" do
      state = fixture(:chat, {170, 34})
      state = put_in(state.read_model.runs, %{})
      state = put_in(state.read_model.order, %{})
      state = put_in(state.read_model.transcript, %{})
      plan = paint(state)
      pixels = screen(plan)

      refute pixels =~ "No runs yet"
      assert row(plan, 0) =~ "Ctrl-R runs"
      assert pixels =~ "Ready to build"
      assert pixels =~ "Enter"
    end
  end

  describe "the composer's edge" do
    test "a hairline between the transcript and the composer when nothing waits" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      {scene, _} = Projector.project(state)
      composer = Enum.find(scene.regions, &(&1.role == :composer))
      edge = row(plan, composer.rect.y - 1, 0, composer.rect.width)
      refute edge =~ "waiting"
      assert edge == String.duplicate("─", composer.rect.width)
    end
  end

  describe "monochrome and ASCII mode" do
    test "the banner survives in monochrome ASCII with the ASCII logo twin" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      title = row(paint(state), 0)
      assert String.starts_with?(title, " # FAKE DEMO — NO USER DATA")
    end

    test "ASCII glyphs in the tab row" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      tab_row = row(paint(state), 0)
      assert tab_row =~ "* Streaming conversation"

      for unicode <- [:assistant_mark, :dot, :stripe] do
        refute tab_row =~ SafeText.value(SafeText.chrome(unicode)),
               "#{unicode} survived into ASCII mode on the tab row"
      end
    end

    test "the status row leads with the mode in monochrome" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      status = row(paint(state), 33)
      assert String.starts_with?(status, " Build")
    end
  end
end
