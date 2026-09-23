defmodule SwarmCodeCLI.UI.DialogChromeTest do
  @moduledoc """
  Cell-level assertions for dialog chrome: title padding, the focus cue (the
  accent rail on the hover surface in colour, `FOCUS >` only in monochrome)
  and pinned strings across the switcher, question and unsent-changes
  dialogs at 120x40 and 80x24, in Unicode and ASCII; and the approval, which
  is drawn in the composer slot instead of a modal.
  """
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

  alias SwarmCodeCLI.UI.Projector.Support

  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  alias SwarmCodeCLI.UI.DataSource.DTO.{
    Approval,
    PendingInteraction,
    Question,
    QuestionOption
  }

  @sizes [{120, 40}, {80, 24}]

  # ── helpers ──────────────────────────────────────────────────────────────

  defp fixture({columns, rows}, color \\ :truecolor, ascii \\ false) do
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, ambiguous_width: :narrow, color_mode: color, ascii?: ascii}
    Fixtures.representative(:chat, size, caps)
  end

  defp paint(state) do
    {scene, table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)
    {scene, table, plan}
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

  defp screen(plan), do: Enum.map_join(0..(plan.size.rows - 1), "\n", &row(plan, &1))

  defp focus_count(plan), do: length(String.split(screen(plan), "FOCUS >")) - 1

  # Rows inside the dialog whose first cell after the border is the rail.
  defp rail_rows(plan, scene, state) do
    rail = SafeText.value(Support.glyph(:stripe, state))
    rect = scene.overlay.rect

    Enum.count((rect.y + 1)..(rect.y + rect.height - 2), fn y ->
      row(plan, y, rect.x + 1, 1) == rail
    end)
  end

  defp background(plan, x, y) do
    case Plan.cell(plan, x, y) do
      {:glyph, _, _, index} -> elem(plan.palette, index).background
      _ -> nil
    end
  end

  # At narrow/small sizes the dialog fills the screen and the status bar is
  # behind the dialog border.  Only assert the status row when the dialog
  # does NOT span the full screen height.
  defp assert_status_bar_when_visible(plan, scene) do
    rect = scene.overlay.rect

    if rect.y > 0 or rect.height < plan.size.rows do
      last_row = row(plan, plan.size.rows - 1)
      assert String.starts_with?(last_row, " Build")
    end
  end

  # ── switcher ─────────────────────────────────────────────────────────────

  describe "switcher dialog" do
    for {cols, rows} <- @sizes, ascii <- [false, true] do
      test "title padding and no focus words at #{cols}x#{rows} ascii=#{ascii}" do
        state = fixture({unquote(cols), unquote(rows)}, :truecolor, unquote(ascii))
        state = %{state | layers: [{:switcher, "layer-1"}], focus: "query"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        title_row = row(plan, scene.overlay.rect.y)
        assert title_row =~ " Search:"
        assert focus_count(plan) == 0
        assert screen(plan) =~ "Cancel"
        assert_status_bar_when_visible(plan, scene)
      end
    end

    test "a selected option is one rail row on the hover surface in colour" do
      state = fixture({120, 40})
      entries = SwarmCodeCLI.UI.Switcher.visible(state, %{})
      state = %{state | layers: [{:switcher, "layer-1"}], focus: hd(entries).id}
      {scene, _table, plan} = paint(state)

      assert focus_count(plan) == 0
      assert rail_rows(plan, scene, state) == 1

      rect = scene.overlay.rect

      y =
        Enum.find(
          (rect.y + 1)..(rect.y + rect.height - 2),
          &(row(plan, &1, rect.x + 1, 1) == "▐")
        )

      assert background(plan, rect.x + 4, y) ==
               Theme.style(:hover, state.capabilities).background.value
    end

    test "monochrome spells the focus once, in words" do
      state = fixture({120, 40}, :monochrome, true)
      entries = SwarmCodeCLI.UI.Switcher.visible(state, %{})
      state = %{state | layers: [{:switcher, "layer-1"}], focus: hd(entries).id}
      {_scene, _table, plan} = paint(state)
      assert focus_count(plan) == 1
    end
  end

  # ── question ─────────────────────────────────────────────────────────────

  describe "question dialog" do
    setup do
      interaction = %PendingInteraction{
        id: "test-question",
        run_id: "fixture-run",
        node_id: "test-node",
        conversation_id: "fixture-conversation",
        kind: :question,
        expected_revision: 3,
        state: :pending,
        question: %Question{
          prompt: "Question",
          options: [
            %QuestionOption{id: "opt-1", label: "First choice"},
            %QuestionOption{id: "opt-2", label: "Second choice"},
            %QuestionOption{id: "opt-3", label: "Third choice"}
          ]
        },
        allowed_actions: [:answer_question]
      }

      {:ok, interaction: interaction}
    end

    for {cols, rows} <- @sizes, ascii <- [false, true] do
      test "title padding and one focused option at #{cols}x#{rows} ascii=#{ascii}", %{
        interaction: interaction
      } do
        state = fixture({unquote(cols), unquote(rows)}, :truecolor, unquote(ascii))
        state = put_in(state.read_model.interactions[interaction.id], interaction)
        state = %{state | layers: [{:question, interaction.id}], focus: "opt-1"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        full = screen(plan)

        assert row(plan, scene.overlay.rect.y) =~ " Question "
        assert focus_count(plan) == 0
        assert rail_rows(plan, scene, state) == 1

        assert full =~ "Option 1"
        assert full =~ "Option 2"
        assert full =~ "Cancel"
        assert full =~ ~r"1 of \d · Enter chooses"

        assert_status_bar_when_visible(plan, scene)
      end
    end

    test "monochrome marks the focused option with FOCUS > once", %{interaction: interaction} do
      state = fixture({120, 40}, :monochrome, true)
      state = put_in(state.read_model.interactions[interaction.id], interaction)
      state = %{state | layers: [{:question, interaction.id}], focus: "opt-1"}
      {_scene, _table, plan} = paint(state)
      assert focus_count(plan) == 1
    end
  end

  # ── approval ─────────────────────────────────────────────────────────────

  describe "approval in the composer slot" do
    setup do
      interaction = %PendingInteraction{
        id: "test-approval",
        run_id: "fixture-run",
        node_id: "test-approval-node",
        conversation_id: "fixture-conversation",
        kind: :approval,
        expected_revision: 3,
        state: :pending,
        approval: %Approval{
          tool: "write_file",
          permission: :write,
          arguments_preview: "lib/auth/session.ex"
        },
        allowed_actions: [:approve, :deny, :always_allow]
      }

      {:ok, interaction: interaction}
    end

    for {cols, rows} <- @sizes, ascii <- [false, true] do
      test "the opened approval keeps the conversation in view at #{cols}x#{rows} ascii=#{ascii}",
           %{interaction: interaction} do
        state = fixture({unquote(cols), unquote(rows)}, :truecolor, unquote(ascii))
        state = put_in(state.read_model.interactions[interaction.id], interaction)
        state = %{state | layers: [{:approval, interaction.id}], focus: "approve"}
        {scene, table, plan} = paint(state)

        assert scene.overlay == nil
        full = screen(plan)

        assert full =~ "Review this synthetic project"
        assert full =~ "The assistant wants to change a file"
        assert full =~ "lib/auth/session.ex"
        assert full =~ "y once"
        # The legacy :always_allow is what the service reads as "for this run".
        assert full =~ "A for this run"
        assert full =~ "d deny"
        assert focus_count(plan) == 0
        assert row(plan, plan.size.rows - 1) =~ "1 waiting"

        for decision <- [:approve, :always_allow, :deny] do
          target =
            {:intent,
             {:resolve_approval, "fixture-run", "test-approval-node", "test-approval", 3,
              decision}}

          assert target in Map.values(table)
        end
      end
    end

    test "the focused decision sits on the warning chip", %{interaction: interaction} do
      state = fixture({120, 40})
      state = put_in(state.read_model.interactions[interaction.id], interaction)
      state = %{state | layers: [{:approval, interaction.id}], focus: "deny"}
      {_scene, _table, plan} = paint(state)

      y = Enum.find(0..(plan.size.rows - 1), &(row(plan, &1) =~ "d deny"))
      {x, _} = :binary.match(row(plan, y), "d deny")
      chip = Theme.style(:on_warn, state.capabilities).background.value
      assert background(plan, x, y) == chip
      refute background(plan, x - 12, y) == chip
    end

    test "monochrome brackets the focused decision", %{interaction: interaction} do
      state = fixture({120, 40}, :monochrome, true)
      state = put_in(state.read_model.interactions[interaction.id], interaction)
      state = %{state | layers: [{:approval, interaction.id}], focus: "approve"}
      {_scene, _table, plan} = paint(state)
      assert screen(plan) =~ "[y once]"
    end
  end

  # ── unsent changes ───────────────────────────────────────────────────────

  describe "unsent-changes dialog" do
    for {cols, rows} <- @sizes, ascii <- [false, true] do
      test "title padding and the focused control at #{cols}x#{rows} ascii=#{ascii}" do
        state = fixture({unquote(cols), unquote(rows)}, :truecolor, unquote(ascii))
        state = %{state | layers: [{:unsent_changes, :detach}], focus: "cancel"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        assert row(plan, scene.overlay.rect.y) =~ " UNSENT CHANGES "
        assert focus_count(plan) == 0
        # "CANCEL" pinned string preserved (from chrome(:cancel_exit) = "Esc CANCEL")
        assert screen(plan) =~ "CANCEL"
        assert_status_bar_when_visible(plan, scene)
      end
    end

    test "quitting with live runs asks about the runs" do
      state = fixture({120, 40})

      state =
        %{state | layers: [{:unsent_changes, :detach}], focus: "cancel"}
        |> Map.put(:quit_live_runs, 2)

      {scene, _table, plan} = paint(state)
      assert row(plan, scene.overlay.rect.y) =~ " Stop 2 live runs and quit? "
      assert screen(plan) =~ "They stop when SwarmCode quits."
    end
  end

  # ── gallery integration: data-focus="dialog" ─────────────────────────────

  describe "gallery integration" do
    test "dialog scenes set data-focus to dialog" do
      state = fixture({120, 40})
      state = %{state | layers: [{:switcher, "layer-1"}], focus: "query"}
      {scene, _table, _plan} = paint(state)
      assert scene.overlay != nil
      assert scene.overlay.id == "dialog"
    end
  end
end
