defmodule SwarmCodeCLI.UI.DataSource.C75FakeInterviewTest do
  @moduledoc """
  pass75 interview (task 208): the fake source speaks the daemon's question
  shapes. The `interview-3` barrier asks three questions at once (one node,
  one revision, indexes 0-2, headers, the asked total, each option's own
  description), the run's needs-you entry is one per ask, and the note's
  `%{option_ids:, custom_text:}` answer removes only the row it answers.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}
  alias SwarmCodeCLI.UI.DataSource.DTO.Outcome

  defp fixture,
    do: File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))

  defp source do
    {:ok, script} = Script.decode(fixture())
    start_supervised!({Source, script: script, source_epoch: "epoch-1"})
  end

  test "interview-3 asks three questions as one ask" do
    pid = source()
    assert :ok = Source.advance(pid, "interview-3")
    script = Source.snapshot(pid)
    assert {:ok, ^script} = Script.validate(script)

    rows =
      script.interactions
      |> Map.values()
      |> Enum.filter(&(&1.kind == :question and &1.state == :pending))
      |> Enum.sort_by(& &1.question.index)

    assert [q1, q2, q3] = rows
    assert Enum.map(rows, & &1.id) == [Script.id(:q1), Script.id(:q2), Script.id(:q3)]
    assert rows |> Enum.map(& &1.node_id) |> Enum.uniq() == [Script.id(:node_a2)]
    assert rows |> Enum.map(& &1.expected_revision) |> Enum.uniq() == [7]
    assert Enum.map(rows, & &1.question.index) == [0, 1, 2]
    assert Enum.map(rows, & &1.question.header) == ["Format", "Fields", "Delivery"]
    assert Enum.map(rows, & &1.question.total) == [3, 3, 3]
    assert Enum.map(rows, & &1.question.multiple) == [false, true, false]
    assert Enum.all?(rows, &(&1.question.requested_at == Script.clock_ms() - 70_000))
    assert Enum.all?(rows, &(&1.deadline == Script.clock_ms() + 1_730_000))

    assert %DTO.QuestionOption{
             id: "csv",
             label: "CSV",
             description: "One row per ticket; opens in Excel and Sheets."
           } = hd(q1.question.options)

    assert Enum.map(q2.question.options, & &1.label) == [
             "Status and priority",
             "Assignee",
             "Customer email",
             "Comments"
           ]

    assert Enum.all?(q3.question.options, &(&1.description == ""))

    a2 = script.runs[Script.id(:a2)]
    assert a2.state == :waiting_question

    assert [%DTO.NeedsYou{kind: :question} = need] =
             Enum.filter(a2.needs_you, &(&1.kind == :question))

    assert need.questions == ["Format", "Fields", "Delivery"]
    assert need.options == 4
    assert need.requested_at == Script.clock_ms() - 70_000
  end

  test "the note's answer payload is accepted and removes only its row" do
    pid = source()
    assert :ok = Source.advance(pid, "interview-3")
    Source.attach(pid, "client", self())
    q = Source.snapshot(pid).interactions[Script.id(:q1)]

    request = %Request{
      request_id: "request-1",
      kind:
        {:answer_question, q.run_id, q.node_id, q.id, q.expected_revision,
         %{option_ids: ["csv"], custom_text: ""}},
      origin: {:interaction, q.id, q.expected_revision},
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      deadline: Script.clock_ms() + 1000,
      expected_response: :outcome
    }

    assert :ok = Source.request(pid, "client", request)

    assert_receive {:fake_source, "client",
                    %Delivery{kind: :response, body: %Outcome{status: :accepted}}}

    assert_receive {:fake_source, "client", deltas} when is_list(deltas)

    removed = for d <- deltas, d.kind == :interaction_remove, do: d.entity_id
    assert removed == [Script.id(:q1)]

    interactions = Source.snapshot(pid).interactions
    assert interactions[Script.id(:q1)].state == :resolved
    assert interactions[Script.id(:q2)].state == :pending
    assert interactions[Script.id(:q3)].state == :pending
  end
end
