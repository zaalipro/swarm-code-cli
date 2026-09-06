defmodule SwarmCodeCLI.UI.DataSource.FakeComposeTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Request}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Details}

  defp script do
    {:ok, value} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    value
  end

  defp request(kind, id \\ "compose-1", conversation \\ :a) do
    origin =
      case kind do
        {:mark_seen, kind, id, revision} -> {:seen, kind, id, revision}
        _ -> {:draft, {Script.id(conversation), :main}}
      end

    %Request{
      request_id: id,
      kind: kind,
      origin: origin,
      scope: %Scope{kind: :conversation, id: Script.id(conversation), generation: 0},
      generation: 0,
      deadline: Script.clock_ms() + 1000,
      expected_response: :outcome
    }
  end

  test "send creates synthetic scoped facts and repeat ids cannot overwrite canonical text" do
    initial = script()
    req = request({:dispatch, :send, "exact prompt\n", :main, ["attachment-ref"]})
    assert {:ok, next, outcome, _} = Script.command(initial, req)
    [run_id, item_id | _] = outcome.identifiers
    assert next.runs[run_id].conversation_id == Script.id(:a)
    assert next.runs[run_id].state == :running
    assert next.transcript[item_id].role == :user
    assert next.transcript[item_id].text == "exact prompt\n"
    assert next.transcript[item_id].attachment_refs == ["attachment-ref"]
    assert {:ok, ^next, ^outcome, []} = Script.command(next, req)

    assert {:error, %AdmissionError{code: :request_conflict}} =
             Script.command(next, %{req | kind: {:dispatch, :send, "changed", :main, []}})
  end

  test "queue retains parent and steer rejects wrong scope and stopped run" do
    initial = script()
    req = request({:dispatch, :queue, "follow up", {:reply, "message-A-1"}, []})
    assert {:ok, next, outcome, _} = Script.command(initial, req)
    [run_id | _] = outcome.identifiers
    assert next.runs[run_id].state == :queued
    assert next.runs[run_id].parent_run_id == Script.id(:a1)
    steer = {:steer, Script.id(:a1), Script.id(:node_a1), "new direction", []}

    assert {:error, %AdmissionError{code: :invalid_origin}} =
             Script.command(next, request(steer, "wrong", :b))

    assert {:ok, steered, _, _} = Script.command(next, request(steer, "steer"))

    assert Enum.any?(
             Map.values(steered.transcript),
             &(&1.text == "new direction" and &1.run_id == Script.id(:a1))
           )

    run = steered.runs[Script.id(:a1)]
    stopped = put_in(steered.runs[run.id], %{run | state: :stopped, allowed_actions: []})

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Script.command(stopped, request(steer, "stopped"))
  end

  test "mark seen changes exact revision metadata and rejects stale revision" do
    initial = script()
    run = initial.runs[Script.id(:a1)]

    assert {:error, %AdmissionError{code: :stale_revision}} =
             Script.command(initial, request({:mark_seen, :run, run.id, 0}))

    assert {:ok, next, _, _} =
             Script.command(initial, request({:mark_seen, :run, run.id, run.revision}))

    assert next.runs[run.id].seen_revision == run.revision
  end

  test "maximum UTF8 prompt round trips through bounded detail pages" do
    text = String.duplicate("😀", 65_536)

    assert {:ok, next, outcome, _} =
             Script.command(script(), request({:dispatch, :send, text, :main, []}))

    [_, item_id | _] = outcome.identifiers
    item = next.transcript[item_id]
    assert byte_size(item.text) <= 65_536
    assert item.detail_ref.total_bytes == byte_size(text)

    chunks =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          req = %{
            request({:dispatch, :send, "unused", :main, []})
            | kind: {:query_detail, item.detail_ref.id, offset, 8193},
              origin: {:query, :detail},
              expected_response: :detail_window
          }

          assert {:ok, page} = Details.query(next, req)
          assert byte_size(page.text) <= 8193
          {page.text, page.next_offset}
      end)
      |> Enum.to_list()

    assert Enum.join(chunks) == text
  end

  test "wrong draft, absent node, cross-conversation target and removed permission reject without facts" do
    initial = script()
    req = request({:dispatch, :send, "hello", :main, []})
    wrong = %{req | origin: {:draft, {Script.id(:b), :main}}}
    assert {:error, %AdmissionError{code: :invalid_origin}} = Script.command(initial, wrong)
    cross = %{req | kind: {:dispatch, :send, "hello", {:reply, "message-B-1"}, []}}
    assert {:error, %AdmissionError{code: :invalid_origin}} = Script.command(initial, cross)
    steer = request({:steer, Script.id(:a1), "absent", "direction", []})
    assert {:error, %AdmissionError{code: :invalid_origin}} = Script.command(initial, steer)
    run = initial.runs[Script.id(:a1)]
    blocked = put_in(initial.runs[run.id], %{run | allowed_actions: [:stop]})

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Script.command(blocked, %{
               steer
               | kind: {:steer, run.id, Script.id(:node_a1), "direction", []}
             })
  end

  test "conversation and activity seen metadata survive distinct requests and stale revisions" do
    initial = script()
    revision = Script.conversation_revision(initial, Script.id(:a))
    req = request({:mark_seen, :conversation, Script.id(:a), revision})
    assert {:ok, next, _, _} = Script.command(initial, req)
    assert Script.conversation_seen_revision(next, Script.id(:a)) == revision

    assert {:error, %AdmissionError{code: :stale_revision}} =
             Script.command(next, %{
               req
               | request_id: "stale",
                 kind: {:mark_seen, :conversation, Script.id(:a), revision - 1},
                 origin: {:seen, :conversation, Script.id(:a), revision - 1}
             })

    item = initial.activity[Script.id(:a1)]

    assert {:ok, seen, _, deltas} =
             Script.command(
               next,
               request({:mark_seen, :activity, item.id, item.revision}, "activity-seen")
             )

    assert seen.activity[item.id].seen_revision == item.revision

    assert Enum.any?(
             deltas,
             &(&1.kind == :activity_upsert and &1.body.seen_revision == item.revision)
           )
  end

  test "detail pages reject foreign scope and split codepoints; short canonical text stays inline" do
    initial = script()

    assert {:ok, short, _, _} =
             Script.command(
               initial,
               request({:dispatch, :send, String.duplicate("a", 65_536), :main, []}, "short")
             )

    assert short.details == %{}

    assert {:ok, long, outcome, _} =
             Script.command(
               short,
               request({:dispatch, :send, String.duplicate("😀", 16_385), :main, []}, "long")
             )

    [_, id | _] = outcome.identifiers
    ref = long.transcript[id].detail_ref

    req = %{
      request({:dispatch, :send, "x", :main, []})
      | kind: {:query_detail, ref.id, 1, 4},
        origin: {:query, :detail},
        expected_response: :detail_window
    }

    assert {:error, %AdmissionError{code: :invalid_origin}} = Details.query(long, req)

    assert {:error, %AdmissionError{code: :invalid_origin}} =
             Details.query(long, %{
               req
               | kind: {:query_detail, ref.id, 0, 4},
                 scope: %Scope{kind: :conversation, id: Script.id(:b), generation: 0}
             })

    assert {:error, :invalid_dto} =
             SwarmCodeCLI.UI.DataSource.DTO.DetailWindow.validate(
               %SwarmCodeCLI.UI.DataSource.DTO.DetailWindow{
                 detail_ref: ref,
                 offset: 0,
                 text: "😀",
                 next_offset: 5,
                 request_id: "q"
               }
             )
  end

  test "detail aggregate overflow rejects the entire canonical transition" do
    prompt = String.duplicate("x", 262_144)

    full =
      Enum.reduce(1..16, script(), fn i, acc ->
        assert {:ok, next, _, _} =
                 Script.command(acc, request({:dispatch, :send, prompt, :main, []}, "large-#{i}"))

        next
      end)

    assert map_size(full.details) == 16
    before = :erlang.term_to_binary(full)

    assert {:error, %AdmissionError{code: :capacity_exceeded}} =
             Script.command(full, request({:dispatch, :send, prompt, :main, []}, "overflow"))

    assert :erlang.term_to_binary(full) == before
    assert {:ok, ^full} = Script.validate(full)
  end

  test "source keeps deterministic requests after detach and delivers correlated large detail" do
    alias SwarmCodeCLI.UI.DataSource.Fake.Source
    alias SwarmCodeCLI.UI.DataSource.Delivery
    pid = start_supervised!({Source, script: script(), source_epoch: "compose-epoch"})
    :ok = Source.attach(pid, "first", self())
    req = request({:dispatch, :send, String.duplicate("z", 65_537), :main, []})
    assert :ok = Source.request(pid, "first", req)
    assert_receive {:fake_source, "first", %Delivery{kind: :response, body: outcome}}
    first = Source.snapshot(pid)
    :ok = Source.detach(pid, "first")
    :ok = Source.attach(pid, "second", self())
    assert :ok = Source.request(pid, "second", req)
    assert Source.snapshot(pid) == first

    assert {:error, %AdmissionError{code: :request_conflict}} =
             Source.request(pid, "second", %{req | kind: {:dispatch, :send, "changed", :main, []}})

    [_, id | _] = outcome.identifiers
    ref = first.transcript[id].detail_ref

    query = %{
      req
      | request_id: "detail-query",
        kind: {:query_detail, ref.id, 0, 1024},
        origin: {:query, :detail},
        expected_response: :detail_window
    }

    assert :ok = Source.request(pid, "second", query)

    assert_receive {:fake_source, "second",
                    %Delivery{request_id: "detail-query", body: page} = delivery}

    assert page.text == String.duplicate("z", 1024)
    assert {:ok, ^delivery} = Delivery.validate(delivery)
  end

  test "seen activity revision persists when canonical run progresses" do
    initial = script()
    item = initial.activity[Script.id(:a1)]

    assert {:ok, seen, _, _} =
             Script.command(initial, request({:mark_seen, :activity, item.id, item.revision}))

    assert {:ok, progressed, _} = Script.advance(seen, "a1-a2-b1-step-1")
    assert progressed.activity[item.id].seen_revision == item.revision
    assert progressed.activity[item.id].revision > item.revision
  end

  test "extended closed DTOs reject contradictory target and seen fields" do
    alias SwarmCodeCLI.UI.DataSource.DTO
    initial = script()
    item = initial.transcript["message-A-1"]

    assert {:error, :invalid_dto} =
             DTO.TranscriptItem.validate(%{item | target_kind: :main, target_id: "unexpected"})

    assert {:error, :invalid_dto} =
             DTO.TranscriptItem.validate(%{item | state: :superseded, allowed_actions: [:steer]})

    run = initial.runs[Script.id(:a1)]

    assert {:error, :invalid_dto} =
             DTO.RunSummary.validate(%{run | seen_revision: run.revision + 1})

    page = %DTO.WorkspaceSnapshot{
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{},
      transcript: %DTO.TranscriptWindow{}
    }

    assert {:error, :invalid_dto} = DTO.WorkspaceSnapshot.validate(%{page | state: :error})
  end

  test "detail timeout is a closed correlated error page without fabricated reference" do
    alias SwarmCodeCLI.UI.DataSource.DTO.DetailWindow

    page =
      struct(DetailWindow, %{
        state: :error,
        error: AdmissionError.new(:deadline_expired),
        request_id: "detail-timeout",
        offset: 100
      })

    assert {:ok, ^page} = DetailWindow.validate(page)
    assert {:error, :invalid_dto} = DetailWindow.validate(Map.put(page, :text, "fabricated"))
  end

  test "canonical transcript facts cannot advertise unsupported domain operations" do
    initial = script()
    item = %{initial.transcript["message-A-1"] | allowed_actions: [:mark_seen]}

    assert {:error, %AdmissionError{code: :invalid_fixture}} =
             Script.validate(put_in(initial.transcript[item.id], item))
  end

  test "new prompts and runs retain canonical creation order independent of hash ids" do
    initial = script()

    {:ok, first, first_outcome, _} =
      Script.command(initial, request({:dispatch, :send, "first prompt", :main, []}, "z-last"))

    {:ok, second, second_outcome, _} =
      Script.command(first, request({:dispatch, :send, "second prompt", :main, []}, "a-first"))

    [run1, item1 | _] = first_outcome.identifiers
    [run2, item2 | _] = second_outcome.identifiers
    assert second.transcript[item1].created_sequence < second.transcript[item2].created_sequence
    assert second.runs[run1].created_sequence < second.runs[run2].created_sequence

    assert second.transcript["message-A-1"].created_sequence <
             second.transcript[item1].created_sequence
  end

  test "canonical identity collisions and run capacity cannot install partial prompt facts" do
    initial = script()
    req = request({:dispatch, :send, "original", :main, []})
    {:ok, next, _, _} = Script.command(initial, req)
    detached = %{next | commands: %{}}

    assert {:error, %AdmissionError{code: :request_conflict}} =
             Script.command(detached, %{req | kind: {:dispatch, :send, "replacement", :main, []}})

    base = initial.runs[Script.id(:a1)]

    full =
      Enum.reduce(1..197, initial, fn i, acc ->
        run = %{base | id: "capacity-run-#{i}"}
        put_in(acc.runs[run.id], run)
      end)

    assert {:ok, ^full} = Script.validate(full)
    assert {:error, %AdmissionError{code: :capacity_exceeded}} = Script.command(full, req)
    assert map_size(full.transcript) == 3
    assert full.commands == %{}
  end

  test "catalogue inserts get creation order after admitted user facts" do
    {:ok, composed, outcome, _} =
      Script.command(script(), request({:dispatch, :send, "prompt", :main, []}))

    [_, user_id | _] = outcome.identifiers
    {:ok, advanced, deltas} = Script.advance(composed, "catalogue-statuses")
    item = advanced.transcript["message-A-superseded"]
    assert item.created_sequence > advanced.transcript[user_id].created_sequence
    assert Enum.any?(deltas, &(&1.kind == :node_upsert and &1.body == item))
  end
end
