defmodule SwarmCodeCLI.UI.DataSource.Pass70FakeTest do
  @moduledoc """
  pass70 C1: every wire addition exists in the fake data source — the
  conversation list/new/open, project approval mode and trust, the widened
  approval decisions, diffs on demand, background commands, rate limits and
  toasts.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Session, Source}

  defp fixture,
    do: File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))

  defp source do
    {:ok, script} = Script.decode(fixture())
    pid = start_supervised!({Source, script: script, source_epoch: "epoch-1"})
    :ok = Source.attach(pid, "client", self())
    pid
  end

  defp conversation(key), do: %Scope{kind: :conversation, id: Script.id(key), generation: 0}
  defp global, do: %Scope{kind: :global, id: nil, generation: 0}

  defp watch(slot, scope, ref \\ "watch-1"),
    do: %Watch{
      watch_ref: ref,
      slot: slot,
      scope: scope,
      generation: 0,
      page_size: 200,
      byte_limit: 1_048_576
    }

  defp request(id, kind, origin, expected, scope \\ conversation(:a)),
    do: %Request{
      request_id: id,
      kind: kind,
      scope: scope,
      generation: 0,
      origin: origin,
      deadline: Script.clock_ms() + 60_000,
      expected_response: expected
    }

  defp reply(pid, request) do
    assert :ok = Source.request(pid, "client", request)
    assert_receive {:fake_source, "client", %Delivery{kind: :response, body: body} = delivery}
    assert {:ok, ^delivery} = Delivery.validate(delivery)
    body
  end

  defp list(pid, id),
    do:
      reply(
        pid,
        request(
          id,
          {:conversation_list, nil, 50, 262_144},
          {:conversation, :list},
          :conversation_list,
          global()
        )
      )

  test "the conversation list is newest first and marks the open conversation" do
    pid = source()

    assert %DTO.ConversationList{items: [a, b], current_id: current} = list(pid, "list-1")
    assert current == Script.id(:a)

    assert {a.id, a.title, a.current, a.run_count} ==
             {Script.id(:a), "Authentication review", true, 2}

    assert {b.id, b.current, b.run_count} == {Script.id(:b), false, 1}
    assert a.updated_at > b.updated_at
  end

  test "a new conversation is created, opened and listed; opening another switches back" do
    pid = source()

    assert %DTO.Outcome{status: :accepted, identifiers: [new_id]} =
             reply(
               pid,
               request("new-1", {:conversation_new}, {:conversation, :new}, :outcome, global())
             )

    assert %DTO.ConversationList{current_id: ^new_id, items: items} = list(pid, "list-2")
    assert [%{id: ^new_id, title: "New conversation", run_count: 0, current: true} | _] = items

    # The new conversation takes a prompt like any other.
    assert %DTO.Outcome{status: :accepted} =
             reply(
               pid,
               request(
                 "send-1",
                 {:dispatch, :send, "hello", :main, []},
                 {:draft, {new_id, :main}},
                 :outcome,
                 %Scope{kind: :conversation, id: new_id, generation: 0}
               )
             )

    assert %DTO.Outcome{status: :accepted, identifiers: [a]} =
             reply(
               pid,
               request(
                 "open-1",
                 {:conversation_open, Script.id(:a)},
                 {:conversation, :open},
                 :outcome,
                 global()
               )
             )

    assert a == Script.id(:a)
    assert %DTO.ConversationList{current_id: ^a} = list(pid, "list-3")

    # The source refuses directly; the client adapter turns it into a delivery.
    assert {:error, %AdmissionError{code: :invalid_origin}} =
             Source.request(
               pid,
               "client",
               request(
                 "open-2",
                 {:conversation_open, "00000000-0000-4000-8000-0000000000ff"},
                 {:conversation, :open},
                 :outcome,
                 global()
               )
             )
  end

  test "workspace and shell snapshots carry mode, trust, gauges, background and rate limits" do
    pid = source()
    assert :ok = Source.watch(pid, "client", watch(:workspace, conversation(:a)))
    assert_receive {:fake_source, "client", %Delivery{kind: :watch_ready, body: page}}

    assert {page.approval_mode, page.trusted, page.title} ==
             {:auto, true, "Authentication review"}

    assert {page.context_used, page.context_window} == {18_640, 131_072}
    assert is_float(page.cost_usd)
    assert [%DTO.BackgroundCommand{state: :running, run_id: run}] = page.background
    assert run == Script.id(:a2)

    [a1_change | _] = Enum.filter(page.changes, &(&1.path == "lib/swarm_code/repo.ex"))
    assert {a1_change.added, a1_change.removed, a1_change.file_state} == {42, 7, :modified}

    assert :ok = Source.watch(pid, "client", watch(:shell, global(), "watch-2"))
    assert_receive {:fake_source, "client", %Delivery{kind: :watch_ready, body: shell}}
    assert [%DTO.RateLimit{provider: "llmotions", used_percent: 62.0}] = shell.rate_limits
  end

  test "an edit's and a change's diff load through detail" do
    pid = source()
    ref = Session.diff_ref("00000000-0000-4000-8000-00000000a2e3")

    body =
      reply(
        pid,
        request(
          "diff-1",
          {:query_detail, ref.id, 0, 65_536},
          {:query, :detail},
          :detail_window
        )
      )

    assert %DTO.DetailWindow{state: :idle, next_offset: nil, detail_ref: ^ref, text: text} = body
    assert text =~ "+++ b/lib/swarm_code/repo.ex"
    assert byte_size(text) == ref.total_bytes

    page =
      reply(
        pid,
        request(
          "diff-2",
          {:query_detail, Script.id(:change_2) <> ":diff", 10, 64},
          {:query, :detail},
          :detail_window
        )
      )

    assert %DTO.DetailWindow{offset: 10, next_offset: 74} = page

    assert {:error, %AdmissionError{code: :invalid_origin}} =
             Source.request(
               pid,
               "client",
               request(
                 "diff-3",
                 {:query_detail, Script.id(:change_1) <> ":diff", 0, 64},
                 {:query, :detail},
                 :detail_window,
                 conversation(:b)
               )
             )
  end

  test "project approval mode and trust change the workspace metadata and raise a toast" do
    pid = source()
    assert :ok = Source.watch(pid, "client", watch(:shell, global()))
    assert_receive {:fake_source, "client", %Delivery{kind: :watch_ready}}

    assert %DTO.Outcome{status: :accepted} =
             reply(
               pid,
               request(
                 "mode-1",
                 {:project_update, :full_access, nil},
                 {:project, :update},
                 :outcome
               )
             )

    assert_receive {:fake_source, "client", deltas} when is_list(deltas)

    assert [%Delta{body: %DTO.WorkspaceMetadata{approval_mode: :full_access}} | _] =
             for(%Delta{kind: :workspace_metadata} = d <- deltas, do: d)

    assert [%Delta{body: %DTO.Toast{level: :success, text: "Approval mode: full access"}}] =
             for(%Delta{kind: :toast} = d <- deltas, do: d)
  end

  test "approvals offer and accept the widened decisions" do
    pid = source()
    assert :ok = Source.advance(pid, "catalogue-activity")
    assert_receive {:fake_source, "client", _deltas}

    script = Source.snapshot(pid)
    approval = script.interactions[Script.id(:approval)]
    assert %DTO.Approval{command_family: "mix test", classification: :normal} = approval.approval
    assert :always_prefix in approval.approval.allowed_decisions

    resolve = fn id, decision ->
      Source.request(
        pid,
        "client",
        request(
          id,
          {:resolve_approval, approval.run_id, approval.node_id, approval.id,
           approval.expected_revision, decision},
          {:interaction, approval.id, approval.expected_revision},
          :outcome
        )
      )
    end

    assert :ok = resolve.("always-1", :always_prefix)
    assert_receive {:fake_source, "client", %Delivery{body: %DTO.Outcome{status: :accepted}}}
    assert_receive {:fake_source, "client", deltas} when is_list(deltas)

    assert [%Delta{body: %DTO.Toast{title: "Always allowed"}}] =
             for(%Delta{kind: :toast} = d <- deltas, do: d)

    # Resolved: a second decision on the same request is refused.
    assert {:error, %AdmissionError{code: :not_allowed}} = resolve.("deny-1", :deny_stop)
  end

  test "the session slash commands answer like the service (C7)" do
    pid = source()

    send = fn id, text ->
      request(id, {:dispatch, :send, text, :main, []}, {:draft, {Script.id(:a), :main}}, :outcome)
    end

    assert %DTO.Outcome{
             identifiers: [],
             feedback: %DTO.Feedback{kind: :navigate, feature: :conversations}
           } =
             reply(pid, send.("s-1", "/resume"))

    assert %DTO.Outcome{feedback: %DTO.Feedback{kind: :report, title: "Commands", text: help}} =
             reply(pid, send.("s-2", "/help"))

    assert help =~ "/new — Start a new conversation"

    assert %DTO.Outcome{
             feedback: %DTO.Feedback{kind: :notice, text: "Approval mode: full access"}
           } =
             reply(pid, send.("s-3", "/approval full"))

    assert %DTO.Outcome{feedback: %DTO.Feedback{kind: :navigate, feature: :changes}} =
             reply(pid, send.("s-4", "/diff"))

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Source.request(pid, "client", send.("s-5", "/quit"))

    # Any other slash command is still a prompt in the demo.
    assert %DTO.Outcome{status: :accepted, feedback: nil, identifiers: [_run | _]} =
             reply(pid, send.("s-6", "/plan"))

    assert %DTO.Outcome{identifiers: [new_id], feedback: %DTO.Feedback{feature: :conversations}} =
             reply(pid, send.("s-7", "/new"))

    assert %DTO.ConversationList{current_id: ^new_id} = list(pid, "list-s")
  end

  test "deny and stop stops the run" do
    pid = source()
    assert :ok = Source.advance(pid, "catalogue-activity")
    assert_receive {:fake_source, "client", _deltas}
    approval = Source.snapshot(pid).interactions[Script.id(:approval)]

    assert %DTO.Outcome{status: :accepted} =
             reply(
               pid,
               request(
                 "deny-stop-1",
                 {:resolve_approval, approval.run_id, approval.node_id, approval.id,
                  approval.expected_revision, :deny_stop},
                 {:interaction, approval.id, approval.expected_revision},
                 :outcome
               )
             )

    run = Source.snapshot(pid).runs[approval.run_id]
    assert {run.state, run.stop_reason} == {:stopped, "user_stopped"}
  end
end
