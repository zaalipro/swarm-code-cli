defmodule SwarmCodeCLI.Plain.OneShotDeniedTest do
  @moduledoc """
  cli020 B3 (onboarding-5, decision 3): `-p` denies every approval nobody can
  give and counts what the policy or a hook blocked; one stderr line at the
  end names them and says how to allow them, and `--fail-on-denied` turns a
  done run with denials into exit 1.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  defp approval(id, revision, command) do
    %DTO.PendingInteraction{
      id: id,
      run_id: H.run_id(),
      node_id: H.root(),
      conversation_id: H.conversation(),
      kind: :approval,
      expected_revision: revision,
      allowed_actions: [:approve, :deny],
      approval: %DTO.Approval{tool: "run_command", command: command, arguments_preview: "{}"}
    }
  end

  defp deny_both(session) do
    session =
      session
      |> accept()
      |> run_update(:waiting_approval)
      |> interaction(approval("66666666-6666-4666-8666-666666666661", 1, "rm -rf build"))

    assert_receive {:source, {:request, :command, %Request{} = first}}, 5_000
    assert elem(first.kind, 5) == :deny
    respond(session, first, %DTO.Outcome{status: :accepted})

    session = interaction(session, approval("66666666-6666-4666-8666-666666666662", 1, "make"))
    assert_receive {:source, {:request, :command, %Request{} = second}}, 5_000
    assert elem(second.kind, 5) == :deny
    respond(session, second, %DTO.Outcome{status: :accepted})

    session = run_update(session, :done)
    complete(session, [run(:done)], [])
    session
  end

  test "two denied approvals: one stderr line naming both, exit 0", context do
    session =
      start(context, [format: :json, project_root: "/tmp/my proj"], approval_mode: :read_only)

    session = deny_both(session)

    assert code(session) == 0
    error = text(context.error)
    assert [line] = String.split(error, "\n", trim: true)

    assert line ==
             "ncode: 2 tool call(s) were denied (approval mode read_only): " <>
               "run_command rm -rf build, run_command make. Allow them with: " <>
               "ncode config set project.approval_mode auto --project '/tmp/my proj', " <>
               "or answer them in ncode."

    json = Jason.decode!(text(context.output))
    assert json["exit_code"] == 0
    assert length(json["denied"]) == 2
  end

  test "--fail-on-denied makes a done run with denials exit 1", context do
    session = start(context, [format: :json, fail_on_denied: true], approval_mode: :auto)
    session = deny_both(session)

    assert code(session) == 1
    assert Jason.decode!(text(context.output))["exit_code"] == 1
    assert text(context.error) =~ "(approval mode auto)"
    assert text(context.error) =~ "/approval full runs every command without asking."
  end

  test "a tool blocked by the policy counts as denied", context do
    tool = %DTO.TranscriptItem{
      id: "77777777-7777-4777-8777-777777777777",
      run_id: H.run_id(),
      conversation_id: H.conversation(),
      node_id: "77777777-7777-4777-8777-777777777777",
      role: :tool,
      kind: :tool,
      state: :failed,
      text: "blocked by Read-only approval mode",
      attempt_id: "attempt-1",
      tool: %DTO.ToolCall{name: "write_file", title: "notes/a.md", status: :failed}
    }

    session =
      start(context, [fail_on_denied: true], approval_mode: :read_only)
      |> accept()
      |> upsert(tool)
      |> run_update(:done)

    complete(session, [run(:done)], [tool])

    assert code(session) == 1

    assert text(context.error) =~
             "ncode: 1 tool call(s) were denied (approval mode read_only): write_file notes/a.md."
  end

  test "more than five denials name five and count the rest" do
    labels = for n <- 1..7, do: "tool#{n}"

    assert SwarmCodeCLI.Plain.OneShot.denied_line(labels, :auto, "/p") ==
             "7 tool call(s) were denied (approval mode auto): tool1, tool2, tool3, tool4, tool5 and 2 more." <>
               " /approval full runs every command without asking."
  end
end
