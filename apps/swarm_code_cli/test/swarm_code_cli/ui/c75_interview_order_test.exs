defmodule SwarmCodeCLI.UI.C75InterviewOrderTest do
  # pass 75 (task 250): the rows of one ask arrive in hash order, and the note
  # still opens at index 0; every site that counts or walks the needs sees one
  # entry per ask.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Keymap, Paint, Projector}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{Panel, Status}
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph
  alias SwarmCodeCLI.UI.Reducer.Hint

  @node "n9"
  @headers %{0 => "Format", 1 => "Fields", 2 => "Delivery"}

  # One row of the ask of node n9, revision 4, all created at the same time.
  defp row(id, index) do
    %DTO.PendingInteraction{
      id: id,
      kind: :question,
      run_id: "r",
      node_id: @node,
      conversation_id: "c",
      expected_revision: 4,
      created_at: 5,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: "Question #{index}?",
        index: index,
        header: @headers[index],
        total: 3,
        multiple: index == 1,
        options: [
          %DTO.QuestionOption{id: "o1-#{index}", label: "First"},
          %DTO.QuestionOption{id: "o2-#{index}", label: "Second"}
        ]
      }
    }
  end

  defp approval(id, created_at) do
    %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: "r",
      node_id: "op-" <> id,
      conversation_id: "c",
      expected_revision: 5,
      created_at: created_at,
      allowed_actions: [:approve, :deny],
      approval: %DTO.Approval{tool: "run_command", permission: :execute, arguments_preview: "ls"}
    }
  end

  # String order of the ids is index 2, 0, 1.
  defp rows, do: [row("a-q2", 2), row("b-q0", 0), row("c-q1", 1)]

  defp opened(interactions) do
    state =
      ready([run("r", :waiting_question)],
        columns: 176,
        rows: 45,
        snapshot: %{interactions: interactions}
      )

    %{state | interaction_grace: nil}
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

  test "rows in hash order 2, 0, 1 open the ask's one note at index 0" do
    ids = rows() |> Enum.map(& &1.id)
    assert Enum.sort(ids) == ["a-q2", "b-q0", "c-q1"]
    assert Enum.map(rows(), & &1.question.index) == [2, 0, 1]

    state = opened(rows())

    assert state.layers == [{:question, @node}]
    assert Map.get(state.interviews, @node, %{step: 0}).step == 0
    assert state.focus == "dialog"

    stepper = Enum.find(screen(state), &(&1 =~ "1 of 3"))
    assert stepper, "no stepper row"
    assert stepper =~ Glyph.get(:dot_on, state) <> " Format"
    [before_fields | _] = String.split(stepper, "Fields")
    assert before_fields =~ "Format"
  end

  test "every site that counts or walks the needs sees one entry per ask" do
    state = opened(rows())
    run = state.read_model.runs["r"]

    assert Keymap.Special.waiting_ids(state) == [@node]
    assert length(Hint.pending(state, "r", nil)) == 1
    assert length(Panel.Model.pending(state, run)) == 1
    assert Status.waiting_count(state) == 1
  end

  test "an approval created earlier is walked first" do
    state = opened([approval("a0", 1) | rows()])

    assert Keymap.Special.waiting_ids(state) == ["a0", @node]
    assert Status.waiting_count(state) == 2
  end
end
