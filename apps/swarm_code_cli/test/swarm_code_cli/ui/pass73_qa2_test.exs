defmodule SwarmCodeCLI.UI.Pass73Qa2Test do
  @moduledoc """
  pass73 G2: the findings of QA #2's live check of the pass 73 release, each
  as a regression. Keys go through `Keymap.resolve/3` and `Reducer.update/2`,
  as in the session; the drawn ones are painted like the golden scenes.

    * Q2-01 a card the user focused (Ctrl-N, `n`) takes typed text the way a
      card that opened by itself does: "hey" types, it approves nothing. `?`
      opens the keys on an empty draft, as the status row says.
    * Q2-04 the workflow-run card leaves empty args out and gives its own
      rule, not "auto runs safe commands".
    * Q2-06 the card's footer counts its place in the walk `n` takes.
    * Q2-05 a resync the client asks for carries its reason (logged by the
      session, `Pass73Qa2RuntimeTest`), and a chat that followed its bottom
      still follows once the fresh snapshot lands.
    * Q2-08 the `/approval` picker shows what typing filters it by.
    * Q2-07 a workflow run is named in words in the band, the run row, the
      overlay and the transcript's tool rows, never `workflow_run`.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Composer, Input, Keymap, Layout, Paint, Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}
  alias SwarmCodeCLI.UI.Projector.{ApprovalCard, Panel, Status}

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

  # A chat turn waiting on two approvals; the first opened by itself over
  # the composer, past its grace window.
  defp under_card(interactions \\ [approval("a1"), approval("a2", created_at: 2)]) do
    state = ready([run("r", :waiting_approval)], snapshot: %{interactions: interactions})
    assert [{:approval, "a1"} | _] = state.layers
    assert state.auto_opened == "a1"
    %{state | interaction_grace: nil}
  end

  # The cards put aside with Esc (the second opens by itself when the first
  # is put aside), and one brought back with Ctrl-N: the user focused it.
  defp focused_card do
    state = press!(under_card(), key(:escape))
    assert [{:approval, "a2"} | _] = state.layers
    state = press!(state, key(:escape))
    assert state.layers == []
    state = press!(state, ctrl("n"))
    assert [{:approval, id} | _] = state.layers
    assert state.auto_opened == nil
    {state, id}
  end

  defp commands(effects), do: for({:command, request} <- effects, do: request.kind)

  defp key(code, mods \\ []), do: Input.key(code, mods)

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

  defp screen(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

    for y <- 0..(state.size.rows - 1) do
      for x <- 0..(state.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp status_words(state) do
    state
    |> Status.project(Layout.classify(state.size), state.size.columns)
    |> List.wrap()
    |> Enum.flat_map(fn
      %{spans: spans} -> spans
      _ -> []
    end)
    |> Enum.map_join(&SafeText.value(&1.text))
  end

  defp type_all(state, typed) do
    Enum.reduce(String.graphemes(typed), {state, []}, fn grapheme, {st, acc} ->
      {next, more} = press(st, letter(grapheme))
      {next, acc ++ more}
    end)
  end

  # ------------------------------------------------------------------ Q2-01

  describe "Q2-01 a card the user focused is typed at like one that opened by itself" do
    test "Ctrl-N, then hey: hey is the draft and nothing is decided" do
      {state, id} = focused_card()
      {state, effects} = type_all(state, "hey")

      assert commands(effects) == []
      assert text(state) == "hey"
      assert [{:approval, ^id} | _] = state.layers
    end

    test "n walks to the next card, and /consens then types, it does not walk" do
      state = press!(under_card(), letter("n"))
      assert [{:approval, "a2"} | _] = state.layers

      {state, effects} = type_all(state, "/consens")
      assert commands(effects) == []
      assert text(state) == "/consens"
      assert [{:approval, "a2"} | _] = state.layers

      # Enter completes it, the way it does under a card that opened by
      # itself, and the card stays.
      assert Composer.enter_action(state) == :complete
      {state, effects} = press(state, key(:enter))
      assert commands(effects) == []
      assert text(state) == "/consensus "
      assert [{:approval, "a2"} | _] = state.layers
    end

    test "on a focused card with an empty draft the card's own letters still decide" do
      {state, id} = focused_card()
      {_, effects} = press(state, letter("y"))
      assert [{:resolve_approval, "r", "op-" <> _, ^id, 5, :approve}] = commands(effects)

      # `n` is the next one, and a letter the card does not offer types.
      assert [{:approval, other} | _] = press!(state, letter("n")).layers
      refute other == id
      {typed, effects} = press(state, letter("a"))
      assert commands(effects) == []
      assert text(typed) == "a"
    end

    # The status row on a card with an empty draft says "? keys": `?` is one
    # of the card's own keys there, on either card, and types once the
    # draft has text.
    test "? opens the keys on an empty draft, on either card, and types after text" do
      {focused, _} = focused_card()

      for state <- [under_card(), focused] do
        assert status_words(state) =~ "? keys"
        {opened, _} = press(state, letter("?"))
        assert [:help | _] = opened.layers
        assert text(opened) == ""

        typed = state |> type("why") |> press!(letter("?"))
        assert text(typed) == "why?"
        assert [{:approval, _} | _] = typed.layers
      end
    end

    test "Enter sends a draft typed at a focused card; the card stays" do
      {state, id} = focused_card()
      state = type(state, "use the staging db")
      assert Keymap.typing_under_card?(state)
      assert Composer.enter_action(state) == :steer

      {sent, effects} = press(state, key(:enter))
      assert [{:dispatch, :send, "use the staging db", :main, []}] = commands(effects)
      assert [{:approval, ^id} | _] = sent.layers
    end
  end

  # ------------------------------------------------------------------ Q2-04

  test "Q2-04 the workflow-run card shows no empty args and says what auto does" do
    item =
      approval("a1",
        tool: "workflow_run",
        preview: ~s({"name":"format-and-test","args":{},"continue":true})
      )

    state =
      ready([run("r", :waiting_approval)],
        snapshot: %{interactions: [item], approval_mode: :auto}
      )

    rows = card_text(%{state | interaction_grace: nil})
    assert Enum.any?(rows, &(&1 =~ "wants to run the workflow /format-and-test"))
    refute Enum.any?(rows, &(&1 =~ "args"))
    refute Enum.any?(rows, &(&1 =~ "safe commands"))
    assert Enum.any?(rows, &(&1 =~ "auto asks before a workflow runs"))

    # Args that say something are still shown.
    with_args = %{
      item
      | approval: %{item.approval | arguments_preview: ~s({"name":"n","args":{"path":"lib"}})}
    }

    state =
      ready([run("r", :waiting_approval)],
        snapshot: %{interactions: [with_args], approval_mode: :auto}
      )

    assert Enum.any?(card_text(state), &(&1 =~ ~s(args: {"path":"lib"})))
  end

  # ------------------------------------------------------------------ Q2-06

  test "Q2-06 the footer counts the card's place in the walk n takes" do
    state = under_card([approval("a1"), approval("a2", created_at: 2), approval("a3")])
    assert Enum.any?(card_text(state), &(&1 =~ "1 of 3 waiting"))

    state = press!(state, letter("n"))
    assert [{:approval, "a2"} | _] = state.layers
    assert Enum.any?(card_text(state), &(&1 =~ "2 of 3 waiting"))

    state = press!(state, letter("n"))
    assert [{:approval, "a3"} | _] = state.layers
    assert Enum.any?(card_text(state), &(&1 =~ "3 of 3 waiting"))
  end

  # ------------------------------------------------------------------ Q2-07

  # Screenshot 11 with the Workflow author asking to run /format-and-test
  # (auto mode), after its workflow tool calls.
  defp workflow_scene(columns, rows) do
    state = Pass73Scenes.screenshot_11(columns, rows)
    chat = Pass73Scenes.chat_id()
    model = state.read_model
    old = model.interactions["demo-approval-80"]

    approval = %{
      old
      | run_id: chat,
        node_id: "wf-op",
        approval: %DTO.Approval{
          tool: "workflow_run",
          permission: :execute,
          arguments_preview: ~s({"name":"format-and-test","args":{},"continue":true}),
          agent_id: "agent-81-1",
          agent_name: "Workflow author",
          allowed_decisions: [:approve, :approve_run, :deny, :deny_stop]
        }
    }

    tools =
      for {{name, title}, n} <-
            Enum.with_index([
              {"workflow_list", "workflow_list"},
              {"workflow_smoke_check", "workflow_smoke_check"},
              {"workflow_save", "workflow_save format-and-test"},
              {"workflow_run", "workflow_run format-and-test"}
            ]) do
        %DTO.TranscriptItem{
          id: "wf-tool-#{n}",
          run_id: chat,
          conversation_id: "demo-panel",
          node_id: "wf-tool-node-#{n}",
          agent_id: "agent-81-1",
          revision: 1,
          role: :assistant,
          kind: :tool,
          state: :done,
          text: "",
          reasoning: "",
          attempt_id: "demo-attempt",
          created_sequence: 81_010 + n,
          at: state.now - 20_000 + n,
          tool: %DTO.ToolCall{name: name, title: title, status: :done, detail: "ok"}
        }
      end

    workspace = Map.get(model.snapshots, :workspace) || %DTO.WorkspaceSnapshot{}

    model = %{
      model
      | interactions: %{approval.id => approval},
        transcript: Map.merge(model.transcript, Map.new(tools, &{&1.id, &1})),
        order: %{model.order | workspace: model.order.workspace ++ Enum.map(tools, & &1.id)},
        snapshots: Map.put(model.snapshots, :workspace, %{workspace | approval_mode: :auto})
    }

    {%{state | read_model: model}, approval}
  end

  test "Q2-07 a workflow run is named in words in the band, the run row and the tool rows" do
    for {columns, rows} <- [{160, 45}, {120, 36}] do
      {state, approval} = workflow_scene(columns, rows)
      text = state |> screen() |> Enum.join("\n")

      assert text =~ "/format-and-test", text
      assert text =~ "run a workflow · auto asks", text
      refute text =~ "use workflow run", text
      refute text =~ "wants to use workflow", text
      refute text =~ "workflow_", text
      assert text =~ "list workflows"
      assert text =~ ~r/save workflow\s+format-and-test/
      assert text =~ ~r/run workflow\s+format-and-test/

      assert Panel.Model.short_ask(%{verb: :workflow}) == "wants to run a workflow"
      assert Panel.Model.request(approval) == "/format-and-test"
    end
  end

  test "Q2-07 the overlay's band names the workflow like the card" do
    {state, _approval} = workflow_scene(160, 45)

    {:ok, state} =
      SwarmCodeCLI.UI.Reducer.Overlay.open(state, Pass73Scenes.chat_id(), "agent-81-1")

    text = state |> screen() |> Enum.join("\n")
    assert text =~ "Workflow author wants to run the workflow /format-and-test", text
    refute text =~ "wants to run a command"
  end

  # ------------------------------------------------------------------ Q2-05

  defp said(id, seq, text) do
    %DTO.TranscriptItem{
      id: id,
      node_id: id,
      run_id: "r",
      conversation_id: "c",
      attempt_id: "attempt",
      revision: 1,
      role: :assistant,
      kind: :text,
      state: :done,
      text: text,
      reasoning: "",
      created_sequence: seq,
      at: seq
    }
  end

  test "Q2-05 a gap resyncs with its reason, and the chat still follows after the snapshot" do
    items = for n <- 1..40, do: said("i#{n}", n, "line #{n}\nsecond line of #{n}")

    state =
      ready([run("r", :running)],
        snapshot: %{transcript: %DTO.TranscriptWindow{items: items}}
      )

    assert state.scrolls.main.follow?
    watch = state.watches.workspace

    gap = %Delivery{
      kind: :delta,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 3,
      sequence: watch.sequence + 2,
      body: %Delta{
        kind: :run_update,
        entity_id: "r",
        run_id: "r",
        conversation_id: "c",
        body: run("r", :running),
        revision: 3,
        sequence: watch.sequence + 2
      }
    }

    {resyncing, [{:query, request}]} = Reducer.update(state, {:data, gap})
    assert request.kind == {:resync_watch, watch.watch_ref}
    assert resyncing.watches.workspace.resync_reason == :gap

    more = items ++ for n <- 41..60, do: said("i#{n}", n, "line #{n}")

    {fresh, _} =
      watch_ready(
        resyncing,
        [run("r", :running)],
        %{transcript: %DTO.TranscriptWindow{items: more}},
        4
      )

    assert fresh.watches.workspace.status == :ready
    assert fresh.watches.workspace.resync_reason == nil
    assert fresh.scrolls.main.follow?
  end

  # ------------------------------------------------------------------ Q2-08

  defp dialog(state) do
    {scene, _} = Projector.project(state)
    %SwarmCodeCLI.UI.Scene.Dialog{} = scene.overlay
  end

  test "Q2-08 the /approval picker shows what typing filters it by" do
    {state, _} = ready([]) |> paste("/approval") |> send()
    assert [{:switcher, _} | _] = state.layers

    assert String.trim(SafeText.value(dialog(state).title)) ==
             "Approvals · who asks before what runs"

    filtered = type(state, "au")
    assert String.trim(SafeText.value(dialog(filtered).title)) == "Approvals: au"
    text = filtered |> screen() |> Enum.join("\n")
    assert text =~ "Approvals: au"
    assert text =~ ~r/auto · edits go ahead/i
    refute text =~ ~r/full access · nothing asks first/i
    refute text =~ "NO RESULTS"

    # A filter that matches nothing says which filter it was.
    none = type(state, "/nosu")
    text = none |> screen() |> Enum.join("\n")
    assert text =~ "Approvals: /nosu", text
  end
end
