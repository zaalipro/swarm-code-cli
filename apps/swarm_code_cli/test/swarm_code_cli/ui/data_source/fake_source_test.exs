defmodule SwarmCodeCLI.UI.DataSource.FakeSourceTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}
  alias SwarmCodeCLI.UI.DataSource.DTO.Outcome

  defp fixture,
    do: File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))

  defp source do
    {:ok, script} = Script.decode(fixture())
    start_supervised!({Source, script: script, source_epoch: "epoch-1"})
  end

  defp watch(slot \\ :activity, size \\ 200, bytes \\ 1_048_576) do
    %Watch{
      watch_ref: "watch-1",
      slot: slot,
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      page_size: size,
      byte_limit: bytes
    }
  end

  defp request(kind, origin, id \\ "request-1") do
    %Request{
      request_id: id,
      kind: kind,
      origin: origin,
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      deadline: Script.clock_ms() + 1000,
      expected_response: :outcome
    }
  end

  test "fixed canonical identities and ordered barrier survive detached clients" do
    pid = source()
    initial = Source.snapshot(pid)
    assert map_size(initial.runs) == 3
    assert initial.runs[Script.id(:a1)].state == :running
    assert Script.id(:a1) == "00000000-0000-4000-8000-0000000000a1"
    assert initial.clock == "2026-09-03T12:00:00Z"
    assert :ok = Source.attach(pid, "client", self())
    assert {:error, :duplicate_client} = Source.attach(pid, "client", self())
    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert_receive {:fake_source, "client", deltas}

    assert Enum.map(Enum.take(deltas, 4), & &1.kind) == [
             :node_upsert,
             :stream_append,
             :stream_append,
             :run_update
           ]

    assert Enum.map(Enum.slice(deltas, 1, 2), & &1.channel) == [:text, :reasoning]
    assert Source.snapshot(pid).interactions[Script.id(:q1)].expected_revision == 7
    assert Source.snapshot(pid).runs[Script.id(:a2)].state == :waiting_question
    assert :ok = Source.detach(pid, "client")
    assert :ok = Source.advance(pid, "a1-b1-step-2")
    refute_receive {:fake_source, "client", _}, 0
    assert Source.snapshot(pid).runs[Script.id(:b1)].progress == 70
    assert :ok = Source.attach(pid, "client-2", self())
    assert :ok = Source.watch(pid, "client-2", watch())
    assert_receive {:fake_source, "client-2", %Delivery{kind: :watch_ready, body: page}}
    assert page.through_sequence == Source.snapshot(pid).sequence
    assert {:error, :unknown_barrier} = Source.advance(pid, "unknown")
  end

  test "accepted question response precedes resolution and can resolve only once" do
    pid = source()
    Source.advance(pid, "a1-a2-b1-step-1")
    Source.attach(pid, "client", self())
    q = Source.snapshot(pid).interactions[Script.id(:q1)]

    req =
      request(
        {:answer_question, q.run_id, q.node_id, q.id, 7, ["option-2"]},
        {:interaction, q.id, 7}
      )

    assert :ok = Source.request(pid, "client", req)

    assert_receive {:fake_source, "client",
                    %Delivery{kind: :response, body: %{__struct__: Outcome, status: :accepted}}}

    assert_receive {:fake_source, "client", [resolved, running | _]}
    assert resolved.kind == :interaction_remove
    assert running.body.state == :running
    assert Source.snapshot(pid).interactions[q.id].state == :resolved

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Source.request(pid, "client", %{req | request_id: "request-2"})
  end

  test "bounded snapshots keep canonical content and explicit off-window presence" do
    pid = source()
    Source.attach(pid, "client", self())
    assert :ok = Source.watch(pid, "client", watch(:activity, 1))
    assert_receive {:fake_source, "client", %Delivery{body: page}}
    assert length(page.items) == 1
    assert page.after_cursor != nil
    assert page.presence == :off_window
    assert page.state == :idle
    assert map_size(Source.snapshot(pid).runs) == 3

    assert {:error, %AdmissionError{code: :capacity_exceeded}} =
             Source.watch(pid, "client", %{watch(:shell, 1, 1) | watch_ref: "tiny"})

    assert map_size(Source.snapshot(pid).runs) == 3
  end

  test "Retry needs exact permission, failed state and CAS; agent Stop never stops run" do
    pid = source()
    Source.advance(pid, "catalogue-retry")
    Source.advance(pid, "catalogue-agent-stop")
    Source.attach(pid, "client", self())
    failed = Source.snapshot(pid).runs[Script.id(:failed_retry)]
    blocked = Source.snapshot(pid).runs[Script.id(:failed_no_retry)]

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Source.request(
               pid,
               "client",
               request(
                 {:retry_run, blocked.id, blocked.revision},
                 {:run_revision, blocked.id, blocked.revision}
               )
             )

    assert {:error, %AdmissionError{code: :stale_revision}} =
             Source.request(
               pid,
               "client",
               request(
                 {:retry_run, failed.id, failed.revision - 1},
                 {:run_revision, failed.id, failed.revision - 1}
               )
             )

    assert :ok =
             Source.request(
               pid,
               "client",
               request(
                 {:retry_run, failed.id, failed.revision},
                 {:run_revision, failed.id, failed.revision}
               )
             )

    assert Source.snapshot(pid).runs[failed.id].state == :retrying
    assert Source.snapshot(pid).runs[failed.id].revision == 42
    agent = Source.snapshot(pid).agents[Script.id(:agent_stop)]
    run_before = Source.snapshot(pid).runs[agent.run_id]
    assert :stop_agent in agent.allowed_actions
    assert :stop not in agent.allowed_actions

    assert :ok =
             Source.request(
               pid,
               "client",
               request(
                 {:stop_agent, agent.run_id, agent.id, agent.revision},
                 {:agent, agent.run_id, agent.id, agent.revision},
                 "stop-agent"
               )
             )

    assert Source.snapshot(pid).agents[agent.id].state == :stopped
    assert Source.snapshot(pid).agents[agent.id].revision == 52
    assert Source.snapshot(pid).runs[agent.run_id] == run_before
  end

  test "unknown messages and malformed fixtures fail statically without state loss" do
    pid = source()
    before = Source.snapshot(pid)

    assert {:error, %AdmissionError{code: :invalid_request}} =
             GenServer.call(pid, {:unknown, "private text"})

    send(pid, {:unknown, "private text"})
    assert before == Source.snapshot(pid)
    assert {:error, %AdmissionError{code: :invalid_fixture}} = Script.decode("{}")

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode(String.duplicate("x", 1_048_577))

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode(String.replace(fixture(), "running", "unrecognized-state"))

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Source.request(pid, "missing", %{secret: "private"})

    refute inspect(:sys.get_status(pid)) =~ "private text"
  end

  test "closed wire enums and fixture decode create no atoms from input" do
    Script.decode(fixture())
    Outcome.decode_status("accepted")
    Outcome.decode_status("unknown")
    before = :erlang.system_info(:atom_count)

    for n <- 1..100 do
      assert :error = Outcome.decode_status("untrusted-outcome-#{n}")

      assert {:error, %AdmissionError{code: :invalid_fixture}} =
               Script.decode(~s({"untrusted-key-#{n}": "untrusted-state-#{n}"}))
    end

    assert :erlang.system_info(:atom_count) == before
  end

  test "every source reply and canonical delta validates with exact ready sequence" do
    pid = source()
    Source.attach(pid, "client", self())

    for slot <- [:shell, :workspace, :activity] do
      assert :ok = Source.watch(pid, "client", %{watch(slot) | watch_ref: Atom.to_string(slot)})
      assert_receive {:fake_source, "client", %Delivery{} = ready}
      assert {:ok, ^ready} = Delivery.validate(ready)
    end

    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert_receive {:fake_source, "client", deltas}
    assert Enum.map(deltas, & &1.sequence) == Enum.to_list(1..length(deltas))

    for delta <- deltas,
        do: assert({:ok, ^delta} = SwarmCodeCLI.UI.DataSource.Delta.validate(delta))

    assert :ok = Source.advance(pid, "sequence-gap")
    assert_receive {:fake_source, "client", [gap]}
    assert gap.kind == :snapshot_required
    assert gap.sequence == List.last(deltas).sequence + 2
    assert {:ok, _} = Script.validate(Source.snapshot(pid))
  end

  test "scoped pages stay within conversation and correlated keyset queries recover all content" do
    pid = source()
    Source.attach(pid, "client", self())
    scope = %Scope{kind: :conversation, id: Script.id(:a), generation: 0}
    assert :ok = Source.watch(pid, "client", %{watch(:workspace, 1) | scope: scope})
    assert_receive {:fake_source, "client", %Delivery{body: body}}
    assert Enum.all?(body.runs, &(&1.conversation_id == Script.id(:a)))
    assert Enum.all?(body.transcript.items, &(&1.conversation_id == Script.id(:a)))

    query = %{
      request({:run_control, :stop, Script.id(:a1)}, {:run, Script.id(:a1)})
      | kind: {:query, :transcript, body.transcript.after_cursor, :after, 1, 1_048_576},
        origin: {:query, :transcript},
        expected_response: :transcript_window,
        scope: scope
    }

    assert :ok = Source.request(pid, "client", query)

    assert_receive {:fake_source, "client",
                    %Delivery{request_id: "request-1", body: older} = delivery}

    assert {:ok, ^delivery} = Delivery.validate(delivery)
    assert older.request_id == query.request_id

    assert Enum.map(body.transcript.items ++ older.items, & &1.id) == [
             "message-A-1",
             "message-A-2"
           ]

    assert older.before_cursor != nil
    assert older.after_cursor == nil

    bad_scope = %{
      request({:run_control, :stop, Script.id(:b1)}, {:run, Script.id(:b1)}, "wrong-scope")
      | scope: scope
    }

    before = Source.snapshot(pid)

    assert {:error, %AdmissionError{code: :invalid_origin}} =
             Source.request(pid, "client", bad_scope)

    assert before == Source.snapshot(pid)
  end

  test "command admission keeps target, origin, permissions, states and revisions distinct" do
    pid = source()
    Source.advance(pid, "catalogue-agent-stop")
    Source.advance(pid, "catalogue-retry")
    Source.attach(pid, "client", self())
    a = Source.snapshot(pid).agents[Script.id(:agent_stop)]
    b = Source.snapshot(pid).agents[Script.id(:agent_no_stop)]

    cases = [
      {request({:stop_agent, a.run_id, b.id, b.revision}, {:agent, a.run_id, b.id, b.revision}),
       :not_allowed},
      {request(
         {:stop_agent, Script.id(:b1), a.id, a.revision},
         {:agent, Script.id(:b1), a.id, a.revision}
       ), :invalid_origin},
      {request(
         {:stop_agent, a.run_id, a.id, a.revision - 1},
         {:agent, a.run_id, a.id, a.revision - 1}
       ), :stale_revision},
      {request({:run_control, :stop, a.id}, {:run, a.id}), :invalid_origin},
      {request({:stop_agent, a.run_id, a.id, a.revision}, {:run, a.run_id}), :invalid_request},
      {request({:retry_run, a.run_id, 1}, {:run_revision, a.run_id, 1}), :not_allowed}
    ]

    before = Source.snapshot(pid)

    for {req, code} <- cases do
      assert {:error, %AdmissionError{code: ^code}} = Source.request(pid, "client", req)
      assert before == Source.snapshot(pid)
      refute_receive {:fake_source, "client", _}, 0
    end

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :stop, a.run_id}, {:run, a.run_id})
             )

    assert Source.snapshot(pid).runs[a.run_id].state == :stopped
    assert Source.snapshot(pid).agents[a.id] == a
    assert_receive {:fake_source, "client", %Delivery{} = response}
    assert {:ok, ^response} = Delivery.validate(response)
  end

  test "client owner death cleans monitors and watches without cancelling canonical work" do
    pid = source()

    owner =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    Source.attach(pid, "ephemeral", owner)
    monitor = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    # A synchronous sys barrier follows the DOWN already sent to the source.
    :sys.get_state(pid)
    assert {:error, %AdmissionError{code: :not_bound}} = Source.watch(pid, "ephemeral", watch())
    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert Source.snapshot(pid).runs[Script.id(:a2)].state == :waiting_question
    assert :ok = Source.attach(pid, "ephemeral", self())
    assert :ok = Source.detach(pid, "ephemeral")
    assert :ok = Source.detach(pid, "ephemeral")
  end

  test "watch and client capacities and absolute deadlines fail before canonical mutation" do
    pid = source()
    for n <- 1..32, do: assert(:ok = Source.attach(pid, "client-#{n}", self()))

    assert {:error, %AdmissionError{code: :capacity_exceeded}} =
             Source.attach(pid, "overflow", self())

    for n <- 1..16,
        do: assert(:ok = Source.watch(pid, "client-1", %{watch() | watch_ref: "watch-#{n}"}))

    assert {:error, %AdmissionError{code: :capacity_exceeded}} =
             Source.watch(pid, "client-1", %{watch() | watch_ref: "overflow"})

    assert {:error, %AdmissionError{code: :duplicate_watch}} =
             Source.watch(pid, "client-1", watch())

    req = %{
      request({:run_control, :stop, Script.id(:a1)}, {:run, Script.id(:a1)})
      | deadline: Script.clock_ms()
    }

    before = Source.snapshot(pid)

    assert {:error, %AdmissionError{code: :deadline_expired}} =
             Source.request(pid, "client-1", req)

    assert before == Source.snapshot(pid)
  end

  test "catalogues contain closed statuses, exact permissions and ordered distinct needs-you" do
    pid = source()

    for barrier <- [
          "catalogue-statuses",
          "catalogue-activity",
          "catalogue-agent-stop",
          "catalogue-retry"
        ],
        do: Source.advance(pid, barrier)

    state = Source.snapshot(pid)
    assert length(state.statuses) == 21

    assert Enum.any?(
             state.statuses,
             &(&1.state == :superseded and &1.allowed_actions == [:inspect, :copy, :fork])
           )

    assert Enum.any?(
             state.statuses,
             &(&1.state == :mutation_pending and &1.request_id == Script.id(:request))
           )

    Source.attach(pid, "client", self())
    Source.watch(pid, "client", watch())
    assert_receive {:fake_source, "client", %Delivery{body: page} = delivery}
    assert {:ok, ^delivery} = Delivery.validate(delivery)

    assert Enum.map(Enum.take(page.items, 3), & &1.id) == [
             Script.id(:q2),
             Script.id(:q1),
             Script.id(:approval)
           ]

    assert Enum.map(Enum.take(page.items, 3), & &1.interaction.urgency) == [
             :urgent,
             :high,
             :normal
           ]

    assert Enum.any?(page.items, &(&1.kind == :paused))
    assert Enum.any?(page.items, &(&1.kind == :completion))
    assert {:ok, ^state} = Script.validate(state)
  end

  test "DTO validators reject forged nested bodies, oversized lists and inappropriate permissions" do
    alias SwarmCodeCLI.UI.DataSource.DTO
    script = Source.snapshot(source())
    run = script.runs[Script.id(:a1)]

    assert {:error, :invalid_dto} =
             DTO.RunSummary.validate(%{run | allowed_actions: [:stop_agent]})

    assert {:error, :invalid_dto} =
             DTO.AgentSummary.validate(%DTO.AgentSummary{
               id: "agent",
               run_id: run.id,
               allowed_actions: [:stop]
             })

    assert {:error, :invalid_dto} =
             DTO.RunSummary.validate(%{run | title: String.duplicate("x", 65_537)})

    assert {:error, :invalid_dto} =
             DTO.TranscriptWindow.validate(%DTO.TranscriptWindow{
               items: List.duplicate(script.transcript["message-A-1"], 201)
             })

    assert {:error, :invalid_dto} = DTO.RunSummary.validate(Map.put(run, :secret, "private"))

    assert {:error, :invalid_dto} =
             DTO.TranscriptWindow.validate(%DTO.TranscriptWindow{state: :loading_before})

    assert {:error, :invalid_dto} =
             DTO.PendingInteraction.validate(%DTO.PendingInteraction{
               id: "q",
               run_id: run.id,
               node_id: "node",
               conversation_id: run.conversation_id,
               kind: :question,
               question: nil
             })

    assert {:error, :invalid_dto} =
             DTO.Outcome.validate(%DTO.Outcome{status: :needs_input, request_id: "request"})

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode(String.replace(fixture(), "A1", String.duplicate("x", 65_537)))

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode(
               String.replace(fixture(), ~s("version": 1), ~s("version": 1, "version": 1))
             )

    assert DateTime.to_unix(~U[2026-09-03 12:00:00Z], :millisecond) == Script.clock_ms()
  end

  test "committed presentation catalogues decode bounded typed facts matching scripted evidence" do
    status_json = File.read!(Path.expand("../../../fixtures/fake/status_catalogue.json", __DIR__))
    activity_json = File.read!(Path.expand("../../../fixtures/fake/activity_page.json", __DIR__))
    assert {:ok, statuses} = Script.decode_catalogue(status_json)
    assert statuses == Script.status_catalogue()

    assert {:ok, %SwarmCodeCLI.UI.DataSource.DTO.ActivitySnapshot{} = page} =
             Script.decode_catalogue(activity_json)

    assert length(Enum.filter(page.items, &(&1.kind == :question))) == 2
    assert length(Enum.filter(page.items, &(&1.kind == :approval))) == 1

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode_catalogue(String.replace(status_json, "connecting", "unknown-state"))
  end

  test "closed enum decoding rejects atom-bearing wire values and deeply invalid deltas" do
    alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}
    run = Source.snapshot(source()).runs[Script.id(:a1)]
    raw = Map.from_struct(run) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    assert {:error, :invalid_dto} = DTO.RunSummary.decode(raw)

    assert {:error, :invalid_delta} =
             Delta.validate(%Delta{
               kind: :stream_append,
               entity_id: "item",
               attempt_id: "attempt",
               channel: :text,
               text: "ok",
               body: %{private: true}
             })

    assert {:error, :invalid_delta} =
             Delta.validate(%Delta{kind: :run_update, entity_id: "wrong-id", body: run})

    assert {:error, :invalid_delivery} =
             Delivery.validate(%Delivery{
               kind: :response,
               watch_ref: nil,
               request_id: "request-1",
               scope: watch().scope,
               generation: 0,
               revision: nil,
               sequence: nil,
               body: %DTO.Outcome{status: :accepted, request_id: "other-request"}
             })
  end

  test "nested workspace pages expose their own coverage and pending query cursor" do
    pid = source()
    Source.advance(pid, "catalogue-activity")
    Source.attach(pid, "client", self())
    Source.watch(pid, "client", watch(:workspace, 1))
    assert_receive {:fake_source, "client", %Delivery{body: page}}
    assert page.runs_page.after_cursor != nil
    assert page.interactions_page.after_cursor != nil
    assert page.runs_page.covered_ids == Enum.map(page.runs, & &1.id)

    query = %{
      request({:run_control, :stop, Script.id(:a1)}, {:run, Script.id(:a1)})
      | kind: {:query, :pending, page.interactions_page.after_cursor, :after, 1, 1_048_576},
        origin: {:query, :pending},
        expected_response: :pending_interactions
    }

    assert :ok = Source.request(pid, "client", query)
    assert_receive {:fake_source, "client", %Delivery{body: pending} = reply}
    assert {:ok, ^reply} = Delivery.validate(reply)
    assert length(pending.items) == 1
    refute hd(pending.items).id == hd(page.interactions).id
  end

  test "Inspector is run-scoped and its nested transcript coverage uses transcript IDs" do
    pid = source()
    Source.advance(pid, "catalogue-agent-stop")
    Source.attach(pid, "client", self())

    assert {:error, %AdmissionError{code: :invalid_watch}} =
             Source.watch(pid, "client", watch(:inspector))

    run_scope = %Scope{kind: :run, id: Script.id(:a1), generation: 0}
    assert :ok = Source.watch(pid, "client", %{watch(:inspector, 1) | scope: run_scope})
    assert_receive {:fake_source, "client", %Delivery{body: detail} = ready}
    assert {:ok, ^ready} = Delivery.validate(ready)
    assert detail.run.id == Script.id(:a1)
    assert Enum.all?(detail.agents, &(&1.run_id == Script.id(:a1)))
    assert detail.transcript.covered_ids == Enum.map(detail.transcript.items, & &1.id)
    assert detail.after_cursor != nil
    assert detail.transcript.after_cursor == nil
  end

  test "superseded canonical turns remain lossless and inspectable" do
    pid = source()
    Source.advance(pid, "catalogue-statuses")
    Source.attach(pid, "client", self())
    Source.watch(pid, "client", watch(:workspace))
    assert_receive {:fake_source, "client", %Delivery{body: page}}
    superseded = Enum.find(page.transcript.items, &(&1.state == :superseded))
    assert superseded.text == "Original superseded authentication proposal."
    assert superseded.allowed_actions == [:inspect, :copy, :fork]
    assert :ok = Source.detach(pid, "client")
    assert Source.snapshot(pid).transcript[superseded.id] == superseded
  end

  test "script validation rejects incomplete canonical state and altered fixed conversation identities" do
    {:ok, script} = Script.decode(fixture())

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.validate(%{script | transcript: %{}})

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.validate(%{script | runs: Map.delete(script.runs, Script.id(:a1))})

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode(String.replace(fixture(), Script.id(:a), Script.id(:b)))

    pid = source()
    Source.attach(pid, "client", self())

    req = %{
      request({:run_control, :stop, Script.id(:a1)}, {:run, Script.id(:a1)})
      | kind: {:query, :inspector, nil, :after, 1, 1_048_576},
        origin: {:query, :inspector},
        expected_response: :run_detail_snapshot
    }

    assert {:error, %AdmissionError{code: :invalid_request}} = Source.request(pid, "client", req)
  end

  test "canonical Activity changes are explicitly delivered after ordered run facts" do
    pid = source()
    Source.attach(pid, "client", self())
    Source.advance(pid, "a1-a2-b1-step-1")
    assert_receive {:fake_source, "client", deltas}
    state = Source.snapshot(pid)
    q = state.interactions[Script.id(:q1)]
    assert Enum.any?(deltas, &(&1.kind == :activity_upsert and &1.entity_id == q.id))

    assert Enum.any?(
             deltas,
             &(&1.kind == :activity_upsert and &1.entity_id == Script.id(:b1) and
                 &1.body == state.activity[Script.id(:b1)])
           )

    req =
      request(
        {:answer_question, q.run_id, q.node_id, q.id, 7, ["option-2"]},
        {:interaction, q.id, 7}
      )

    Source.request(pid, "client", req)
    assert_receive {:fake_source, "client", %Delivery{}}
    assert_receive {:fake_source, "client", resolved}
    assert Enum.any?(resolved, &(&1.kind == :activity_remove and &1.entity_id == q.id))

    for delta <- resolved,
        do: assert({:ok, ^delta} = SwarmCodeCLI.UI.DataSource.Delta.validate(delta))
  end

  test "same-size forged DTO and Script missing required keys fail statically" do
    {:ok, script} = Script.decode(fixture())
    run = script.runs[Script.id(:a1)]
    forged_run = run |> Map.delete(:title) |> Map.put(:unknown, "private")
    assert {:error, :invalid_dto} = SwarmCodeCLI.UI.DataSource.DTO.RunSummary.validate(forged_run)
    forged_script = script |> Map.delete(:transcript) |> Map.put(:unknown, "private")
    assert {:error, %AdmissionError{code: :invalid_fixture}} = Script.validate(forged_script)

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.validate(%{script | runs: Map.put(script.runs, run.id, forged_run)})
  end

  test "scripted progress preserves monotonic run revisions after interleaved commands" do
    pid = source()
    Source.advance(pid, "a1-a2-b1-step-1")
    Source.attach(pid, "client", self())
    run_id = Script.id(:a1)

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :pause, run_id}, {:run, run_id}, "pause")
             )

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :continue, run_id}, {:run, run_id}, "continue")
             )

    assert Source.snapshot(pid).runs[run_id].revision == 4
    assert :ok = Source.advance(pid, "a1-b1-step-2")
    assert Source.snapshot(pid).runs[run_id].revision == 5
    assert Source.snapshot(pid).runs[run_id].progress == 60
  end

  test "stopping a waiting run settles its interaction and answer cannot resurrect work" do
    pid = source()
    Source.advance(pid, "a1-a2-b1-step-1")
    Source.attach(pid, "client", self())
    q = Source.snapshot(pid).interactions[Script.id(:q1)]

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :stop, q.run_id}, {:run, q.run_id}, "stop")
             )

    assert_receive {:fake_source, "client", %Delivery{}}
    assert_receive {:fake_source, "client", deltas}
    assert Enum.any?(deltas, &(&1.kind == :interaction_remove and &1.entity_id == q.id))
    assert Enum.any?(deltas, &(&1.kind == :activity_remove and &1.entity_id == q.id))
    stopped = Source.snapshot(pid)
    assert stopped.interactions[q.id].state == :resolved

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Source.request(
               pid,
               "client",
               request(
                 {:answer_question, q.run_id, q.node_id, q.id, 7, ["option-2"]},
                 {:interaction, q.id, 7},
                 "answer"
               )
             )

    assert Source.snapshot(pid) == stopped
    refute_receive {:fake_source, "client", _}, 0
  end

  test "oversized scripted append refuses entire barrier without dropping canonical text" do
    {:ok, script} = Script.decode(fixture())
    full = String.duplicate("x", 65_536)
    script = put_in(script.transcript["message-A-1"].text, full)
    assert {:ok, ^script} = Script.validate(script)
    pid = start_supervised!({Source, script: script, source_epoch: "bounded-epoch"})
    Source.attach(pid, "client", self())

    assert {:error, %AdmissionError{code: :capacity_exceeded}} =
             Source.advance(pid, "a1-a2-b1-step-1")

    assert Source.snapshot(pid) == script
    assert Source.snapshot(pid).transcript["message-A-1"].text == full
    refute_receive {:fake_source, "client", _}, 0
    assert :ok = Source.watch(pid, "client", watch(:workspace))
    assert_receive {:fake_source, "client", %Delivery{} = ready}
    assert {:ok, ^ready} = Delivery.validate(ready)
  end

  test "typed delta routing scope must agree with every applicable body identity" do
    alias SwarmCodeCLI.UI.DataSource.Delta
    pid = source()
    Source.attach(pid, "client", self())
    Source.advance(pid, "a1-a2-b1-step-1")
    assert_receive {:fake_source, "client", deltas}

    for delta <-
          Enum.filter(
            deltas,
            &(&1.kind in [:node_upsert, :run_update, :interaction_upsert, :activity_upsert])
          ) do
      assert {:error, :invalid_delta} =
               Delta.validate(%{delta | run_id: Script.id(:b1) <> "-wrong"})

      assert {:error, :invalid_delta} =
               Delta.validate(%{delta | conversation_id: Script.id(:b) <> "-wrong"})

      forged = delta |> Map.delete(:kind) |> Map.put(:unknown, "private")
      assert {:error, :invalid_delta} = Delta.validate(forged)
    end
  end

  test "fake fixture advertises executable steer but rejects send on entity facts" do
    {:ok, script} = Script.decode(fixture())
    run = %{script.runs[Script.id(:a1)] | allowed_actions: [:steer]}
    assert {:ok, ^run} = SwarmCodeCLI.UI.DataSource.DTO.RunSummary.validate(run)
    assert {:ok, _} = Script.validate(%{script | runs: Map.put(script.runs, run.id, run)})
    assert {:ok, _} = Script.decode(String.replace(fixture(), ~s("pause"), ~s("steer")))

    stopped = %{run | state: :stopped}

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.validate(%{script | runs: Map.put(script.runs, run.id, stopped)})

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.decode(String.replace(fixture(), ~s("pause"), ~s("send")))
  end

  test "scripted barriers skip stopped and paused branches while independent B1 progresses" do
    pid = source()
    Source.attach(pid, "client", self())

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :stop, Script.id(:a1)}, {:run, Script.id(:a1)}, "stop-a1")
             )

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :pause, Script.id(:a2)}, {:run, Script.id(:a2)}, "pause-a2")
             )

    controlled = Source.snapshot(pid)
    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert :ok = Source.advance(pid, "a1-b1-step-2")
    current = Source.snapshot(pid)
    assert current.runs[Script.id(:a1)] == controlled.runs[Script.id(:a1)]
    assert current.runs[Script.id(:a2)] == controlled.runs[Script.id(:a2)]
    assert current.transcript["message-A-1"] == controlled.transcript["message-A-1"]
    assert current.interactions == %{}
    assert current.runs[Script.id(:b1)].progress == 70
  end

  test "a stopped waiting branch cannot be reintroduced by later catalogue barriers" do
    pid = source()
    Source.advance(pid, "a1-a2-b1-step-1")
    Source.attach(pid, "client", self())
    run = Script.id(:a2)

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:run_control, :stop, run}, {:run, run}, "stop")
             )

    stopped = Source.snapshot(pid)
    assert :ok = Source.advance(pid, "catalogue-activity")
    assert Source.snapshot(pid).runs[run] == stopped.runs[run]

    assert Source.snapshot(pid).interactions[Script.id(:q1)] ==
             stopped.interactions[Script.id(:q1)]

    refute Map.has_key?(Source.snapshot(pid).activity, Script.id(:q1))
  end

  test "catalogue overlap never rolls a retrying run back to fixed failed revision" do
    pid = source()
    Source.advance(pid, "catalogue-activity")
    Source.attach(pid, "client", self())
    run = Source.snapshot(pid).runs[Script.id(:failed_retry)]

    assert :ok =
             Source.request(
               pid,
               "client",
               request({:retry_run, run.id, run.revision}, {:run_revision, run.id, run.revision})
             )

    retrying = Source.snapshot(pid).runs[run.id]
    assert :ok = Source.advance(pid, "catalogue-retry")
    assert Source.snapshot(pid).runs[run.id] == retrying
  end

  test "ordinary barrier preserves Q1 resolved earlier through the Activity catalogue" do
    pid = source()
    assert :ok = Source.advance(pid, "catalogue-activity")
    Source.attach(pid, "client", self())
    q = Source.snapshot(pid).interactions[Script.id(:q1)]

    assert :ok =
             Source.request(
               pid,
               "client",
               request(
                 {:answer_question, q.run_id, q.node_id, q.id, 7, ["option-2"]},
                 {:interaction, q.id, 7}
               )
             )

    assert_receive {:fake_source, "client", %Delivery{}}
    assert_receive {:fake_source, "client", _}
    settled = Source.snapshot(pid)
    assert settled.interactions[q.id].state == :resolved
    assert :ok = Source.advance(pid, "a1-a2-b1-step-1")
    assert_receive {:fake_source, "client", deltas}
    current = Source.snapshot(pid)
    assert current.interactions[q.id] == settled.interactions[q.id]
    assert current.runs[q.run_id] == settled.runs[q.run_id]
    refute Map.has_key?(current.activity, q.id)
    refute Enum.any?(deltas, &(&1.kind == :interaction_upsert and &1.entity_id == q.id))
    assert current.runs[Script.id(:b1)].progress == 40
  end
end
