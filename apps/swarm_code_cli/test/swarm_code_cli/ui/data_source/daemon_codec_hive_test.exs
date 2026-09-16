defmodule SwarmCodeCLI.UI.DataSource.Daemon.CodecHiveTest do
  @moduledoc "The daemon codec round-trips snapshots and deltas carrying the wave 1 additions."
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire

  @wire "11111111-1111-4111-8111-111111111111"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "33333333-3333-4333-8333-333333333333"
  @nonce String.duplicate("A", 43)
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}

  defp watch,
    do: %Watch{
      watch_ref: "workspace-1",
      slot: :workspace,
      scope: @scope,
      generation: 2,
      page_size: 20,
      byte_limit: 262_144
    }

  defp through_json(message) do
    {:ok, bytes} = Envelope.encode(message)
    {:ok, decoded} = Envelope.decode(IO.iodata_to_binary(bytes))
    decoded
  end

  defp ready(value),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: 9,
      occurred_at: "2026-09-16T00:00:00Z",
      body: %{
        "op" => "watch_ready",
        "watch_ref" => "workspace-1",
        "revision" => 7,
        "body_kind" => "workspace_snapshot",
        "value" => value
      }
    }

  defp delta_event(value),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: 12,
      occurred_at: "2026-09-16T00:00:00Z",
      body: %{"op" => "delta", "watch_ref" => "workspace-1", "value" => value}
    }

  defp delta_value(kind, entity_id, body),
    do: %{
      "kind" => kind,
      "entity_id" => entity_id,
      "run_id" => @run,
      "conversation_id" => @conversation,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => body,
      "sequence" => 12,
      "revision" => 2
    }

  test "a watch snapshot with changes, verdicts, tool items and run gauges crosses real JSON" do
    message = through_json(ready(Wire.workspace()))

    assert {:ok, %Delivery{kind: :watch_ready, body: page}} =
             Codec.event(message, watch(), @nonce)

    assert [%DTO.Change{id: "change-1", agent_id: agent}] = page.changes
    assert agent == "44444444-4444-4444-8444-444444444444"
    assert [%DTO.Verdict{checks: [_, _, _, _], summary: summary}] = page.verdicts
    assert summary =~ "meet the bar"

    assert [%DTO.TranscriptItem{kind: :tool, tool: %DTO.ToolCall{name: "grep", files: [_]}}] =
             page.transcript.items

    assert [
             %DTO.RunSummary{
               model: "kimi-k2-thinking",
               agents_total: 5,
               needs: 1,
               consensus: true
             }
           ] = page.runs
  end

  test "an older daemon that omits every new key still installs the snapshot" do
    legacy_run = Map.take(Wire.run_summary(), Wire.legacy_run_keys())
    legacy_item = Map.drop(Wire.transcript_item(), ~w(kind tool agent_id tokens_in tokens_out at))

    value =
      Wire.workspace()
      |> Map.drop(~w(changes verdicts mode chat_model swarm_model effort swarm_effort))
      |> Map.put("runs", [legacy_run])
      |> Map.put("transcript", Map.put(Wire.page(), "items", [legacy_item]))

    message = through_json(ready(value))
    assert {:ok, %Delivery{body: page}} = Codec.event(message, watch(), @nonce)
    assert {page.changes, page.verdicts} == {[], []}
    assert [%DTO.RunSummary{tokens_in: 0, model: nil, consensus: false}] = page.runs
    assert [%DTO.TranscriptItem{kind: :text, tool: nil, at: 0}] = page.transcript.items

    # Legacy fixture-only defaults remain mandatory on the wire.
    assert {:error, %AdmissionError{}} =
             Codec.event(
               through_json(ready(Map.delete(value, "allowed_actions"))),
               watch(),
               @nonce
             )
  end

  test "a tool call omitting its optional keys installs; bounds still reject inside the codec" do
    item = Map.put(Wire.transcript_item(), "tool", Map.take(Wire.tool_call(), ["name"]))
    value = Map.put(Wire.workspace(), "transcript", Map.put(Wire.page(), "items", [item]))

    assert {:ok, %Delivery{body: page}} = Codec.event(through_json(ready(value)), watch(), @nonce)

    assert [%DTO.TranscriptItem{tool: %DTO.ToolCall{name: "grep", files: [], status: :done}}] =
             page.transcript.items

    long = put_in(Wire.transcript_item(), ["tool", "title"], String.duplicate("t", 201))
    value = Map.put(Wire.workspace(), "transcript", Map.put(Wire.page(), "items", [long]))
    assert {:error, %AdmissionError{}} = Codec.event(through_json(ready(value)), watch(), @nonce)

    stray = put_in(Wire.workspace(), ["changes", Access.at(0), "extra"], true)
    assert {:error, %AdmissionError{}} = Codec.event(through_json(ready(stray)), watch(), @nonce)
  end

  test "change and verdict deltas decode for the conversation watch that owns the run" do
    change = delta_value("change_upsert", "change-1", Wire.change())

    assert {:ok,
            %Delivery{
              kind: :delta,
              sequence: 12,
              body: %Delta{kind: :change_upsert, body: %DTO.Change{}}
            }} =
             Codec.event(through_json(delta_event(change)), watch(), @nonce)

    verdict = delta_value("verdict_upsert", "judge-1", Map.put(Wire.verdict(), "revision", 2))

    assert {:ok,
            %Delivery{
              body: %Delta{kind: :verdict_upsert, body: %DTO.Verdict{checks: [_, _, _, _]}}
            }} =
             Codec.event(through_json(delta_event(verdict)), watch(), @nonce)

    remove = delta_value("change_remove", "change-1", nil)

    assert {:ok, %Delivery{body: %Delta{kind: :change_remove, body: nil}}} =
             Codec.event(through_json(delta_event(remove)), watch(), @nonce)

    # Another conversation's change is not admitted into this watch.
    foreign = Map.put(change, "conversation_id", @wire)

    assert {:error, %AdmissionError{}} =
             Codec.event(through_json(delta_event(foreign)), watch(), @nonce)

    # The delta's revision must be the entity's revision.
    assert {:error, %AdmissionError{}} =
             Codec.event(
               through_json(delta_event(Map.put(change, "revision", 3))),
               watch(),
               @nonce
             )
  end

  test "a workspace query response carries the agents of its runs" do
    request = %Request{
      request_id: "local-8",
      kind: {:query, :workspace, nil, :after, 50, 262_144},
      scope: @scope,
      generation: 2,
      origin: {:query, :workspace},
      deadline: 5_000,
      expected_response: :workspace_snapshot
    }

    value =
      Wire.workspace()
      |> Map.put("agents", [Wire.agent_summary()])
      |> Map.put("request_id", @wire)
      |> Map.put("runs_page", Map.put(Wire.page(), "request_id", @wire))
      |> Map.put("interactions_page", Map.put(Wire.page(), "request_id", @wire))
      |> Map.put("transcript", Map.put(Wire.page(), "request_id", @wire) |> Map.put("items", []))

    response = %Message{
      version: 1,
      sequence: nil,
      occurred_at: nil,
      type: :response,
      request_id: @wire,
      nonce: @nonce,
      scope: @scope,
      body: %{"op" => "result", "response_kind" => "workspace_snapshot", "value" => value}
    }

    assert {:ok, %Delivery{body: page}} =
             Codec.response(through_json(response), request, @wire, @nonce)

    assert [%DTO.AgentSummary{id: "agent-4", run_id: run_id}] = page.agents
    assert run_id == Wire.run_id()
  end

  test "a workspace query response carries changes and verdicts" do
    request = %Request{
      request_id: "local-7",
      kind: {:query, :workspace, nil, :after, 50, 262_144},
      scope: @scope,
      generation: 2,
      origin: {:query, :workspace},
      deadline: 5_000,
      expected_response: :workspace_snapshot
    }

    value =
      Wire.workspace()
      |> Map.put("request_id", @wire)
      |> Map.put("runs_page", Map.put(Wire.page(), "request_id", @wire))
      |> Map.put("interactions_page", Map.put(Wire.page(), "request_id", @wire))
      |> Map.put("transcript", Map.put(Wire.page(), "request_id", @wire) |> Map.put("items", []))

    response = %Message{
      version: 1,
      sequence: nil,
      occurred_at: nil,
      type: :response,
      request_id: @wire,
      nonce: @nonce,
      scope: @scope,
      body: %{"op" => "result", "response_kind" => "workspace_snapshot", "value" => value}
    }

    assert {:ok, %Delivery{body: page}} =
             Codec.response(through_json(response), request, @wire, @nonce)

    assert page.request_id == "local-7"
    assert [%DTO.Change{}] = page.changes
    assert [%DTO.Verdict{}] = page.verdicts
  end
end
