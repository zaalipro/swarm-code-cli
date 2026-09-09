defmodule SwarmCodeCLI.UI.DataSource.Daemon.CodecTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec

  @wire "11111111-1111-4111-8111-111111111111"
  @conversation "22222222-2222-4222-8222-222222222222"
  @nonce String.duplicate("A", 43)
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}

  test "typed query crosses real JSON with remaining TTL and distinct wire identity" do
    request = query()
    assert {:ok, message} = Codec.request(request, @wire, @nonce, 1_000)
    assert message.request_id == @wire
    assert message.scope == @scope

    assert message.body == %{
             "op" => "query",
             "slot" => "transcript",
             "cursor" => nil,
             "direction" => "after",
             "page_size" => 50,
             "byte_limit" => 262_144,
             "timeout_ms" => 4_000
           }

    assert {:ok, wire} = Envelope.encode(message)
    assert {:ok, ^message} = Envelope.decode(IO.iodata_to_binary(wire))

    assert {:error, %AdmissionError{code: :deadline_expired}} =
             Codec.request(request, @wire, @nonce, 5_000)
  end

  test "send supports main text and refuses unsupported actions without silently rewriting them" do
    request = %{
      query()
      | kind: {:dispatch, :send, "Fix the test", :main, []},
        origin: {:draft, {@conversation, :main}},
        expected_response: :outcome
    }

    assert {:ok, message} = Codec.request(request, @wire, @nonce, 1_000)
    assert message.body["action"] == "send"
    assert message.body["target"] == %{"kind" => "main", "id" => nil}

    assert {:ok, _message} =
             Codec.request(
               %{
                 request
                 | kind:
                     {:dispatch, :send, "Fix the test", :main,
                      ["33333333-3333-4333-8333-333333333333"]}
               },
               @wire,
               @nonce,
               1_000
             )

    for kind <- [
          {:dispatch, :queue, "Fix the test", :main, []},
          {:dispatch, :send, "Fix the test", {:reply, "node"}, []}
        ] do
      assert {:error, %AdmissionError{code: :not_allowed}} =
               Codec.request(%{request | kind: kind}, @wire, @nonce, 1_000)
    end

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.request(
               %{request | kind: {:dispatch, :send, "Fix the test", :main, ["attachment"]}},
               @wire,
               @nonce,
               1_000
             )
  end

  test "response checks wire correlation before restoring the original local request ID" do
    request = query()
    response = result("transcript_window", page())
    assert {:ok, %Delivery{} = delivery} = Codec.response(response, request, @wire, @nonce)
    assert delivery.request_id == "local-7"
    assert delivery.body.request_id == "local-7"
    assert delivery.scope == @scope
    assert {:ok, ^delivery} = Delivery.validate(delivery)

    for response <- [
          %{response | request_id: @conversation},
          %{response | nonce: String.duplicate("B", 43)},
          %{response | scope: %{@scope | generation: 3}},
          %{response | scope: %{@scope | id: @wire}},
          %{response | body: Map.put(response.body, "response_kind", "shell_snapshot")},
          %{response | body: put_in(response.body["value"]["request_id"], "unrelated")},
          Map.put(response, :extra, true)
        ] do
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.response(response, request, @wire, @nonce)
    end
  end

  test "canonical wire errors decode inside outcomes and reject arbitrary diagnostics" do
    error = %{"code" => "source_unavailable", "message" => "data source is unavailable"}
    assert {:ok, %AdmissionError{code: :source_unavailable}} = AdmissionError.decode(error)

    for invalid <- [
          Map.put(error, "message", "raw secret failure"),
          Map.put(error, "code", "invented"),
          Map.put(error, "extra", true)
        ] do
      assert {:error, :invalid_admission_error} = AdmissionError.decode(invalid)
    end

    request = %{
      query()
      | kind: {:dispatch, :send, "Fix", :main, []},
        origin: {:draft, {@conversation, :main}},
        expected_response: :outcome
    }

    value = %{
      "status" => "rejected",
      "request_id" => @wire,
      "identifiers" => [],
      "interaction" => nil,
      "error" => error,
      "corrective_action" => "retry"
    }

    assert {:ok,
            %Delivery{
              body: %DTO.Outcome{
                status: :rejected,
                error: %AdmissionError{code: :source_unavailable}
              }
            }} =
             Codec.response(result("outcome", value), request, @wire, @nonce)
  end

  test "transport error is a closed rejection and never a fabricated successful outcome" do
    message = %Message{
      version: 1,
      sequence: nil,
      occurred_at: nil,
      type: :error,
      request_id: @wire,
      nonce: @nonce,
      scope: @scope,
      body: %{"op" => "error", "code" => "not_allowed", "message" => "request is not allowed"}
    }

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Codec.response(message, query(), @wire, @nonce)

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.response(
               %{message | body: Map.put(message.body, "message", "secret")},
               query(),
               @wire,
               @nonce
             )
  end

  test "command feedback stays exact, accepted-only and scoped while old ledger outcomes decode" do
    request = %{
      query()
      | kind: {:dispatch, :send, "/goal", :main, []},
        origin: {:draft, {@conversation, :main}},
        expected_response: :outcome
    }

    old = %{
      "status" => "accepted",
      "request_id" => @wire,
      "identifiers" => [],
      "interaction" => nil,
      "error" => nil,
      "corrective_action" => "none"
    }

    feedback = %{
      "kind" => "report",
      "feature" => nil,
      "title" => "Goal",
      "text" => "Finish the CLI",
      "conversation_id" => @conversation
    }

    value = Map.put(old, "feedback", feedback)

    assert {:ok, %{body: %DTO.Outcome{feedback: nil}}} =
             Codec.response(result("outcome", old), request, @wire, @nonce)

    assert {:ok, %{body: %DTO.Outcome{feedback: %DTO.Feedback{text: "Finish the CLI"}}}} =
             Codec.response(result("outcome", value), request, @wire, @nonce)

    for invalid <- [
          put_in(value["feedback"]["conversation_id"], @wire),
          put_in(value["feedback"]["kind"], "execute"),
          put_in(value["feedback"]["text"], String.duplicate("x", 65_537)),
          Map.put(value, "feedback", Map.delete(feedback, "feature")),
          put_in(value["feedback"]["extra"], "hidden"),
          Map.delete(value, "interaction"),
          Map.put(value, "status", "outcome_unknown"),
          Map.put(value, "feedback", %{feedback | "kind" => "navigate", "feature" => nil})
        ] do
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.response(result("outcome", invalid), request, @wire, @nonce)
    end
  end

  test "actual run and node identities survive approval and steering translation" do
    run = "33333333-3333-4333-8333-333333333333"
    node = "44444444-4444-4444-8444-444444444444"
    interaction = "55555555-5555-4555-8555-555555555555"

    steer = %{
      query()
      | kind: {:steer, run, node, "Explain the change", []},
        origin: {:draft, {@conversation, :main}},
        expected_response: :outcome
    }

    assert {:ok, message} = Codec.request(steer, @wire, @nonce, 1_000)
    assert message.body["node_id"] == node
    assert message.body["run_id"] == run

    approval = %{
      steer
      | kind: {:resolve_approval, run, node, interaction, 7, :approve},
        origin: {:interaction, interaction, 7}
    }

    assert {:ok, message} = Codec.request(approval, @wire, @nonce, 1_000)
    assert message.body["node_id"] == node
    assert message.body["expected_revision"] == 7

    assert {:error, %AdmissionError{code: :not_allowed}} =
             Codec.request(
               %{approval | kind: {:resolve_approval, run, node, interaction, 7, :always_allow}},
               @wire,
               @nonce,
               1_000
             )
  end

  test "admission enforces actual encoded frame size and malformed local values" do
    request = %{
      query()
      | kind: {:dispatch, :send, String.duplicate("\e", 262_144), :main, []},
        origin: {:draft, {@conversation, :main}},
        expected_response: :outcome
    }

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.request(request, @wire, @nonce, 1_000)

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.request(Map.put(query(), :extra, 1), @wire, @nonce, 1_000)

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.request(query(), "invalid-wire-id", @nonce, 1_000)
  end

  test "workspace response restores every nested request ID and rejects a different body scope" do
    request = %{
      query()
      | kind: {:query, :workspace, nil, :after, 50, 262_144},
        origin: {:query, :workspace},
        expected_response: :workspace_snapshot
    }

    value = workspace()

    assert {:ok, delivery} =
             Codec.response(result("workspace_snapshot", value), request, @wire, @nonce)

    assert delivery.body.runs_page.request_id == "local-7"
    assert delivery.body.interactions_page.request_id == "local-7"
    assert delivery.body.transcript.request_id == "local-7"
    assert delivery.body.transcript.error.code == :source_unavailable

    for invalid <- [
          Map.put(value, "conversation_id", @wire),
          put_in(value["runs_page"]["request_id"], @conversation),
          put_in(value["transcript"]["request_id"], @conversation)
        ] do
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.response(
                 result("workspace_snapshot", invalid),
                 request,
                 @wire,
                 @nonce
               )
    end
  end

  test "workspace metadata deltas preserve scope and cannot enter a shell watch" do
    watch = %SwarmCodeCLI.UI.DataSource.Watch{
      watch_ref: "metadata",
      slot: :workspace,
      scope: @scope,
      generation: 2,
      page_size: 20,
      byte_limit: 262_144
    }

    value = %{
      "kind" => "workspace_metadata",
      "entity_id" => nil,
      "run_id" => nil,
      "conversation_id" => @conversation,
      "attempt_id" => nil,
      "channel" => nil,
      "text" => nil,
      "sequence" => 1,
      "revision" => 1,
      "body" => %{
        "conversation_id" => @conversation,
        "mode" => "plan",
        "chat_model" => "planner",
        "swarm_model" => nil,
        "effort" => nil,
        "swarm_effort" => nil
      }
    }

    event = %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: 1,
      occurred_at: "2026-09-09T00:00:00Z",
      body: %{"op" => "delta", "watch_ref" => "metadata", "value" => value}
    }

    assert {:ok, %{kind: :workspace_metadata}} = SwarmCodeCLI.UI.DataSource.Delta.decode(value)

    assert {:ok, %{body: %{body: %DTO.WorkspaceMetadata{mode: :plan}}}} =
             Codec.event(event, watch, @nonce)

    scope = %Scope{kind: :global, id: nil, generation: 2}

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.event(%{event | scope: scope}, %{watch | slot: :shell, scope: scope}, @nonce)
  end

  test "detail responses match requested reference offset and byte limit" do
    request = %{
      query()
      | kind: {:query_detail, "detail", 0, 4},
        origin: {:query, :detail},
        expected_response: :detail_window
    }

    value = %{
      "detail_ref" => %{"id" => "detail", "total_bytes" => 10},
      "state" => "idle",
      "error" => nil,
      "offset" => 0,
      "text" => "1234",
      "next_offset" => 4,
      "through_sequence" => 1,
      "request_id" => @wire
    }

    assert {:ok, _} = Codec.response(result("detail_window", value), request, @wire, @nonce)

    for invalid <- [
          put_in(value["detail_ref"]["id"], "another"),
          %{value | "offset" => 4, "next_offset" => 8},
          %{value | "text" => "12345", "next_offset" => 5}
        ] do
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.response(
                 result("detail_window", invalid),
                 request,
                 @wire,
                 @nonce
               )
    end
  end

  test "v1 wire response requires explicit fields even where fixture decoding has legacy defaults" do
    request = %{
      query()
      | kind: {:query, :workspace, nil, :after, 50, 262_144},
        origin: {:query, :workspace},
        expected_response: :workspace_snapshot
    }

    assert {:error, %AdmissionError{code: :invalid_request}} =
             Codec.response(
               result("workspace_snapshot", Map.delete(workspace(), "allowed_actions")),
               request,
               @wire,
               @nonce
             )
  end

  defp workspace do
    Map.merge(Map.delete(page(), "items"), %{
      "allowed_actions" => [],
      "revision" => 1,
      "seen_revision" => 0,
      "runs_page" => Map.delete(page(), "items"),
      "interactions_page" => Map.delete(page(), "items"),
      "conversation_id" => @conversation,
      "runs" => [],
      "interactions" => [],
      "transcript" => %{
        page()
        | "state" => "error",
          "error" => %{"code" => "source_unavailable", "message" => "data source is unavailable"}
      }
    })
  end

  defp query,
    do: %Request{
      request_id: "local-7",
      kind: {:query, :transcript, nil, :after, 50, 262_144},
      scope: @scope,
      generation: 2,
      origin: {:query, :transcript},
      deadline: 5_000,
      expected_response: :transcript_window
    }

  defp result(kind, value),
    do: %Message{
      version: 1,
      sequence: nil,
      occurred_at: nil,
      type: :response,
      request_id: @wire,
      nonce: @nonce,
      scope: @scope,
      body: %{"op" => "result", "response_kind" => kind, "value" => value}
    }

  defp page,
    do: %{
      "items" => [],
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => @wire,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => [],
      "through_sequence" => 0
    }
end
