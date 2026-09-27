defmodule SwarmCodeCLI.UI.C75InterviewSettleTest do
  # pass 75 (task 252): the note's send path and everything after it: N
  # intents in one transition, sending, a refusal, the vanish notices, prune.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Projector, Question, Reducer, SafeText, State}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Delivery, Delta}
  alias SwarmCodeCLI.UI.Projector.RunRow
  alias SwarmCodeCLI.UI.Scene.Block

  @node "n9"
  @lead "lead-1"
  @now 1_000_000_000

  defp row(id, index, opts) do
    {header, multiple} =
      case index do
        0 -> {"Format", false}
        1 -> {"Fields", true}
        2 -> {"Delivery", false}
      end

    %DTO.PendingInteraction{
      id: id,
      kind: :question,
      run_id: "r",
      node_id: Keyword.get(opts, :node, @node),
      conversation_id: "c",
      expected_revision: 4,
      created_at: Keyword.get(opts, :created_at, 5),
      deadline: Keyword.get(opts, :deadline, 0),
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: header <> "?",
        index: index,
        header: header,
        total: Keyword.get(opts, :total, 3),
        multiple: multiple,
        agent_id: @lead,
        options: [
          %DTO.QuestionOption{id: "o1-#{index}", label: "First"},
          %DTO.QuestionOption{id: "o2-#{index}", label: "Second"}
        ]
      }
    }
  end

  defp rows(opts \\ []),
    do: [row("a-q2", 2, opts), row("b-q0", 0, opts), row("c-q1", 1, opts)]

  defp opened(interactions) do
    state =
      ready([run("r", :waiting_question, kind: :swarm, title: "add ticket export")],
        columns: 176,
        rows: 45,
        snapshot: %{interactions: interactions}
      )

    lead = %DTO.AgentSummary{id: @lead, run_id: "r", name: "Lead", role: :lead}
    state = put_in(state.read_model.agents[@lead], lead)
    %{state | interaction_grace: nil, now: @now}
  end

  defp update!(state, action), do: elem(Reducer.update(state, action), 0)

  # Every question answered: q0 picks o1, q1 ticks o2, q2 is left on its
  # last step with o2 picked.
  defp answered(state) do
    state
    |> update!({:interview, {:pick, @node, "o1-0"}})
    |> update!({:interview, {:confirm, @node}})
    |> update!({:interview, {:toggle, @node, "o2-1"}})
    |> update!({:interview, {:confirm, @node}})
    |> update!({:interview, {:pick, @node, "o2-2"}})
  end

  # The daemon removes a row: the delta the Fake sends for it.
  defp remove(state, id) do
    watch = state.watches.workspace
    sequence = watch.sequence + 1

    {state, _} =
      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :delta,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: sequence,
           sequence: sequence,
           body: %Delta{
             kind: :interaction_remove,
             entity_id: id,
             run_id: "r",
             conversation_id: "c",
             revision: sequence,
             sequence: sequence
           }
         }}
      )

    state
  end

  defp note_spans(state) do
    {scene, _} = Projector.project(state)

    for %Block.RichText{spans: spans} <- scene.overlay.blocks,
        span <- spans,
        do: {SafeText.value(span.text), span.style}
  end

  test "the last Enter sends every answer in one transition, in index order" do
    state = opened(rows()) |> answered()
    assert Question.interview(state, @node).step == 2

    {sent, effects} = Reducer.update(state, {:interview, {:confirm, @node}})
    requests = requests(effects)
    assert length(effects) == 3
    assert length(requests) == 3

    assert Enum.map(requests, & &1.kind) == [
             {:answer_question, "r", @node, "b-q0", 4, %{option_ids: ["o1-0"], custom_text: ""}},
             {:answer_question, "r", @node, "c-q1", 4, %{option_ids: ["o2-1"], custom_text: ""}},
             {:answer_question, "r", @node, "a-q2", 4, %{option_ids: ["o2-2"], custom_text: ""}}
           ]

    assert length(Question.interview(sent, @node).sending) == 3
    assert {_, []} = Reducer.update(sent, {:interview, {:confirm, @node}})
  end

  test "Enter on the last question with one unanswered goes to it and sends nothing" do
    state =
      opened(rows())
      |> update!({:interview, {:pick, @node, "o1-0"}})
      |> update!({:interview, {:confirm, @node}})
      |> update!({:interview, {:step, @node, 1}})

    assert Question.interview(state, @node).step == 2

    {state, effects} = Reducer.update(state, {:interview, {:confirm, @node}})
    assert effects == []
    assert Question.interview(state, @node).step == 1
  end

  test "two accepted and one refused: the note stays on the refused row with why" do
    state = opened(rows()) |> answered()
    {state, effects} = Reducer.update(state, {:interview, {:confirm, @node}})
    [q0, q1, q2] = requests(effects)

    {state, _} = outcome(state, q0, :accepted, ["b-q0", "r"])
    state = remove(state, "b-q0")
    {state, _} = outcome(state, q2, :accepted, ["a-q2", "r"])
    state = remove(state, "a-q2")

    {state, _} =
      outcome(state, q1, :rejected, [], error: AdmissionError.new(:stale_revision))

    assert [{:question, @node} | _] = state.layers
    assert Question.interview(state, @node).sending == []

    # In colour the refusal row is the `warning` role.
    colour = %{state | capabilities: %{state.capabilities | color_mode: :truecolor}}
    warning = RunRow.tinted(:warning, colour).foreground
    assert warning != nil

    assert Enum.any?(note_spans(colour), fn {text, style} ->
             String.starts_with?(text, "Fields: ") and style.foreground == warning
           end)

    # The removed rows took their headers with them: indexes 0 and 2.
    ledger = Question.ledger(state, Question.ask(state, @node))
    assert {:earlier, _, "answered earlier"} = Enum.at(ledger, 0)
    assert {_, "Fields", _} = Enum.at(ledger, 1)
    assert {:earlier, _, "answered earlier"} = Enum.at(ledger, 2)
  end

  test "an ask that leaves unanswered says why; one answered says nothing" do
    past = opened(rows(deadline: @now - 1))
    past = Enum.reduce(["a-q2", "b-q0", "c-q1"], past, &remove(&2, &1))
    assert past.layers == []

    assert State.shown_notice(past) ==
             {:command_feedback, "The Lead stopped waiting: no answer after 30 min"}

    gone = opened(rows())
    gone = Enum.reduce(["a-q2", "b-q0", "c-q1"], gone, &remove(&2, &1))
    assert gone.layers == []

    assert State.shown_notice(gone) ==
             {:command_feedback, "The Lead is no longer waiting for your answers"}

    state = opened(rows()) |> answered()
    notice = state.notice
    {sent, _} = Reducer.update(state, {:interview, {:confirm, @node}})
    sent = Enum.reduce(["a-q2", "b-q0", "c-q1"], sent, &remove(&2, &1))
    assert sent.layers == []
    assert sent.notice == notice
  end

  test "held answers are pruned when the ask leaves, and at most 8 are held" do
    state =
      opened(rows())
      |> update!({:interview, {:confirm, @node}})
      |> update!({:interview, {:pick, @node, "o1-0"}})
      |> update!({:interview, {:confirm, @node}})
      |> update!({:interview, {:toggle, @node, "o1-1"}})
      |> update!({:interview, {:toggle_other, @node}})
      |> type("also")

    assert Map.has_key?(state.interviews, @node)
    assert Map.has_key?(state.selection, {:question, "c-q1"})
    assert Map.has_key?(state.field_editors.entries, {:question_other, "c-q1", 4})

    assert FieldEditors.fetch(state.field_editors, {:question_other, "c-q1", 4}) |> Editor.text() ==
             "also"

    state = Enum.reduce(["a-q2", "b-q0", "c-q1"], state, &remove(&2, &1))
    refute Map.has_key?(state.interviews, @node)
    refute Map.has_key?(state.selection, {:question, "c-q1"})
    refute Map.has_key?(state.field_editors.entries, {:question_other, "c-q1", 4})

    nodes = for n <- 1..9, do: "node-#{n}"

    asks =
      for {node, n} <- Enum.with_index(nodes, 1),
          do: row("row-#{n}", 0, node: node, total: 1, created_at: n)

    held =
      Enum.reduce(nodes, opened(asks), fn node, acc ->
        update!(acc, {:interview, {:pick, node, "o1-0"}})
      end)

    # Nine held: the oldest ask's answers went.
    assert map_size(held.interviews) == 8
    refute Map.has_key?(held.interviews, "node-1")
    held = remove(held, "nobody")
    assert map_size(held.interviews) == 8
  end
end
