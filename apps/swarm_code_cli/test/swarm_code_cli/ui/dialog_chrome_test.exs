defmodule SwarmCodeCLI.UI.DialogChromeTest do
  @moduledoc """
  Cell-level assertions for dialog chrome: title padding, FOCUS > prefix,
  and pinned strings across switcher, question, approval, and unsent-changes
  dialogs at 120x40 and 80x24, in both truecolor and ASCII modes.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Fixtures,
    Paint,
    Projector,
    Size
  }

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

  # At narrow/small sizes the dialog fills the screen and the status bar is
  # behind the dialog border.  Only assert Focus: on the last row when the
  # dialog does NOT span the full screen height.
  defp assert_status_bar_when_visible(plan, scene) do
    rect = scene.overlay.rect

    if rect.y > 0 or rect.height < plan.size.rows do
      last_row = row(plan, plan.size.rows - 1)
      assert last_row =~ "Focus:"
    end
  end

  # ── switcher ─────────────────────────────────────────────────────────────

  describe "switcher dialog" do
    for {cols, rows} <- @sizes,
        {color, ascii} <- [{:truecolor, false}, {:truecolor, true}] do
      @tag size: {cols, rows}, ascii: ascii
      test "title padding and FOCUS > at #{cols}x#{rows} ascii=#{ascii}" do
        state = fixture({unquote(cols), unquote(rows)}, unquote(color), unquote(ascii))
        state = %{state | layers: [{:switcher, "layer-1"}], focus: "query"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        full = screen(plan)

        # Title must contain "Search:" (PTY invariant)
        title_row = row(plan, scene.overlay.rect.y)
        assert title_row =~ "Search:"

        # Title row has padding: space before "Search:"
        assert title_row =~ " Search:"

        # When focus is on "query", no option row gets FOCUS > but there is
        # no spurious occurrence either, so count is 0 or 1.
        assert focus_count(plan) <= 1

        # Footer contains "Cancel"
        assert full =~ "Cancel"

        # Status bar (only visible when dialog does not fill entire screen)
        assert_status_bar_when_visible(plan, scene)
      end
    end

    test "switcher with selected option shows exactly one FOCUS >" do
      state = fixture({120, 40})
      entries = SwarmCodeCLI.UI.Switcher.visible(state, %{})
      first_id = if entries != [], do: hd(entries).id, else: "cancel"
      state = %{state | layers: [{:switcher, "layer-1"}], focus: first_id}
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

    for {cols, rows} <- @sizes,
        {color, ascii} <- [{:truecolor, false}, {:truecolor, true}] do
      @tag size: {cols, rows}, ascii: ascii
      test "title padding and FOCUS > at #{cols}x#{rows} ascii=#{ascii}", %{
        interaction: interaction
      } do
        state = fixture({unquote(cols), unquote(rows)}, unquote(color), unquote(ascii))
        state = put_in(state.read_model.interactions[interaction.id], interaction)
        state = %{state | layers: [{:question, interaction.id}], focus: "opt-1"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        full = screen(plan)

        # Title has padding
        title_row = row(plan, scene.overlay.rect.y)
        assert title_row =~ " Question "

        # Exactly one FOCUS >
        assert focus_count(plan) == 1

        # Option format preserved: "Option N"
        assert full =~ "Option 1"
        assert full =~ "Option 2"

        # Footer: "Cancel" and "item N of M"
        assert full =~ "Cancel"
        assert full =~ "item 1 of"

        # Status bar when visible
        assert_status_bar_when_visible(plan, scene)
      end
    end
  end

  # ── approval ─────────────────────────────────────────────────────────────

  describe "approval dialog" do
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

    for {cols, rows} <- @sizes,
        {color, ascii} <- [{:truecolor, false}, {:truecolor, true}] do
      @tag size: {cols, rows}, ascii: ascii
      test "title padding and FOCUS > at #{cols}x#{rows} ascii=#{ascii}", %{
        interaction: interaction
      } do
        state = fixture({unquote(cols), unquote(rows)}, unquote(color), unquote(ascii))
        state = put_in(state.read_model.interactions[interaction.id], interaction)
        state = %{state | layers: [{:approval, interaction.id}], focus: "approve"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        full = screen(plan)

        # Title has padding — the approval card is titled by who wants what
        title_row = row(plan, scene.overlay.rect.y)
        assert title_row =~ " The agent wants to change a file "

        # Exactly one FOCUS >
        assert focus_count(plan) == 1

        # Approval options preserved
        assert full =~ "Approve"
        assert full =~ "Deny"
        assert full =~ "Always allow"

        # Footer: "Cancel" and "PgUp/PgDn: scroll arguments"
        assert full =~ "Cancel"
        assert full =~ "PgUp/PgDn: scroll arguments"

        # Status bar when visible
        assert_status_bar_when_visible(plan, scene)
      end
    end
  end

  # ── unsent changes ───────────────────────────────────────────────────────

  describe "unsent-changes dialog" do
    for {cols, rows} <- @sizes,
        {color, ascii} <- [{:truecolor, false}, {:truecolor, true}] do
      @tag size: {cols, rows}, ascii: ascii
      test "title padding and FOCUS > at #{cols}x#{rows} ascii=#{ascii}" do
        state = fixture({unquote(cols), unquote(rows)}, unquote(color), unquote(ascii))
        state = %{state | layers: [{:unsent_changes, :detach}], focus: "cancel"}
        {scene, _table, plan} = paint(state)

        assert scene.overlay != nil
        full = screen(plan)

        # Title has padding — "UNSENT CHANGES" pinned string preserved
        title_row = row(plan, scene.overlay.rect.y)
        assert title_row =~ " UNSENT CHANGES "

        # Exactly one FOCUS >
        assert focus_count(plan) == 1

        # "CANCEL" pinned string preserved (from chrome(:cancel_exit) = "Esc CANCEL")
        assert full =~ "CANCEL"

        # Status bar when visible
        assert_status_bar_when_visible(plan, scene)
      end
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
