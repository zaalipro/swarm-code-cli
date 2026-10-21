defmodule SwarmCodeCLI.Plain.OneShotReasonTest do
  @moduledoc """
  pass76 cli-reason-codes: the `--json` summary and the stream-json summary
  record carry a stable `reason` word for every way a one-shot ends other than
  `done` (null for a clean end). Exit codes and the stderr sentences are the
  ones the other one-shot tests pin.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Release.{Reasons, Signals}
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  @workflow "77777777-7777-4777-8777-777777777777"
  @interaction "66666666-6666-4666-8666-666666666666"

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  defp summary(context) do
    summary = context.output |> text() |> String.split("\n", trim: true) |> List.last()
    object = Jason.decode!(summary)
    # Every word a summary carries is one the README lists.
    assert object["reason"] in [nil | Reasons.all()]
    object
  end

  defp stop_request do
    assert_receive {:source, {:request, :command, %Request{kind: kind}}}, 5_000
    kind
  end

  # A chat run that went `running` and then ended in `state`.
  defp ended(context, format, state, extra \\ []) do
    session = start(context, format: format) |> accept() |> run_update(:running)
    session = run_update(session, state, extra)
    complete(session, [run(state, extra)], [])
    session
  end

  defp approval(command) do
    %DTO.PendingInteraction{
      id: @interaction,
      run_id: H.run_id(),
      node_id: H.root(),
      conversation_id: H.conversation(),
      kind: :approval,
      expected_revision: 1,
      allowed_actions: [:approve, :deny],
      approval: %DTO.Approval{tool: "run_command", command: command, arguments_preview: "{}"}
    }
  end

  describe "a run that ends" do
    test "done has a null reason in json", context do
      session = ended(context, :json, :done)

      assert code(session) == 0
      assert %{"reason" => nil, "exit_code" => 0, "state" => "done"} = summary(context)
    end

    test "done has a null reason in the stream-json summary", context do
      session = ended(context, :stream_json, :done)

      assert code(session) == 0
      assert %{"type" => "summary", "reason" => nil, "exit_code" => 0} = summary(context)
    end

    test "failed is run_failed, in the stream-json summary too", context do
      session = ended(context, :stream_json, :failed, error: "provider said no")

      assert code(session) == 1
      assert %{"type" => "summary", "reason" => "run_failed", "exit_code" => 1} = summary(context)
    end

    test "failed keeps its sentence and exit code", context do
      session = ended(context, :json, :failed, error: "provider said no")

      assert code(session) == 1

      assert %{
               "reason" => "run_failed",
               "state" => "failed",
               "error" => "the run failed: provider said no",
               "exit_code" => 1
             } = summary(context)

      assert text(context.error) =~ "ncode: the run failed: provider said no"
    end

    test "stopped from outside is run_stopped", context do
      session = ended(context, :json, :stopped)

      assert code(session) == 1
      assert %{"reason" => "run_stopped", "state" => "stopped"} = summary(context)
    end

    test "interrupted is run_interrupted", context do
      session = ended(context, :json, :interrupted)

      assert code(session) == 1
      assert %{"reason" => "run_interrupted", "state" => "interrupted"} = summary(context)
    end

    test "paused (not a workflow) is run_paused", context do
      session = ended(context, :json, :paused)

      assert code(session) == 1
      assert %{"reason" => "run_paused", "state" => "paused"} = summary(context)
    end

    test "a paused workflow it launched is paused_workflow", context do
      flow = %DTO.RunSummary{
        id: @workflow,
        conversation_id: H.conversation(),
        kind: :workflow,
        state: :paused,
        title: "review flow",
        parent_run_id: H.run_id(),
        created_sequence: 2,
        error: "The model provider has been unreachable.",
        allowed_actions: [:stop]
      }

      session = start(context, format: :json) |> accept() |> run_update(:done)
      complete(session, [run(:done), flow], [])

      assert code(session) == 1
      assert %{"reason" => "paused_workflow", "state" => "paused"} = summary(context)
    end
  end

  describe "a run this process stops" do
    test "--max-turns says max_turns", context do
      session =
        start(context, format: :json, max_turns: 1)
        |> accept()
        |> run_update(:running)
        |> agent_update(2)

      assert {:run_control, :stop, _} = stop_request()
      session = run_update(session, :stopped)
      complete(session, [run(:stopped)], [])

      assert code(session) == 1

      assert %{"reason" => "max_turns", "state" => "stopped", "exit_code" => 1} =
               summary(context)

      assert text(context.error) =~ "ncode: stopped after 1 turns."
    end

    test "--max-budget-usd says max_budget", context do
      session =
        start(context, format: :json, max_budget_usd: 0.01)
        |> accept()
        |> run_update(:running, cost_usd: 0.02)

      assert {:run_control, :stop, _} = stop_request()
      session = run_update(session, :stopped, cost_usd: 0.02)
      complete(session, [run(:stopped, cost_usd: 0.02)], [])

      assert code(session) == 1
      assert %{"reason" => "max_budget", "state" => "stopped"} = summary(context)
    end

    test "a question is question_asked, with the question in the object", context do
      question = %DTO.PendingInteraction{
        id: @interaction,
        run_id: H.run_id(),
        node_id: H.root(),
        conversation_id: H.conversation(),
        kind: :question,
        expected_revision: 1,
        allowed_actions: [:answer_question],
        question: %DTO.Question{
          prompt: "Which folder?",
          options: [%DTO.QuestionOption{id: "notes", label: "notes/"}]
        }
      }

      session =
        start(context, format: :json)
        |> accept()
        |> run_update(:waiting_question)
        |> interaction(question)

      assert {:run_control, :stop, _} = stop_request()
      session = run_update(session, :stopped)
      complete(session, [run(:stopped)], [])

      assert code(session) == 1

      assert %{"reason" => "question_asked", "question" => "Which folder?", "state" => "stopped"} =
               summary(context)
    end

    # pass 77 C-VER-1: a workflow parked on `await_user` shows as a pending
    # question of its run; with nobody to answer, `-p` stops it and says why
    # rather than waiting for ever.
    test "a workflow's await_user gate is question_asked", context do
      gate = %DTO.PendingInteraction{
        id: @interaction,
        run_id: H.run_id(),
        node_id: H.run_id(),
        conversation_id: H.conversation(),
        kind: :question,
        expected_revision: 1,
        allowed_actions: [:answer_question],
        question: %DTO.Question{
          prompt: "Apply the fixes?",
          options: [
            %DTO.QuestionOption{id: "yes", label: "yes"},
            %DTO.QuestionOption{id: "no", label: "no"}
          ]
        }
      }

      session =
        start(context, format: :json)
        |> accept()
        |> run_update(:waiting_question, kind: :workflow)
        |> interaction(gate)

      assert {:run_control, :stop, _} = stop_request()
      session = run_update(session, :stopped, kind: :workflow)
      complete(session, [run(:stopped, kind: :workflow)], [])

      assert code(session) == 1

      assert %{"reason" => "question_asked", "question" => "Apply the fixes?"} =
               summary(context)
    end

    test "an approval the service will not deny is approval_required", context do
      session =
        start(context, format: :json)
        |> accept()
        |> run_update(:waiting_approval)
        |> interaction(approval("ls"))

      assert_receive {:source,
                      {:request, :command,
                       %Request{kind: {:resolve_approval, _, _, _, _, :deny}} = deny}},
                     5_000

      respond(session, deny, %DTO.Outcome{
        status: :rejected,
        error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
      })

      assert {:run_control, :stop, _} = stop_request()
      session = run_update(session, :stopped)
      complete(session, [run(:stopped)], [])

      assert code(session) == 1
      assert %{"reason" => "approval_required", "state" => "stopped"} = summary(context)
    end
  end

  describe "denials" do
    test "--fail-on-denied on a done run with denials is denied", context do
      session =
        start(context, [format: :json, fail_on_denied: true], approval_mode: :read_only)
        |> accept()
        |> run_update(:waiting_approval)
        |> interaction(approval("make"))

      assert_receive {:source, {:request, :command, %Request{} = deny}}, 5_000
      respond(session, deny, %DTO.Outcome{status: :accepted})
      session = run_update(session, :done)
      complete(session, [run(:done)], [])

      assert code(session) == 1
      assert %{"reason" => "denied", "state" => "done", "exit_code" => 1} = summary(context)
    end

    test "without the flag a denial still exits 0 with a null reason", context do
      session =
        start(context, [format: :json], approval_mode: :read_only)
        |> accept()
        |> run_update(:waiting_approval)
        |> interaction(approval("make"))

      assert_receive {:source, {:request, :command, %Request{} = deny}}, 5_000
      respond(session, deny, %DTO.Outcome{status: :accepted})
      session = run_update(session, :done)
      complete(session, [run(:done)], [])

      assert code(session) == 0
      assert %{"reason" => nil, "exit_code" => 0} = summary(context)
    end
  end

  describe "a session that never gets to a run" do
    test "a prompt the service refuses is prompt_not_sent", context do
      session = start(context, format: :json)

      respond(session, session.dispatch, %DTO.Outcome{
        status: :rejected,
        error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
      })

      assert code(session) == 1

      assert %{
               "reason" => "prompt_not_sent",
               "state" => "not_started",
               "error" => "the prompt was not sent: request is not allowed."
             } = summary(context)
    end

    test "a session that closes under the run is session_closed", context do
      session = start(context, format: :json) |> accept() |> run_update(:running)
      send(session.owner, {:swarm_code_ui_closed, context.source, H.epoch()})

      assert code(session) == 1

      assert %{
               "reason" => "session_closed",
               "error" => "the session closed before the run finished."
             } = summary(context)
    end

    test "SIGTERM is sigterm and keeps exit 143", context do
      session = start(context, format: :json) |> accept() |> run_update(:running)
      Signals.notify(session.task.pid, :sigterm)

      assert {:run_control, :stop, _} = stop_request()
      assert code(session) == 143
      assert %{"reason" => "sigterm", "exit_code" => 143} = summary(context)
    end

    test "SIGHUP is sighup and keeps exit 129", context do
      session = start(context, format: :json) |> accept() |> run_update(:running)
      Signals.notify(session.task.pid, :sighup)

      assert {:run_control, :stop, _} = stop_request()
      assert code(session) == 129
      assert %{"reason" => "sighup", "exit_code" => 129} = summary(context)
    end
  end
end
