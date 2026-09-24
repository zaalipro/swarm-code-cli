defmodule SwarmCodeCLI.UI.Projector.Pass73TranscriptTest do
  @moduledoc """
  pass73 owner V1, the transcript side of the owner's notes:

    * T1 `/diff off` (K's `show_diffs`): every tool row is its one line —
      verb, target, meta — with no inline diff or "… N more lines" tail (the
      owner's `git diff` row had grown a 12-line red block in the Lead's turn);
    * T5: "workflow" highlighted in the sent message, as in the composer;
    * T3/T8: a message the running turn took in says so, and what waits on
      the queue shows after the live turn;
    * T7: every change of the approval policy prints a notice.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, ScrollMetrics, Size, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  defp scene(name, {columns, rows}) do
    size = %Size{columns: columns, rows: rows}
    Conversation.state(name, size, %Capabilities{size: size, color_mode: :truecolor})
  end

  defp paint(state) do
    {scene, _table} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

    assert plan.diagnostics == []
    {scene, plan}
  end

  defp rows(plan) do
    for y <- 0..(plan.size.rows - 1) do
      for x <- 0..(plan.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
      |> String.trim_trailing()
    end
  end

  # The main region's rows, so the panel beside them never matches.
  defp main_rows(state) do
    {_scene, plan} = paint(state)
    rect = SwarmCodeCLI.UI.Layout.for_state(state).rects.main

    plan
    |> rows()
    |> Enum.slice(rect.y, rect.height)
    |> Enum.map(fn row ->
      {_, rest, _} = Width.take_cells(row, rect.x, :narrow)
      {kept, _, _} = Width.take_cells(rest, rect.width, :narrow)
      String.trim_trailing(kept)
    end)
  end

  defp style(plan, x, y) do
    {:glyph, _, _, index} = Plan.cell(plan, x, y)
    elem(plan.palette, index)
  end

  defp find(rows, pattern), do: Enum.find_index(rows, &(&1 =~ pattern))

  # The heights ScrollMetrics reports stay the rows painted (the viewport's
  # invariant) with the new rows in place.
  defp assert_heights(state) do
    width = ScrollMetrics.viewport(state, :main).width
    {blocks, _first, _total} = Turns.viewport(state, width, 100_000)

    painted =
      blocks
      |> Enum.map(fn block ->
        Enum.count(block.spans, &(SwarmCodeCLI.UI.SafeText.value(&1.text) == "\n")) + 1
      end)
      |> Enum.sum()

    heights =
      state |> Turns.view_order() |> Enum.map(&Turns.height(state, width, &1)) |> Enum.sum()

    assert painted == heights
  end

  @git_diff """
  diff --git a/lib/tickets/guard.ex b/lib/tickets/guard.ex
  index 1111111..2222222 100644
  --- a/lib/tickets/guard.ex
  +++ b/lib/tickets/guard.ex
  @@ -1,53 +0,0 @@
  """

  defp git_diff_state do
    state = scene(:trouble, {120, 60})
    id = "demo-run-2-item-005"
    item = state.read_model.transcript[id]
    removed = Enum.map_join(1..53, "\n", &"-  old line #{&1}")

    tool = %{item.tool | title: "run git diff", exit_code: 0}
    item = %{item | text: @git_diff <> removed, tool: tool}
    put_in(state.read_model.transcript[id], item)
  end

  describe "T1 /diff" do
    test "shown: an edit keeps its first hunk in place, a git diff its red block" do
      rows = git_diff_state() |> paint() |> elem(1) |> rows()
      edit = find(rows, ~r/edit +lib\/tickets\/guard\.ex +\+5 −1/)
      assert Enum.at(rows, edit + 1) =~ ~r/^ +@@ -12,9 \+12,13 @@/
      diff = find(rows, ~r/run +git diff +\+0 −53/)
      assert diff, Enum.join(rows, "\n")
      assert Enum.at(rows, diff + 1) =~ ~r/^ +@@ -1,53 \+0,0 @@/
      assert Enum.any?(rows, &(&1 =~ ~r/^ +… \d+ more lines · Enter opens$/))
    end

    test "hidden: every tool row is one line — verb, target, meta — and no tail" do
      state = git_diff_state() |> Map.put(:show_diffs, false)
      rows = state |> paint() |> elem(1) |> rows()

      edit = find(rows, ~r/edit +lib\/tickets\/guard\.ex +\+5 −1 +14ms$/)
      assert edit, Enum.join(rows, "\n")
      refute Enum.at(rows, edit + 1) =~ "@@"
      assert find(rows, ~r/read +lib\/tickets\/guard\.ex +48 lines/)

      diff = find(rows, ~r/run +git diff +\+0 −53/)
      assert diff
      assert Enum.at(rows, diff + 1) =~ ~r/run +mix phx\.server|^\s*$/

      refute Enum.any?(rows, &(&1 =~ "@@"))
      refute Enum.any?(rows, &(&1 =~ "old line"))
      refute Enum.any?(rows, &(&1 =~ "more lines"))
      assert_heights(state)
    end

    test "hidden: a row the user opened with Enter still shows what it opened" do
      state =
        git_diff_state()
        |> Map.put(:show_diffs, false)
        |> Map.put(:expansions, MapSet.new(["demo-run-2-item-003"]))

      state =
        put_in(state.read_model.transcript["demo-run-2-item-003"].text, "line one\nline two")

      rows = state |> paint() |> elem(1) |> rows()
      read = find(rows, ~r/read +lib\/tickets\/guard\.ex/)
      assert Enum.at(rows, read + 1) =~ "line one"
    end
  end

  describe "T5 the word workflow" do
    defp with_user_text(text) do
      state = scene(:trouble, {120, 60})
      id = "demo-run-2-item-000"
      put_in(state.read_model.transcript[id].text, text)
    end

    defp keyword_style?(plan, rows, word_at_row, word) do
      y = find(rows, word_at_row)
      row = Enum.at(rows, y)
      [before | _] = String.split(row, word, parts: 2)
      x = Width.cells(before, :narrow)
      s = style(plan, x, y)
      caps = %Capabilities{size: %Size{columns: 120, rows: 60}, color_mode: :truecolor}
      s.foreground == Theme.style(:run_workflow, caps).foreground.value and :bold in s.modifiers
    end

    test "the sent message highlights the whole word workflow, not a slash command" do
      state = with_user_text("please review the Workflow before we ship the `workflow` flag")
      {_scene, plan} = paint(state)
      rows = rows(plan)
      assert keyword_style?(plan, rows, ~r/please review the Workflow/, "Workflow")
      refute keyword_style?(plan, rows, ~r/please review the Workflow/, "`workflow`")
      refute keyword_style?(plan, rows, ~r/please review the Workflow/, "please")
    end

    test "a message sent as /create-workflow highlights the command and the word" do
      state = with_user_text("/create-workflow a nightly workflow for the ticket guard")
      {_scene, plan} = paint(state)
      rows = rows(plan)
      assert keyword_style?(plan, rows, ~r/create-workflow a nightly/, "/create-workflow")
      assert keyword_style?(plan, rows, ~r/create-workflow a nightly/, "workflow for")
      refute keyword_style?(plan, rows, ~r/create-workflow a nightly/, "nightly")
    end

    test "a slash command naming workflows is not highlighted" do
      state = with_user_text("/swarm check the workflows")
      {_scene, plan} = paint(state)
      rows = rows(plan)
      refute keyword_style?(plan, rows, ~r/swarm check the workflows/, "workflows")
    end

    test "the highlight follows a message wrapped over rows" do
      long = String.duplicate("words ", 12) <> "then the workflow at the end"
      state = with_user_text(long)
      {_scene, plan} = paint(state)
      rows = rows(plan)
      at = find(rows, ~r/workflow at the end/)
      assert at && not (Enum.at(rows, at) =~ "words words"), Enum.join(rows, "\n")
      assert keyword_style?(plan, rows, ~r/workflow at the end/, "workflow at")
    end
  end

  describe "T3/T8 where a send went" do
    defp chat_item(state, fields) do
      now = state.now

      item =
        struct!(
          %DTO.TranscriptItem{
            id: "demo-panel-run-81-item-81005",
            run_id: Pass73Scenes.chat_id(),
            conversation_id: "demo-panel",
            node_id: "n-81005",
            revision: 1,
            role: :user,
            state: :done,
            text: "",
            reasoning: "",
            attempt_id: "a",
            created_sequence: 81_005,
            at: now - 5_000
          },
          fields
        )

      order = state.read_model.order.workspace ++ [item.id]

      %{
        state
        | read_model: %{
            state.read_model
            | transcript: Map.put(state.read_model.transcript, item.id, item),
              order: %{state.read_model.order | workspace: order}
          }
      }
    end

    test "a message the running turn took in says → to the running turn" do
      state =
        Pass73Scenes.screenshot_11(160, 45)
        |> chat_item(
          text: "also check the admin plans",
          target_kind: :steer,
          target_id: Pass73Scenes.chat_id()
        )

      rows = main_rows(state)
      at = find(rows, ~r/▏ also check the admin plans/)
      assert at, Enum.join(rows, "\n")
      assert Enum.at(rows, at + 1) =~ ~r/^ +→ to the running turn/
      assert_heights(state)
    end

    test "K's delivery marked :steered marks the message before the wire says so" do
      state =
        Pass73Scenes.screenshot_11(160, 45)
        |> chat_item(text: "also check the admin plans")
        |> Map.put(:deliveries, [
          %{
            id: "d1",
            conversation_id: "demo-panel",
            run_id: Pass73Scenes.chat_id(),
            text: "also check the admin plans",
            status: :steered,
            at: 0,
            reason: nil
          }
        ])

      rows = main_rows(state)
      at = find(rows, ~r/▏ also check the admin plans/)
      assert Enum.at(rows, at + 1) =~ "→ to the running turn"
    end

    test "what waits on the queue shows after the live turn, never dropped" do
      state = Pass73Scenes.screenshot_11(160, 45)

      workspace =
        Map.put(state.read_model.snapshots.workspace, :queued_texts, [
          "/compact",
          "then tidy the plans"
        ])

      state = put_in(state.read_model.snapshots.workspace, workspace)

      rows = main_rows(state)
      compact = find(rows, ~r/▏ \/compact$/)
      tidy = find(rows, ~r/▏ then tidy the plans$/)
      assert compact && tidy && tidy > compact, Enum.join(rows, "\n")
      assert Enum.at(rows, compact + 1) =~ "queued · sends after the running turn"
      author = find(rows, ~r/Workflow author  deepseek/)
      assert compact > author
      assert_heights(state)
    end

    test "a send on its way shows until its message is in the transcript" do
      delivery = %{
        id: "d2",
        conversation_id: "demo-panel",
        run_id: nil,
        text: "and the deploy plans",
        status: :sending,
        at: 1_788_436_800_000 - 100,
        reason: nil
      }

      state = Pass73Scenes.screenshot_11(160, 45) |> Map.put(:deliveries, [delivery])
      rows = main_rows(state)
      at = find(rows, ~r/▏ and the deploy plans$/)
      assert at && Enum.at(rows, at + 1) =~ "sending…"

      state = chat_item(state, text: "and the deploy plans", at: delivery.at + 50)
      rows = main_rows(state)
      refute Enum.any?(rows, &(&1 =~ "sending…"))
    end
  end

  describe "T7 the policy notice" do
    test "every change of the approval policy prints Approvals: from → to" do
      state = Pass73Scenes.screenshot_11(160, 45)
      at = state.now - 20_000

      state =
        Map.put(state, :policy_notices, [
          %{conversation_id: "demo-panel", from: :auto, to: :full_access, at: at},
          %{conversation_id: "other", from: :auto, to: :read_only, at: at}
        ])

      rows = main_rows(state)
      notice = find(rows, ~r/^ +Approvals: auto → full access$/)
      assert notice, Enum.join(rows, "\n")
      refute Enum.any?(rows, &(&1 =~ "read-only$"))
      assert notice > find(rows, ~r/create-workflow a nightly check/)
      assert_heights(state)
    end
  end
end
