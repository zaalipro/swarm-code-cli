defmodule SwarmCodeCLI.UI.Paint.ShellFormatTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Paint,
    Projector,
    ReadModel,
    Size
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
      assert String.starts_with?(title, "SWARMCODE  ")
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
      assert String.starts_with?(String.trim(title), "SWARMCODE  FAKE — NO USER DATA · Build")
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
      assert status =~ "Ctrl-K"
    end

    test "medium shows 4 hints for composer focus" do
      state = fixture(:chat, {120, 40})
      plan = paint(state)
      status = row(plan, 39)
      refute status =~ "Tab Composer"
      assert status =~ "Enter"
      assert status =~ "Esc"
      assert status =~ "Ctrl-O"
      assert status =~ "Ctrl-K"
    end

    test "narrow shows 3 hints for composer focus" do
      state = fixture(:chat, {80, 24})
      plan = paint(state)
      status = row(plan, 23)
      assert status =~ "Enter"
      assert status =~ "Esc"
      assert status =~ "?"
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

  describe "navigator structure" do
    test "WORKSPACE heading at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      nav_row1 = row(plan, 1, 0, 26)
      assert nav_row1 =~ "WORKSPACE"
    end

    test "destination entries: Conversation and Activity with banner=nil" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      nav_row2 = row(plan, 2, 0, 26)
      nav_row3 = row(plan, 3, 0, 26)
      assert nav_row2 =~ "Conversation"
      assert nav_row3 =~ "Activity"
    end

    test "destination entries: all 5 with live banner" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      plan = paint(state)
      nav_row2 = row(plan, 2, 0, 26)
      nav_row3 = row(plan, 3, 0, 26)
      nav_row4 = row(plan, 4, 0, 26)
      nav_row5 = row(plan, 5, 0, 26)
      nav_row6 = row(plan, 6, 0, 26)
      assert nav_row2 =~ "Conversation"
      assert nav_row3 =~ "Activity"
      assert nav_row4 =~ "Workflows"
      assert nav_row5 =~ "Research"
      assert nav_row6 =~ "Memory"
    end

    test "RUNS heading appears after blank row with banner=nil" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      # With 2 destinations (rows 2-3), blank row at 4, RUNS at row 5
      nav_row5 = row(plan, 5, 0, 26)
      assert nav_row5 =~ "RUNS"
    end

    test "RUNS heading appears after blank row with live banner" do
      state = fixture(:chat, {170, 34}, banner: :persisted_banner)
      plan = paint(state)
      # With 5 destinations (rows 2-6), blank row at 7, RUNS at row 8
      nav_row8 = row(plan, 8, 0, 26)
      assert nav_row8 =~ "RUNS"
    end

    test "run entry with kind glyph at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      # Run entry after RUNS heading. With banner=nil: rows 2-3 dest, 4 blank, 5 RUNS, 6 run
      nav_row6 = row(plan, 6, 0, 26)
      assert nav_row6 =~ "Streaming conversation"
      # Has glyph before it (◉)
      assert nav_row6 =~ "◉"
    end

    test "empty state rows preserved" do
      state = fixture(:chat, {170, 34})
      # Remove all runs to trigger empty state
      state = put_in(state.read_model.runs, %{})
      state = put_in(state.read_model.order, %{})
      plan = paint(state)
      all_nav = for y <- 1..31, do: row(plan, y, 0, 26)
      nav_text = Enum.join(all_nav, "\n")
      assert nav_text =~ "No runs yet"
      assert nav_text =~ "Send a prompt to begin"
    end
  end

  describe "activity strip" do
    test "NEEDS 0 text at xl" do
      state = fixture(:chat, {170, 34})
      plan = paint(state)
      activity_row = row(plan, 29)
      assert activity_row =~ "NEEDS 0 · Activity"
    end
  end

  describe "monochrome and ASCII mode" do
    test "SWARMCODE appears in monochrome ASCII" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      plan = paint(state)
      title = row(plan, 0)
      assert title =~ "SWARMCODE"
    end

    test "ASCII glyphs in navigator" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      plan = paint(state)
      nav_row2 = row(plan, 2, 0, 26)
      assert nav_row2 =~ "*"
      assert nav_row2 =~ "Conversation"
    end

    test "Focus: composer in monochrome" do
      state = fixture(:chat, {170, 34}, color: :monochrome, ascii: true)
      plan = paint(state)
      status = row(plan, 33)
      assert status =~ "Focus: composer"
    end
  end
end
