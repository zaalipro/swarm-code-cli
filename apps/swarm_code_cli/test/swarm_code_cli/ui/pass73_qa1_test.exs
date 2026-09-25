defmodule SwarmCodeCLI.UI.Pass73Qa1Test do
  @moduledoc """
  pass73 G1: the findings of QA #1's live check of the pass 73 release, each
  as a regression. Keys go through `Keymap.resolve/3` and `Reducer.update/2`,
  as in the session; the drawn ones are painted like the golden scenes.

    * Q1-01 `/com` Enter under an approval card that opened by itself runs
      (here queues) `/compact`, and the `/` list is drawn under the card.
    * Q1-02 the draft under that card takes the composer's editing and
      sending keys; Ctrl-C clears it before it closes the card; the
      "workflow" hint row is drawn.
    * Q1-03 wheel notches past the bottom are not stored, and wheeling back
      to the bottom follows again.
    * Q1-04 the card counts every request waiting, as the status row does.
    * Q1-05 (in `Pass73FinisherTest`) Enter on a card that shows all folds.
    * Q1-07 the workflow-run card names the workflow.
    * Q1-08 Ctrl-B on a narrow terminal keeps `/panel compact`.
    * Q1-09 a stale "Not sent" goes once the draft is edited or another
      request starts.
    * Q1-11 a run spoken by its kind is capitalised.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Composer, Input, Keymap, Layout, Paint, Projector, Reducer}
  alias SwarmCodeCLI.UI.{SafeText, SlashPalette, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{ApprovalCard, Status}

  # ---------------------------------------------------------------- fixtures

  defp approval(id, opts \\ []) do
    %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: Keyword.get(opts, :run, "r"),
      node_id: "op-" <> id,
      conversation_id: "c",
      expected_revision: 5,
      created_at: Keyword.get(opts, :created_at, 1),
      allowed_actions: [:approve, :deny, :always_allow],
      approval: %DTO.Approval{
        tool: Keyword.get(opts, :tool, "run_command"),
        permission: :execute,
        arguments_preview: Keyword.get(opts, :preview, "ls -la notes")
      }
    }
  end

  # A chat turn waiting on an approval that opened by itself over the
  # composer, past its grace window.
  defp under_card(interactions \\ [approval("a1")], opts \\ []) do
    state =
      ready(
        [run("r", :waiting_approval)],
        Keyword.merge([snapshot: %{interactions: interactions}], opts)
      )

    assert [{:approval, "a1"} | _] = state.layers
    assert state.auto_opened == "a1"
    %{state | interaction_grace: nil}
  end

  defp commands(effects), do: for({:command, request} <- effects, do: request.kind)

  defp key(code, mods \\ []), do: Input.key(code, mods)

  defp paint(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?,
        glyph_tier: state.capabilities.glyph_tier
      })

    for y <- 0..(plan.size.rows - 1) do
      for x <- 0..(plan.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp main_rows(state, rows) do
    rect = Layout.for_state(state).rects.main
    policy = state.capabilities.ambiguous_width

    rows
    |> Enum.slice(rect.y, rect.height)
    |> Enum.map(fn row ->
      {_, rest, _} = Width.take_cells(row, rect.x, policy)
      {kept, _, _} = Width.take_cells(rest, rect.width, policy)
      String.trim_trailing(kept)
    end)
  end

  defp index(rows, pattern), do: Enum.find_index(rows, &(&1 =~ pattern))

  # The screenshot-11 card as it opens by itself, with `draft` under it.
  defp scene_under_card(columns, rows, draft) do
    state = Pass73Scenes.screenshot_11(columns, rows, draft: draft)
    id = "demo-approval-80"
    %{state | layers: [{:approval, id}], focus: "cancel", auto_opened: id}
  end

  # ------------------------------------------------------------------ Q1-01

  describe "Q1-01 the / list under a card that opened by itself" do
    test "/com Enter queues /compact behind the waiting turn; the card stays" do
      state = type(under_card(), "/com")
      assert SlashPalette.open?(state)
      assert SlashPalette.selected(state).name == "compact"
      assert Composer.enter_action(state) == :queue

      {sent, effects} = press(state, key(:enter))
      assert [{:dispatch, :send, "/compact", :main, []}] = commands(effects)
      assert [{:approval, "a1"} | _] = sent.layers
    end

    test "/consens Enter leaves /consensus and the argument waits" do
      state = type(under_card(), "/consens")
      assert Composer.enter_action(state) == :complete

      {completed, effects} = press(state, key(:enter))
      assert commands(effects) == []
      assert text(completed) == "/consensus "
      assert [{:approval, "a1"} | _] = completed.layers
    end

    test "Tab completes it, and the arrows walk the list" do
      state = type(under_card(), "/co")
      first = SlashPalette.selected(state).name
      moved = press!(state, key(:down))
      refute SlashPalette.selected(moved).name == first
      assert text(press!(state, key(:tab))) == "/" <> first <> " "
    end

    test "the list is drawn on the composer, under the card and its blank row" do
      for {columns, rows} <- [{160, 45}, {120, 36}] do
        state = scene_under_card(columns, rows, "/com")
        main = main_rows(state, paint(state))
        bottom = index(main, ~r/^  ╰/)
        compact = index(main, ~r/\/compact/)

        assert bottom && compact && compact > bottom + 1, Enum.join(main, "\n")
        assert Enum.at(main, bottom + 1) == ""
        # The selected row's key word ("Enter queue", F7's word, was "Tab
        # complete") where the row has room for it.
        if columns == 160, do: assert(Enum.at(main, compact) =~ "Enter queue")
      end
    end
  end

  # ------------------------------------------------------------------ Q1-02

  describe "Q1-02 the draft under the card keeps the composer's keys" do
    test "Ctrl-S sends a message naming workflow as a plain message" do
      state = type(under_card(), "the workflow should print timings")
      assert Composer.enter_action(state) == :run_command

      {sent, effects} = press(state, ctrl("s"))

      assert [{:dispatch, :send, "the workflow should print timings", :main, []}] =
               commands(effects)

      assert [{:approval, "a1"} | _] = sent.layers
    end

    test "Left, Home, Ctrl-A, Ctrl-E and Ctrl-U edit the draft, not the card" do
      state = type(under_card(), "abc")

      state = press!(state, key(:left))
      state = type(state, "X")
      assert text(state) == "abXc"

      state = press!(state, ctrl("a"))
      state = type(state, "Y")
      assert text(state) == "YabXc"

      state = state |> press!(ctrl("e")) |> type("Z")
      assert text(state) == "YabXcZ"

      state = press!(state, key(:home))
      assert text(type(state, "!")) == "!YabXcZ"

      state = press!(state, ctrl("e"))
      assert text(press!(state, ctrl("u"))) == ""
      assert [{:approval, "a1"} | _] = state.layers
    end

    test "Ctrl-C clears the draft first; the next press puts the card aside" do
      state = type(under_card(), "/com")

      cleared = press!(state, ctrl("c"))
      assert text(cleared) == ""
      assert [{:approval, "a1"} | _] = cleared.layers
      assert cleared.quit_armed == nil

      aside = press!(cleared, ctrl("c"))
      assert aside.layers == []
    end

    test "Esc, PgDn and the letters on an empty draft stay the card's" do
      state = type(under_card(), "hello")

      later = press!(state, key(:escape))
      assert later.layers == []
      assert text(later) == "hello"

      assert {:ok, {:scroll, "dialog", _}} = Keymap.resolve(key(:page_down), state, %{})

      empty = under_card()
      {_, effects} = press(empty, letter("y"))
      assert [{:resolve_approval, "r", _, "a1", 5, :approve}] = commands(effects)
    end

    test "the status row says what Enter does with the draft; no n or ? words" do
      state = type(under_card(), "/com")

      words =
        state
        |> Status.project(Layout.classify(state.size), state.size.columns)
        |> status_text()

      # "Enter run" before: the list was closed under the card.
      assert words =~ "Enter queue"
      assert words =~ "Esc later"
      refute words =~ "next"
      refute words =~ "keys"
    end

    test "the workflow hint takes the row above the composer" do
      state = scene_under_card(160, 45, "the workflow should print timings")
      rows = paint(state)

      assert Enum.any?(
               rows,
               &(&1 =~ "workflow · sends as /create-workflow · Ctrl-S plain message")
             ),
             Enum.join(rows, "\n")
    end
  end

  defp status_text(blocks) do
    blocks
    |> List.wrap()
    |> Enum.flat_map(fn
      %{spans: spans} -> spans
      _ -> []
    end)
    |> Enum.map_join(&SafeText.value(&1.text))
  end

  # ------------------------------------------------------------------ Q1-03

  describe "Q1-03 the wheel at the bottom of the chat" do
    alias SwarmCodeCLI.UI.Projector.Workspace.Turns

    defp chat do
      items =
        for n <- 1..30 do
          %DTO.TranscriptItem{
            id: "i#{n}",
            node_id: "i#{n}",
            run_id: "r1",
            conversation_id: "c",
            attempt_id: "attempt",
            role: :user,
            text: "prompt number #{n}\nsecond line of #{n}"
          }
        end

      ready([run("r1", :done)],
        columns: 100,
        rows: 24,
        snapshot: %{transcript: %DTO.TranscriptWindow{items: items}}
      )
    end

    defp lines(state) do
      height = SwarmCodeCLI.UI.ScrollMetrics.content_height(state, :main)
      width = SwarmCodeCLI.UI.ScrollMetrics.viewport(state, :main).width
      {blocks, _first, _total} = Turns.viewport(state, width, height)

      blocks
      |> Enum.map_join("\n", fn block -> Enum.map_join(block.spans, &SafeText.value(&1.text)) end)
      |> String.split("\n")
    end

    defp notch(state, kind, times \\ 1) do
      %{main: main} = Layout.for_state(state).rects

      Enum.reduce(1..times, state, fn _, acc ->
        {:ok, action} =
          Keymap.resolve({:mouse, kind, nil, main.x + 2, main.y + 2, []}, acc, %{})

        elem(Reducer.update(acc, action), 0)
      end)
    end

    test "notches past the bottom are not stored: the next notch up moves three rows" do
      state = chat()
      following = lines(state)

      over = notch(state, :wheel_down, 5)
      assert over.scrolls.main.follow?
      assert lines(over) == following

      up = notch(over, :wheel_up)
      assert Enum.drop(lines(up), 3) == Enum.drop(following, -3)
    end

    test "wheeling back to the bottom follows the stream again" do
      up = notch(chat(), :wheel_up, 2)
      refute up.scrolls.main.follow?

      back = notch(up, :wheel_down, 2)
      assert back.scrolls.main.follow?
    end
  end

  # ------------------------------------------------------------------ Q1-04

  defp card_text(state) do
    width = Layout.for_state(state).rects.main.width

    case ApprovalCard.layout(state, width) do
      %{rows: rows} ->
        Enum.map(rows, fn {left, right} ->
          Enum.map_join(left ++ right, fn {text, _style} -> text end)
        end)

      nil ->
        []
    end
  end

  test "Q1-04 a card counts the one set aside, as the status row does" do
    state = under_card([approval("a1"), approval("a2", created_at: 2)])
    assert Enum.any?(card_text(state), &(&1 =~ "1 of 2 waiting"))

    # Esc sets a1 aside; a2 opens by itself and still says 1 of 2.
    state = press!(state, key(:escape))
    assert [{:approval, "a2"} | _] = state.layers
    assert Status.waiting_count(state) == 2

    assert Enum.any?(card_text(state), &(&1 =~ "1 of 2 waiting · n next")),
           inspect(card_text(state))
  end

  # ------------------------------------------------------------------ Q1-07

  test "Q1-07 the workflow-run card names the workflow and leaves continue out" do
    item =
      approval("a1",
        tool: "workflow_run",
        preview: ~s({"name":"format-compile-check","continue":true})
      )

    state = under_card([item])

    assert ApprovalCard.title(item, state) =~
             ~r/wants to run the workflow \/format-compile-check$/

    rows = card_text(state)
    refute Enum.any?(rows, &(&1 =~ "continue"))
    refute Enum.any?(rows, &(&1 =~ "workflow run"))

    with_args =
      approval("a1",
        tool: "workflow_run",
        preview: ~s({"name":"nightly","args":{"path":"lib"},"continue":false})
      )

    state = under_card([with_args])
    assert Enum.any?(card_text(state), &(&1 =~ ~s(args: {"path":"lib"})))

    one_off = approval("a1", tool: "workflow_run", preview: ~s({"source":"phase :a","budget":2}))
    assert ApprovalCard.title(one_off, state) =~ "wants to run a one-off workflow"
  end

  # ------------------------------------------------------------------ Q1-08

  test "Q1-08 Ctrl-B on a narrow terminal brings back compact, not full" do
    state = ready([], columns: 90, rows: 30, init: [panel_mode: :compact])

    {off, effects} = press(state, ctrl("b"))
    assert off.panel_mode == :hidden
    assert {:save_preferences, %{panel_mode: :hidden}} in effects

    {back, effects} = press(off, ctrl("b"))
    assert back.panel_mode == :compact
    assert {:save_preferences, %{panel_mode: :compact}} in effects

    # Loaded from cli.json after start, the same.
    {loaded, _} =
      Reducer.update(ready([], columns: 90, rows: 30), {:panel_preferences_loaded, :compact})

    loaded = loaded |> press!(ctrl("b")) |> press!(ctrl("b"))
    assert loaded.panel_mode == :compact
  end

  # ------------------------------------------------------------------ Q1-09

  describe "Q1-09 a refused send" do
    defp refused do
      state = ready([]) |> type("/com")
      {state, effects} = press(state, key(:enter))
      [request] = requests(effects)
      {state, _} = outcome(state, request, :rejected, [])
      assert {:settled, _, :rejected} = state.mutations[{:draft, key()}]
      state
    end

    test "goes once the draft is edited" do
      edited = press!(refused(), key(:backspace))
      refute Map.has_key?(edited.mutations, {:draft, key()})
    end

    test "goes once another request starts (a card answered), and stays until then" do
      state = type(under_card(), "hello")
      {state, effects} = press(state, key(:enter))
      [request] = requests(effects)
      {state, _} = outcome(state, request, :rejected, [])
      assert {:settled, _, :rejected} = state.mutations[{:draft, key()}]

      # A key that changes nothing about the draft keeps it.
      kept = press!(state, key(:page_down))
      assert {:settled, _, :rejected} = kept.mutations[{:draft, key()}]

      # The card put aside and brought back on purpose answers to y.
      focused = state |> press!(key(:escape)) |> press!(ctrl("n"))
      assert [{:approval, "a1"} | _] = focused.layers
      {answered, effects} = press(focused, letter("y"))
      assert [{:resolve_approval, "r", _, "a1", 5, :approve}] = commands(effects)
      assert text(answered) == "hello"
      refute Map.has_key?(answered.mutations, {:draft, key()})
    end
  end

  # ------------------------------------------------------------------ Q1-11

  test "Q1-11 a workflow run without an agent is spoken as Workflow" do
    item = %DTO.TranscriptItem{
      id: "w-1",
      node_id: "w-1",
      run_id: "w",
      conversation_id: "c",
      attempt_id: "attempt",
      role: :assistant,
      kind: :text,
      state: :done,
      text: "The checks passed."
    }

    state =
      ready([run("w", :done, kind: :workflow, title: "/format-check")],
        columns: 120,
        rows: 30,
        snapshot: %{transcript: %DTO.TranscriptWindow{items: [item]}}
      )

    rows = main_rows(state, paint(state))
    assert Enum.any?(rows, &(&1 =~ ~r/\bWorkflow\b/)), Enum.join(rows, "\n")
    refute Enum.any?(rows, &(&1 =~ ~r/^\s*\S+\s+workflow\b/))
  end
end
