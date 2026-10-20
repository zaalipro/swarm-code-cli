defmodule SwarmCode.Daemon.Service.R1019WorkflowGateTest do
  @moduledoc """
  Pass 77 C-VER-1: a workflow parked on `await_user` holds its question on the
  workflow row. The TUI used to see only "waiting" with no card to answer: the
  gate is now projected as a one-question interaction (id = the run), and
  `question.answer` (or `workflows resume ID --answer`) resumes the run with the
  answer.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.FeatureRequest
  alias SwarmCode.Domain.{Conversations, Engine, FeatureCatalog, Projects, Workflows}
  alias SwarmCode.Protocol.{ServiceRequest}

  @program """
  meta = %{name: "gate-test", description: "Asks once"}
  answer = await_user("Apply the fixes?", options: ["yes", "no"])
  complete("answered: " <> answer)
  """

  setup_all do
    world = setup_world("wf-gate")
    {:ok, _} = Projects.trust(world.project)
    dir = Path.join([world.root, ".swarm_code", "workflows"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gate-test.exs"), @program)
    world
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    {conv, _, _} = provider!(c, conv, fn _ -> {:text, "unused"} end)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  # A real workflow run, parked on its gate.
  defp parked(c) do
    assert {:ok, wf} =
             FeatureCatalog.start_workflow(%{
               conversation_id: c.conversation.id,
               name: "gate-test"
             })

    assert eventually(fn -> Conversations.get_run(wf.run_id).status == "waiting_user" end)
    wf.run_id
  end

  defp pending(backend, c) do
    {:ok, %{"value" => %{"items" => items}}} = query(backend, scope(c.conversation), "pending")
    items
  end

  test "the gate is a question card with the workflow's options, answered from the TUI", c do
    run_id = parked(c)
    backend = start_backend(c, c.conversation)

    assert [gate] = pending(backend, c)
    assert gate["kind"] == "question"
    assert gate["run_id"] == run_id
    assert gate["node_id"] == run_id
    assert gate["question"]["prompt"] == "Apply the fixes?"
    assert Enum.map(gate["question"]["options"], & &1["label"]) == ["yes", "no"]
    assert gate["allowed_actions"] == ["answer_question"]

    workspace = workspace(backend, scope(c.conversation))
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot.decode(workspace)
    run = Enum.find(workspace["runs"], &(&1["id"] == run_id))
    assert run["state"] == "waiting_question"

    yes = Enum.find(gate["question"]["options"], &(&1["label"] == "yes"))

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [^run_id]}}} =
             command(backend, "answer", scope(c.conversation), :question_answer, %{
               "run_id" => run_id,
               "node_id" => gate["node_id"],
               "interaction_id" => gate["id"],
               "expected_revision" => gate["expected_revision"],
               "answers" => [yes["id"]],
               "custom_text" => ""
             })

    assert eventually(fn -> Conversations.get_run(run_id).status == "done" end)
    assert Workflows.get_run(run_id).result =~ "answered: yes"
    assert pending(backend, c) == []
  end

  test "a typed answer wins over the options", c do
    run_id = parked(c)
    backend = start_backend(c, c.conversation)
    assert [gate] = pending(backend, c)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(backend, "typed", scope(c.conversation), :question_answer, %{
               "run_id" => run_id,
               "node_id" => gate["node_id"],
               "interaction_id" => gate["id"],
               "expected_revision" => gate["expected_revision"],
               "answers" => [],
               "custom_text" => "only the safe ones"
             })

    assert eventually(fn -> Conversations.get_run(run_id).status == "done" end)
    assert Workflows.get_run(run_id).result =~ "answered: only the safe ones"
  end

  test "a stale revision is refused and the run stays parked", c do
    run_id = parked(c)
    backend = start_backend(c, c.conversation)
    assert [gate] = pending(backend, c)

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(backend, "stale", scope(c.conversation), :question_answer, %{
               "run_id" => run_id,
               "node_id" => gate["node_id"],
               "interaction_id" => gate["id"],
               "expected_revision" => gate["expected_revision"] + 1,
               "answers" => [],
               "custom_text" => "late"
             })

    assert Conversations.get_run(run_id).status == "waiting_user"
  end

  test "`workflows resume ID` with an answer resumes the parked run", c do
    run_id = parked(c)

    request = %ServiceRequest{
      operation: :feature_command,
      timeout_ms: 5_000,
      params: %{
        "feature" => "workflows",
        "action" => "resume",
        "id" => run_id,
        "attributes" => %{"answer" => "yes"}
      }
    }

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             FeatureRequest.execute(request, scope(c.conversation), "resume-answer", 0)

    assert eventually(fn -> Conversations.get_run(run_id).status == "done" end)
    assert Workflows.get_run(run_id).result =~ "answered: yes"
  end

  test "an answer that is not a short string is refused before any run is touched", c do
    run_id = parked(c)

    for attrs <- [%{"answer" => 5}, %{"answer" => String.duplicate("a", 4_001)}, %{"x" => "y"}] do
      request = %ServiceRequest{
        operation: :feature_command,
        timeout_ms: 5_000,
        params: %{
          "feature" => "workflows",
          "action" => "resume",
          "id" => run_id,
          "attributes" => attrs
        }
      }

      assert {:ok, %{"value" => %{"status" => "rejected"}}} =
               FeatureRequest.execute(request, scope(c.conversation), "bad-answer", 0)
    end

    assert Conversations.get_run(run_id).status == "waiting_user"
  end
end
