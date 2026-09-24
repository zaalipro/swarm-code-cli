defmodule SwarmCodeCLI.UI.Pass73HintsTest do
  @moduledoc """
  pass73 T6: the footer's key hints are true. After a send, the old row still
  said "Esc interrupt · Enter send" with an empty composer. Now Enter is hinted
  only when the composer has text and says what Enter does (send, steer,
  queue, run, complete); Esc only when it does something, naming it. These are
  the six states of acceptance item 6, pinned as the painted right edge of the
  status row at 170 columns (two hints).
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Fixtures, Paint, Projector, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Status

  @size %Size{columns: 170, rows: 40}

  test "1. empty composer, nothing running: neither Enter nor Esc" do
    row = status(idle())
    refute row =~ "Enter"
    refute row =~ "Esc"
    assert row =~ ~r/Ctrl-P palette   Ctrl-F hints\s*$/
  end

  test "2. a draft, nothing running: Enter sends" do
    row = status(typed(idle(), "explain the retry loop"))
    refute row =~ "Esc"
    assert row =~ ~r/Enter send   Ctrl-P palette\s*$/
  end

  test "3. empty composer while a turn runs: Esc stops it, by its agent's name" do
    row = status(live())
    refute row =~ "Enter"
    assert row =~ ~r/Esc stop Workflow author   Ctrl-P palette\s*$/
  end

  test "4. a draft while a turn runs: Esc stops it, Enter steers it" do
    row = status(typed(live(), "also cover the docs"))
    assert row =~ ~r/Esc stop Workflow author   Enter steer\s*$/
  end

  test "5. the slash palette open: Enter runs a bare command, completes one that takes an argument" do
    # /cost takes nothing: Enter runs it, Tab would leave "/cost ".
    row = status(typed(idle(), "/cos"))
    assert row =~ ~r/Enter run   Tab complete\s*$/

    # /search needs its words: Enter completes, the cursor waits.
    row = status(typed(idle(), "/sea"))
    assert row =~ ~r/Enter complete   Ctrl-P palette\s*$/
    # Tab would do what Enter does: it is not hinted twice.
    refute row =~ "Tab complete"
  end

  test "the palette's selected row names Enter's action too" do
    rows = fn state ->
      state
      |> SwarmCodeCLI.UI.Projector.Composer.slash_popup(120)
      |> Enum.map(fn %{spans: spans} ->
        Enum.map_join(spans, &SwarmCodeCLI.UI.SafeText.value(&1.text))
      end)
    end

    assert Enum.any?(rows.(typed(idle(), "/cos")), &(&1 =~ ~r/Enter run\s*$/))
    assert Enum.any?(rows.(typed(idle(), "/sea")), &(&1 =~ ~r/Enter complete\s*$/))
  end

  test "6. an approval card open: Esc sets it aside; the card carries its own keys" do
    row = status(approval(live()))
    refute row =~ "Enter"
    refute row =~ "Esc stop"
    assert row =~ ~r/Esc later   \? keys\s*$/
  end

  test "a live swarm is named as the run, not by its Lead" do
    state = %{
      Fixtures.representative(:swarm, @size, %Capabilities{size: @size})
      | focus: "composer"
    }

    assert status(state) =~ "Esc stop the swarm"
  end

  test "a turn the daemon will not stop is not offered to Esc" do
    state = live()
    runs = Map.new(state.read_model.runs, fn {id, run} -> {id, %{run | allowed_actions: []}} end)
    refute status(put_in(state.read_model.runs, runs)) =~ "Esc"
  end

  test "a long agent name is cut to fit, never wrapped into the row" do
    state = live("an agent whose name goes on and on and on past any sensible width")
    [{"Esc", words} | _] = Status.composer_hints(state)
    assert String.starts_with?(words, "stop an agent whose name")
    assert String.ends_with?(words, "…")
    assert String.length(words) <= 5 + 24
  end

  test "every Enter action has a word, and :none hides the hint" do
    for action <- [:send, :steer, :queue, :run_command, :complete],
        do: assert(is_binary(Status.enter_words(action)))

    assert Status.enter_words(:none) == nil
  end

  # ------------------------------------------------------------------ helpers

  defp base do
    %{Fixtures.representative(:chat, @size, %Capabilities{size: @size}) | focus: "composer"}
  end

  defp idle do
    state = base()
    runs = Map.new(state.read_model.runs, fn {id, run} -> {id, %{run | state: :done}} end)
    put_in(state.read_model.runs, runs)
  end

  defp live(name \\ "Workflow author") do
    state = base()

    agent = %DTO.AgentSummary{
      id: "agent-root",
      run_id: "fixture-run",
      name: name,
      role: :lead,
      depth: 0
    }

    put_in(state.read_model.agents[agent.id], agent)
  end

  defp approval(state) do
    item =
      Map.put(
        %DTO.PendingInteraction{
          id: "approval-1",
          kind: :approval,
          run_id: "fixture-run",
          node_id: "node-a",
          conversation_id: "fixture-conversation",
          expected_revision: 3,
          allowed_actions: [:approve, :deny, :always_allow],
          approval: %DTO.Approval{tool: "bash", permission: :execute, arguments_preview: "ls"}
        },
        :allowed_decisions,
        [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
      )

    state = put_in(state.read_model.interactions[item.id], item)
    %{state | layers: [{:approval, item.id}]}
  end

  defp typed(state, text) do
    key = State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:insert, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
  end

  defp status(state) do
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
