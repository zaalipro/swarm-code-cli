defmodule SwarmCodeCLI.UI.DataSource.Daemon.WatchCodecTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delta, Delivery, DTO, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec

  @wire "11111111-1111-4111-8111-111111111111"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "33333333-3333-4333-8333-333333333333"
  @nonce String.duplicate("A", 43)
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}

  test "watch request carries bounded page admission through the real JSON protocol" do
    assert {:ok, message} = Codec.watch_request(watch(), @wire, @nonce, 5_000)
    assert {:ok, decoded} = Envelope.decode(json(message))
    assert decoded.request_id == @wire

    assert {:ok, %ServiceRequest{operation: :watch, timeout_ms: 5_000}} =
             ServiceRequest.decode(decoded.body, decoded.scope)

    assert decoded.body["watch_ref"] == "workspace-1"
    assert decoded.body["page_size"] == 20
    assert decoded.body["byte_limit"] == 65_536

    for invalid <- [%{watch() | slot: :inspector}, Map.put(watch(), :extra, 1)] do
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.watch_request(invalid, @wire, @nonce, 5_000)
    end

    for ttl <- [0, 600_001, nil] do
      assert {:error, %AdmissionError{}} = Codec.watch_request(watch(), @wire, @nonce, ttl)
    end
  end

  test "run workspace watch is admitted as inspector and decodes run detail snapshot" do
    run_watch = %{watch() | scope: %{@scope | kind: :run, id: @run}}
    assert {:ok, message} = Codec.watch_request(run_watch, @wire, @nonce, 5_000)
    assert message.body["slot"] == "inspector"

    assert {:ok, %ServiceRequest{operation: :watch}} =
             ServiceRequest.decode(message.body, message.scope)

    assert run_watch.scope.kind == :run
  end

  test "initial snapshot supplies its watermark while the delivery has no delta sequence" do
    message = ready()
    assert {:ok, message} = Envelope.decode(json(message))
    assert {:ok, %Delivery{kind: :watch_ready} = delivery} = Codec.event(message, watch(), @nonce)
    assert delivery.watch_ref == "workspace-1"
    assert delivery.request_id == nil
    assert delivery.sequence == nil
    assert delivery.revision == 7
    assert delivery.scope == @scope
    assert delivery.body.through_sequence == 9
    assert delivery.body.transcript.through_sequence == 9
    assert {:ok, ^delivery} = Delivery.validate(delivery)
  end

  test "snapshot refuses another watch, epoch nonce, generation, body scope or watermark" do
    message = ready()

    for invalid <- [
          %{message | nonce: String.duplicate("B", 43)},
          %{message | request_id: @wire},
          %{message | scope: %{@scope | generation: 3}},
          %{message | sequence: 10},
          %{message | body: Map.put(message.body, "watch_ref", "another")},
          %{message | body: Map.put(message.body, "body_kind", "shell_snapshot")},
          %{message | body: Map.put(message.body, "revision", 8)},
          %{message | body: put_in(message.body["value"]["conversation_id"], @wire)},
          %{message | body: put_in(message.body["value"]["transcript"]["through_sequence"], 8)},
          %{message | body: put_in(message.body["value"]["runs_page"]["request_id"], @wire)}
        ] do
      assert {:error, %AdmissionError{code: :invalid_request}} =
               Codec.event(invalid, watch(), @nonce)
    end
  end

  test "watch snapshots enforce explicit nested fields and encoded page budget" do
    message = ready()

    invalid = %{
      message
      | body: update_in(message.body["value"], &Map.delete(&1, "allowed_actions"))
    }

    assert {:error, %AdmissionError{}} = Codec.event(invalid, watch(), @nonce)

    invalid = %{
      message
      | body: update_in(message.body["value"]["transcript"], &Map.delete(&1, "request_id"))
    }

    assert {:error, %AdmissionError{}} = Codec.event(invalid, watch(), @nonce)
    assert {:error, %AdmissionError{}} = Codec.event(message, %{watch() | byte_limit: 50}, @nonce)
  end

  test "stream delta restores typed enums and retains actual operation identity" do
    message = event(%{"op" => "delta", "watch_ref" => "workspace-1", "value" => delta()})
    assert {:ok, message} = Envelope.decode(json(message))

    assert {:ok, %Delivery{kind: :delta, sequence: 10, revision: 2, body: body}} =
             Codec.event(message, watch(), @nonce)

    assert %Delta{kind: :stream_append, channel: :text, text: "Hello 🙂", run_id: @run} = body
    assert body.attempt_id == "operation-1"
    assert {:ok, ^body} = Delta.validate(body)

    for value <- [
          Map.put(delta(), "kind", "invented"),
          Map.put(delta(), "channel", "other"),
          Map.put(delta(), "sequence", 11),
          Map.put(delta(), "conversation_id", @wire),
          Map.put(delta(), "attempt_id", nil),
          Map.delete(delta(), "body"),
          Map.put(delta(), "extra", true)
        ] do
      assert {:error, %AdmissionError{}} =
               Codec.event(
                 %{message | body: Map.put(message.body, "value", value)},
                 watch(),
                 @nonce
               )
    end
  end

  test "run updates decode the closed DTO selected by kind and preserve unknown progress" do
    value = %{
      delta()
      | "kind" => "run_update",
        "entity_id" => @run,
        "attempt_id" => nil,
        "text" => nil,
        "channel" => nil,
        "body" => run()
    }

    message = event(%{"op" => "delta", "watch_ref" => "workspace-1", "value" => value})

    assert {:ok, %Delivery{body: %Delta{body: %DTO.RunSummary{progress: nil, state: :running}}}} =
             Codec.event(message, watch(), @nonce)

    for invalid <- [
          put_in(value["body"]["id"], @wire),
          put_in(value["body"]["revision"], 3),
          update_in(value["body"], &Map.delete(&1, "created_sequence"))
        ] do
      assert {:error, %AdmissionError{}} =
               Codec.event(
                 %{message | body: Map.put(message.body, "value", invalid)},
                 watch(),
                 @nonce
               )
    end
  end

  test "overflow is a correlated resync signal with closed reasons, never an ordinary delta" do
    message = %{
      event(%{"op" => "snapshot_required", "watch_ref" => "workspace-1", "reason" => "overflow"})
      | type: :snapshot_required
    }

    for reason <- ["overflow", "gap", "epoch_changed"] do
      assert {:ok, %Delivery{kind: :resyncing, body: nil, revision: nil, sequence: nil}} =
               Codec.event(
                 %{message | body: Map.put(message.body, "reason", reason)},
                 watch(),
                 @nonce
               )
    end

    for invalid <- [
          %{message | sequence: nil},
          %{message | body: Map.put(message.body, "reason", "secret diagnostic")},
          %{message | body: Map.put(message.body, "extra", true)}
        ] do
      assert {:error, %AdmissionError{}} = Codec.event(invalid, watch(), @nonce)
    end
  end

  test "populated project watches rely on the correlated project scope for server-owned membership" do
    counts = %{
      "running" => 1,
      "waiting" => 0,
      "paused" => 0,
      "failed" => 0,
      "done" => 0,
      "unseen" => 0
    }

    shell =
      Map.merge(page(), %{
        "runs" => [run()],
        "counts" => counts,
        "connection" => %{"state" => "connected", "source_epoch" => "daemon-1"}
      })

    activity =
      Map.merge(page(), %{
        "counts" => counts,
        "items" => [
          %{
            "id" => "activity-1",
            "run_id" => @run,
            "conversation_id" => @conversation,
            "kind" => "running",
            "state" => "running",
            "title" => "Fix test",
            "revision" => 2,
            "seen_revision" => 0,
            "allowed_actions" => [],
            "interaction" => nil,
            "deadline" => nil,
            "created_at" => 1
          }
        ]
      })

    for {slot, kind, value} <- [
          {:shell, "shell_snapshot", shell},
          {:activity, "activity_snapshot", activity}
        ] do
      watch = %{watch() | slot: slot, scope: %{@scope | kind: :project, id: @wire}}
      assert {:ok, _} = Codec.watch_request(watch, @wire, @nonce, 5_000)

      message = %{
        ready()
        | scope: watch.scope,
          body: %{
            "op" => "watch_ready",
            "watch_ref" => watch.watch_ref,
            "revision" => 7,
            "body_kind" => kind,
            "value" => value
          }
      }

      assert {:ok, %Delivery{kind: :watch_ready}} = Codec.event(message, watch, @nonce)

      assert {:error, %AdmissionError{}} =
               Codec.event(%{message | scope: %{watch.scope | id: @run}}, watch, @nonce)
    end
  end

  test "delta wire decoding refuses runtime structs and other malformed containers without raising" do
    for invalid <- [%Delta{}, %DTO.RunSummary{}, nil, [], :stream_append] do
      assert {:error, _} = Delta.decode(invalid)
    end
  end

  defp watch,
    do: %Watch{
      watch_ref: "workspace-1",
      slot: :workspace,
      scope: @scope,
      generation: 2,
      page_size: 20,
      byte_limit: 65_536
    }

  defp json(message) do
    {:ok, bytes} = Envelope.encode(message)
    IO.iodata_to_binary(bytes)
  end

  defp event(body),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: 10,
      occurred_at: "2026-09-07T00:00:00Z",
      body: body
    }

  defp ready,
    do: %{
      event(%{
        "op" => "watch_ready",
        "watch_ref" => "workspace-1",
        "revision" => 7,
        "body_kind" => "workspace_snapshot",
        "value" => workspace()
      })
      | sequence: 9
    }

  defp page,
    do: %{
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => nil,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => [],
      "through_sequence" => 9
    }

  defp workspace,
    do:
      Map.merge(page(), %{
        "allowed_actions" => ["send"],
        "revision" => 7,
        "seen_revision" => 0,
        "runs_page" => page(),
        "interactions_page" => page(),
        "conversation_id" => @conversation,
        "runs" => [],
        "interactions" => [],
        "transcript" => Map.put(page(), "items", [])
      })

  defp delta,
    do: %{
      "kind" => "stream_append",
      "entity_id" => "message-1",
      "run_id" => @run,
      "conversation_id" => @conversation,
      "channel" => "text",
      "attempt_id" => "operation-1",
      "text" => "Hello 🙂",
      "body" => nil,
      "sequence" => 10,
      "revision" => 2
    }

  defp run,
    do: %{
      "created_sequence" => 1,
      "parent_run_id" => nil,
      "seen_revision" => 0,
      "id" => @run,
      "conversation_id" => @conversation,
      "kind" => "chat",
      "title" => "Fix the test",
      "revision" => 2,
      "state" => "running",
      "allowed_actions" => ["pause", "stop"],
      "progress" => nil
    }
end
