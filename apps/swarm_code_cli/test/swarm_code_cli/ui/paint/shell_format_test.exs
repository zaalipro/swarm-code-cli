defmodule SwarmCodeCLI.UI.Paint.ShellFormatTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Paint,
    Projector,
    ReadModel,
    SafeText,
    Size,
    Theme
  }

  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.DataSource.DTO

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

  describe "title bar (row 0)" do
    test "SWARMCODE wordmark appears first at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      title = row(plan, 0)
      # After W5 Change 2, the logo mark appears before the wordmark
      assert title =~ "⬢ SWARMCODE  "
    end

    test "contiguous banner triple is preserved at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      title = row(plan, 0)
      assert title =~ "FAKE DEMO — NO USER DATA · Build"
    end

    test "contiguous banner triple at medium uses compact banner" do
      state = fixture(:chat, {120, 40})
      plan = paint(state)
      title = row(plan, 0)
      assert title =~ "SWARMCODE  FAKE — NO USER DATA · Build"
    end

    test "contiguous banner triple at narrow" do
      state = fixture(:chat, {80, 24})
      plan = paint(state)
      title = row(plan, 0)
      # After W5 Change 2, the logo mark appears before the wordmark
      assert String.starts_with?(String.trim(title), "⬢ SWARMCODE  FAKE — NO USER DATA · Build")
    end

    test "contiguous banner triple at small" do
      state = fixture(:chat, {50, 16})
      plan = paint(state)
      title = row(plan, 0)
      assert title =~ "SWARMCODE"
      assert title =~ "Build"
    end

    test "right-aligned counts appear when running" do
      state = fixture(:chat, {170, 34})
      # Add a shell snapshot with counts
      counts = %DTO.Counts{running: 1}

      shell_snapshot = %DTO.ShellSnapshot{
        runs: [],
        connection: %DTO.Connection{source_epoch: "e"},
        counts: counts
      }

      state = %{state | read_model: ReadModel.snapshot(state.read_model, :shell, shell_snapshot)}
      plan = paint(state)
      title = row(plan, 0)
      assert title =~ "◉ 1 running"
    end

    test "wordmark is accent bold (has bold modifier)" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      # The first cell 'S' in SWARMCODE should have bold modifier
      style = cell_style(plan, 0, 0)
      assert :bold in style.modifiers
    end
  end

  describe "status bar (last row)" do
    test "Focus: composer is contiguous at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      status = row(plan, 33)
      assert status =~ "Focus: composer"
    end

    test "Focus: composer at medium" do
      state = fixture(:chat, {120, 40})
      plan = paint(state)
      status = row(plan, 39)
      assert status =~ "Focus: composer"
    end

    test "key names are bold (key role) at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      # Find the "Tab" key hint - it's after "Focus: composer  "
      # "Focus: composer" is 16 chars, "  " is 2, so "Tab" starts at position 18
      status = row(plan, 33)
      tab_pos = :binary.match(status, "Tab") |> elem(0)
      tab_style = cell_style(plan, tab_pos, 33)
      assert :bold in tab_style.modifiers
    end

    test "xl shows 5 hints for composer focus" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      status = row(plan, 33)
      assert status =~ "Tab"
      assert status =~ "Enter"
      assert status =~ "Esc"
      assert status =~ "Ctrl-O"
      assert status =~ "Ctrl-P"
    end

    test "medium shows 4 hints for composer focus" do
      state = fixture(:chat, {120, 40})
      plan = paint(state)
      status = row(plan, 39)
      refute status =~ "Tab Composer"
      assert status =~ "Enter"
      assert status =~ "Esc"
      assert status =~ "Ctrl-O"
      assert status =~ "Ctrl-P"
    end

    # The old row hinted "?" here, a key that types a question mark in the
    # composer; hints now come from the binding table for the composer context,
    # where the third strongest is the command palette.
    test "narrow shows 3 hints for composer focus" do
      state = fixture(:chat, {80, 24})
      plan = paint(state)
      status = row(plan, 23)
      assert status =~ "Enter"
      assert status =~ "Esc"
      assert status =~ "Ctrl-P"
      refute status =~ "?"
    end

    test "small shows 2 hints for composer focus" do
      state = fixture(:chat, {50, 16})
      plan = paint(state)
      status = row(plan, 15)
      assert status =~ "Enter"
      assert status =~ "Esc"
    end

    test "two-space separator between focus and hints (not middle dot)" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      status = row(plan, 33)
      # The old format used " · " between Focus: and keys
      refute status =~ "Focus: composer · "
      assert status =~ "Focus: composer  "
    end
  end

  # The navigator owned columns 0..25: a WORKSPACE heading on row 1, a list of
  # destinations, a RUNS heading and the run rows. The dock is gone. Row 1 is the
  # tab row, main starts flush at column 0, and the destinations that used to be
  # listed are reached through the keys the tab row advertises.
  describe "the shell body after the navigator was removed" do
    test "no WORKSPACE heading: row 1 is the tab row" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      refute screen(plan) =~ "WORKSPACE"
      assert row(plan, 1) =~ "Ctrl-R runs"
      assert row(plan, 1) =~ "Ctrl-G all"
    end

    test "no destination entries: main's band owns columns 0..25 from row 2 down" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      {scene, _} = Projector.project(state)
      main = Enum.find(scene.regions, &(&1.role == :main))

      # Main's band starts at column 0 and its reading measure is centred inside
      # it, so main reaches into the columns the navigator used to own and the
      # rest of them are its empty gutter, not a dock.
      assert main.rect.x < 26
      assert row(plan, 2, main.rect.x, main.rect.width) =~ "Streaming conversation"
      assert String.trim(row(plan, 2, 0, main.rect.x)) == ""
      refute screen(plan) =~ "◉ Conversation"
      refute screen(plan) =~ "◌ Activity"
    end

    test "no library destinations with a live banner: Ctrl-P carries them" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      plan = paint(state)
      pixels = screen(plan)

      for label <- ["WORKSPACE", "Workflows", "Research", "Memory"] do
        refute pixels =~ label, "#{label} survived the navigator's removal"
      end

      assert row(plan, 1) =~ "Ctrl-P features"
    end

    test "no RUNS heading with banner=nil: the tab row is the runs affordance" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      refute screen(plan) =~ "RUNS"
      assert row(plan, 1) =~ "Ctrl-R runs"
    end

    test "no RUNS heading with live banner either" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      plan = paint(state)
      refute screen(plan) =~ "RUNS"
      assert row(plan, 1) =~ "Ctrl-R runs"
    end

    test "the run is a tab on row 1 carrying its kind mark" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      tab_row = row(plan, 1)
      # A tab elides the title to 20 cells; the run card in main keeps it whole.
      assert tab_row =~ "Streaming conversat"
      assert tab_row =~ SafeText.value(SafeText.chrome(Theme.run_mark(:assistant)))
      assert tab_row =~ SafeText.value(SafeText.chrome(:dot))
      assert row(plan, 2) =~ "Streaming conversation"
    end

    test "with no runs the tab row still offers the keys and main says what to do" do
      state = fixture(:chat, {170, 34})
      # Remove all runs to trigger empty state
      state = put_in(state.read_model.runs, %{})
      state = put_in(state.read_model.order, %{})
      plan = paint(state)
      pixels = screen(plan)

      # The navigator's "No runs yet / Send a prompt to begin" pair is gone; the
      # same guidance is main's welcome, and the keys are on the tab row.
      refute pixels =~ "No runs yet"
      assert row(plan, 1) =~ "Ctrl-R runs"
      assert pixels =~ "READY TO BUILD"
      assert pixels =~ "Ask for a change"
      assert pixels =~ "Type a request below and press Enter"
    end
  end

  describe "activity strip" do
    test "NEEDS 0 text at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      activity_row = row(plan, 29)
      refute activity_row =~ "Waiting for you"
      assert activity_row =~ "Activity"
    end
  end

  describe "monochrome and ASCII mode" do
    test "SWARMCODE appears in monochrome ASCII" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      plan = paint(state)
      title = row(plan, 0)
      assert title =~ "SWARMCODE"
    end

    test "ASCII glyphs in the tab row" do
      # The navigator's ASCII destination glyphs are gone with the dock; the tab
      # row is where the shell now spends its glyphs, and they degrade too.
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      plan = paint(state)
      tab_row = row(plan, 1)
      assert tab_row =~ "*"
      assert tab_row =~ "Streaming conversat"

      for unicode <- [:assistant_mark, :dot, :stripe] do
        refute tab_row =~ SafeText.value(SafeText.chrome(unicode)),
               "#{unicode} survived into ASCII mode on the tab row"
      end
    end

    test "Focus: composer in monochrome" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      plan = paint(state)
      status = row(plan, 33)
      assert status =~ "Focus: composer"
    end
  end
end
