defmodule SwarmCodeCLI.UI.Pass73FinisherTest do
  @moduledoc """
  Pass 73 finisher: the seams between owners S (wire), K (keys, state), V1
  (cards, transcript) and V2 (status), each as a regression. Keys go through
  `Keymap.resolve/3` and `Reducer.update/2`, as in the session.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers,
    only: [ready: 1, run: 2, run: 3, press: 2, paste: 2, send: 1, requests: 1]

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Composer, Input, Keymap, Layout, Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Delivery}
  alias SwarmCodeCLI.UI.Projector.{ApprovalCard, Status}

  defp answer(state, request, fields) do
    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :response,
         request_id: request.request_id,
         watch_ref: nil,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: struct!(%DTO.Outcome{request_id: request.request_id}, fields)
       }}
    )
  end

  defp commands(effects), do: for({:command, request} <- effects, do: request.kind)

  describe "Enter on the approval card (V1's request K1)" do
    # The screenshot-11 card: a four-line curl | python3 command from a swarm
    # worker, cut at six lines only when the rows are short.
    defp card_open(columns, rows) do
      state = Pass73Scenes.screenshot_11(columns, rows)
      id = "demo-approval-80"
      {%{state | layers: [{:approval, id}], focus: "cancel"}, id}
    end

    test "with the draft blank, Enter shows every line the card cut, and folds them back" do
      {state, id} = card_open(120, 24)
      width = Layout.for_state(state).rects.main.width
      hidden = ApprovalCard.hidden_lines(state, width)
      assert hidden > 0

      assert Composer.enter_action(state) == :show_all
      assert Keymap.show_all?(state, id)

      {:ok, action} = Keymap.resolve(Input.key(:enter), state, %{})
      assert action == {:approval_show_all, id}
      {shown, []} = Reducer.update(state, action)

      assert ApprovalCard.expanded?(shown, shown.read_model.interactions[id])
      assert [{:approval, ^id} | _] = shown.layers

      # Expanded, Enter folds it back rather than closing the card, and the
      # status row says so (pass73 G1, QA Q1-05).
      assert Composer.enter_action(shown) == :fold
      assert Status.enter_words(Composer.enter_action(shown)) == "fold"
      {:ok, again} = Keymap.resolve(Input.key(:enter), shown, %{})
      {folded, []} = Reducer.update(shown, again)
      refute ApprovalCard.expanded?(folded, folded.read_model.interactions[id])
      assert ApprovalCard.hidden_lines(folded, width) == hidden
    end

    test "a card that shows its whole command keeps Enter's old meaning" do
      {state, id} = card_open(160, 45)
      item = state.read_model.interactions[id]

      approval = %{
        item.approval
        | command: "mix test",
          arguments_preview: ~s({"command":"mix test"})
      }

      state =
        put_in(state.read_model.interactions[id], %{item | approval: approval})

      width = Layout.for_state(state).rects.main.width
      assert ApprovalCard.hidden_lines(state, width) == 0
      refute Keymap.show_all?(state, id)
      assert Composer.enter_action(state) == :none
      assert {:ok, :close_top_layer} = Keymap.resolve(Input.key(:enter), state, %{})
    end

    test "the status row says what Enter does on the card" do
      {state, _id} = card_open(120, 24)
      assert Status.enter_words(Composer.enter_action(state)) == "show all"
    end
  end

  describe "Ctrl-C after a stop (S's request K5)" do
    test "a run already asked to stop is not stopped again; the next press arms the quit" do
      state = ready([run("swarm", :running, kind: :swarm, actions: [:stop])])

      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      assert [{:run_control, :stop, "swarm"}] = commands(effects)
      assert state.stops_asked == ["swarm"]

      # The read model still draws the swarm live (its terminal update is
      # late, or the daemon answered that it had already finished).
      assert Keymap.live_turn(state, [:running]) == nil

      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      assert commands(effects) == []
      assert state.quit_armed != nil
    end

    test "with two live turns, the second press stops the other one" do
      state =
        ready([
          run("old", :running, started_at: 1),
          run("new", :running, started_at: 2, kind: :swarm)
        ])

      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      assert [{:run_control, :stop, "new"}] = commands(effects)
      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      assert [{:run_control, :stop, "old"}] = commands(effects)
      assert state.quit_armed == nil
    end
  end

  describe "refusals in words (V2's request K-1, S's request K1)" do
    test "a refused stop says the daemon's sentence and keeps it for the toast" do
      state = ready([run("t", :running)])
      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      [request] = requests(effects)

      {state, _} =
        answer(state, request,
          status: :rejected,
          error: AdmissionError.new(:not_allowed),
          reason: %DTO.Refusal{code: "run_finished", text: "That run has already finished."}
        )

      assert state.notice == {:command_feedback, "That run has already finished."}
      assert state.mutation_reasons[request.origin] == "That run has already finished."

      toast = Status.refusal_words(request.origin, state.mutation_reasons[request.origin])
      assert toast == "Not done: That run has already finished."
      refute toast =~ "daemon"
    end

    test "without a sentence the toast reads the admission code, never 'daemon'" do
      state = ready([run("t", :running)])
      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      [request] = requests(effects)

      {state, _} =
        answer(state, request,
          status: :rejected,
          error: AdmissionError.new(:capacity_exceeded)
        )

      assert state.mutation_reasons[request.origin] == :capacity_exceeded
      words = Status.refusal_words(request.origin, :capacity_exceeded)
      assert words =~ "too much is in flight"
      refute words =~ "daemon"
    end

    test "an accepted answer forgets the reason" do
      state = ready([run("t", :running)])
      origin = {:run, "t"}
      state = %{state | mutation_reasons: %{origin => "nope"}}
      {state, effects} = press(state, Input.text_fragment(:press, "c", [:control]))
      [request] = requests(effects)
      assert request.origin == origin
      {state, _} = answer(state, request, status: :accepted, identifiers: ["t"])
      refute Map.has_key?(state.mutation_reasons, origin)
    end
  end

  describe "the live check's findings" do
    # `/com` Enter runs `/compact`, which the daemon queues behind the live
    # chat turn; the hint said "Enter run" while the transcript said queued.
    test "the palette's /compact behind a live chat turn is hinted as a queue" do
      state = ready([run("t", :streaming)]) |> paste("/com")
      assert SwarmCodeCLI.UI.SlashPalette.enter_completion(state) == {:run, "compact"}
      assert Composer.enter_action(state) == :queue

      idle = ready([]) |> paste("/com")
      assert Composer.enter_action(idle) == :run_command
    end

    # The picker's title echoed its query ("Actions: approvals:").
    test "the /approval picker is titled by what it chooses" do
      {state, _} = ready([]) |> paste("/approval") |> send()
      assert [{:switcher, _} | _] = state.layers
      {scene, _} = SwarmCodeCLI.UI.Projector.project(state)
      assert %SwarmCodeCLI.UI.Scene.Dialog{title: title} = scene.overlay
      assert SafeText.value(title) =~ "Approvals · who asks before what runs"
      refute SafeText.value(title) =~ "Actions: approvals:"
    end
  end

  describe "where a send went (S's request K4)" do
    test "a queued send keeps no run to stop; a started one does" do
      state = ready([run("t", :running)])
      {state, effects} = state |> paste("/compact") |> send()
      [request] = requests(effects)

      {state, _} =
        answer(state, request, status: :accepted, identifiers: ["ghost"], disposition: :queued)

      assert state.sent_turn == nil
      assert [%{status: :queued} | _] = state.deliveries

      {state, effects} = state |> paste("/swarm look at the tests") |> send()
      [request] = requests(effects)

      {state, _} =
        answer(state, request, status: :accepted, identifiers: ["swarm-1"], disposition: :started)

      assert state.sent_turn == {"c", "swarm-1"}
    end
  end
end
