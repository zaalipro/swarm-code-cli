defmodule SwarmCodeCLI.UI.DataSource.Pass70WireTest do
  @moduledoc """
  pass70 C1: the DTO and wire additions (approval card facts and decisions,
  conversations, run/agent stop facts, diffs, background commands, rate limits,
  project approval mode and trust, toasts, seen marks) cross real JSON through
  the daemon codec, and an older daemon that omits them still decodes.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire

  @wire "11111111-1111-4111-8111-111111111111"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "33333333-3333-4333-8333-333333333333"
  @node "44444444-4444-4444-8444-444444444444"
  @interaction "55555555-5555-4555-8555-555555555555"
  @provider "66666666-6666-4666-8666-666666666666"
  @nonce String.duplicate("A", 43)
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}
  @global %Scope{kind: :global, id: nil, generation: 2}

  defp through_json(message) do
    {:ok, bytes} = Envelope.encode(message)
    {:ok, decoded} = Envelope.decode(IO.iodata_to_binary(bytes))
    decoded
  end

  defp request(kind, origin, expected, scope \\ @scope),
    do: %Request{
      request_id: "local-1",
      kind: kind,
      scope: scope,
      generation: 2,
      origin: origin,
      deadline: 5_000,
      expected_response: expected
    }

  defp result(kind, value, scope \\ @scope),
    do: %Message{
      version: 1,
      sequence: nil,
      occurred_at: nil,
      type: :response,
      request_id: @wire,
      nonce: @nonce,
      scope: scope,
      body: %{"op" => "result", "response_kind" => kind, "value" => value}
    }

  defp watch(slot, scope),
    do: %Watch{
      watch_ref: "watch-1",
      slot: slot,
      scope: scope,
      generation: 2,
      page_size: 20,
      byte_limit: 262_144
    }

  defp event(scope, sequence, body),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: scope,
      sequence: sequence,
      occurred_at: "2026-09-23T00:00:00Z",
      body: body
    }

  defp delta(kind, entity, body, run, conversation),
    do: %{
      "kind" => kind,
      "entity_id" => entity,
      "run_id" => run,
      "conversation_id" => conversation,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => body,
      "sequence" => 4,
      "revision" => 3
    }

  def approval_wire,
    do: %{
      "tool" => "run_command",
      "permission" => "execute",
      "arguments_preview" => ~s({"command":"ls -la notes"}),
      "arguments_detail_ref" => nil,
      "command" => "ls -la notes",
      "cwd" => ".",
      "reason" => "List the new notes directory.",
      "command_family" => "ls -la",
      "classification" => "safe",
      "agent_id" => @node,
      "agent_name" => "worker-b",
      "requested_at" => 1_788_436_800_000,
      "allowed_decisions" => ["approve", "approve_run", "always_prefix", "deny", "deny_stop"]
    }

  def interaction_wire(approval),
    do: %{
      "id" => @interaction,
      "run_id" => @run,
      "node_id" => @node,
      "conversation_id" => @conversation,
      "kind" => "approval",
      "expected_revision" => 7,
      "state" => "pending",
      "question" => nil,
      "approval" => approval,
      "allowed_actions" => ["approve", "deny"],
      "urgency" => "normal",
      "deadline" => 0,
      "created_at" => 1_788_436_800_000
    }

  describe "requests" do
    test "conversation, project, seen and approval operations encode closed wire bodies" do
      cases = [
        {{:conversation_list, nil, 50, 262_144}, {:conversation, :list}, :conversation_list,
         %{"op" => "conversation.list", "cursor" => nil, "page_size" => 50}},
        {{:conversation_new}, {:conversation, :new}, :outcome, %{"op" => "conversation.new"}},
        {{:conversation_open, @conversation}, {:conversation, :open}, :outcome,
         %{"op" => "conversation.open", "conversation_id" => @conversation}},
        {{:project_update, :full_access, nil}, {:project, :update}, :outcome,
         %{"op" => "project.update", "approval_mode" => "full_access", "trusted" => nil}},
        {{:project_update, nil, true}, {:project, :update}, :outcome,
         %{"op" => "project.update", "approval_mode" => nil, "trusted" => true}},
        {{:mark_seen, :run, @run, 4}, {:seen, :run, @run, 4}, :outcome,
         %{"op" => "mark_seen", "kind" => "run", "id" => @run, "revision" => 4}},
        {{:resolve_approval, @run, @node, @interaction, 7, :deny_stop},
         {:interaction, @interaction, 7}, :outcome,
         %{"op" => "approval.resolve", "decision" => "deny_stop"}}
      ]

      for {kind, origin, expected, fields} <- cases do
        request = request(kind, origin, expected)
        assert {:ok, ^request} = Request.validate(request)
        assert {:ok, message} = Codec.request(request, @wire, @nonce, 1_000)
        assert Map.take(message.body, Map.keys(fields)) == fields
        assert {:ok, _} = ServiceRequest.decode(message.body, @scope)
        assert through_json(message) == message
      end
    end

    test "requests reject mismatched origins, responses and malformed arguments" do
      for {kind, origin, expected} <- [
            {{:conversation_list, nil, 50, 262_144}, {:conversation, :new}, :conversation_list},
            {{:conversation_list, nil, 50, 262_144}, {:conversation, :list}, :outcome},
            {{:conversation_new}, {:conversation, :new}, :conversation_list},
            {{:conversation_open, "opaque"}, {:conversation, :open}, :outcome},
            {{:project_update, nil, nil}, {:project, :update}, :outcome},
            {{:project_update, :ask, nil}, {:project, :update}, :outcome},
            {{:project_update, :auto, false}, {:project, :update}, :outcome},
            {{:resolve_approval, @run, @node, @interaction, 7, :always},
             {:interaction, @interaction, 7}, :outcome}
          ] do
        assert {:error, :invalid_request} = Request.validate(request(kind, origin, expected))
      end
    end

    test "a file query is a feature query over the project index" do
      request =
        request(
          {:feature_query, :files, "lib/rep", nil, 20, 65_536},
          {:feature, :files},
          :library_snapshot
        )

      assert {:ok, message} = Codec.request(request, @wire, @nonce, 1_000)
      assert message.body["feature"] == "files"
      assert message.body["id"] == "lib/rep"
    end
  end

  describe "responses" do
    test "a conversation list page decodes with its summaries" do
      value =
        Map.merge(Wire.page(), %{
          "through_sequence" => 0,
          "request_id" => @wire,
          "project" => "ailogic",
          "current_id" => @conversation,
          "covered_ids" => [@conversation],
          "items" => [
            %{
              "id" => @conversation,
              "title" => "Fix the login flow",
              "created_at" => 1_788_436_000_000,
              "updated_at" => 1_788_436_800_000,
              "run_count" => 3,
              "live" => true,
              "waiting" => 1,
              "unread" => false,
              "current" => true
            }
          ]
        })

      request =
        request(
          {:conversation_list, nil, 50, 262_144},
          {:conversation, :list},
          :conversation_list
        )

      assert {:ok, %Delivery{kind: :response, body: %DTO.ConversationList{} = page}} =
               Codec.response(
                 through_json(result("conversation_list", value)),
                 request,
                 @wire,
                 @nonce
               )

      assert page.request_id == "local-1"
      assert page.current_id == @conversation

      assert [%DTO.ConversationSummary{title: "Fix the login flow", live: true, waiting: 1}] =
               page.items

      two_current =
        Map.put(value, "items", value["items"] ++ [%{hd(value["items"]) | "id" => @run}])

      assert {:error, %AdmissionError{}} =
               Codec.response(result("conversation_list", two_current), request, @wire, @nonce)
    end
  end

  describe "snapshots and deltas" do
    test "a workspace snapshot carries approval facts, mode, trust, gauges and background" do
      background = %{
        "id" => @node,
        "run_id" => @run,
        "agent_id" => nil,
        "pid" => 4242,
        "command" => "mix test --trace",
        "cwd" => ".",
        "state" => "running",
        "exit_code" => nil,
        "started_at" => 1_788_436_790_000,
        "output_bytes" => 512,
        "revision" => 2
      }

      tool =
        Map.merge(Wire.tool_call(), %{
          "name" => "edit_file",
          "added" => 12,
          "removed" => 3,
          "diff_ref" => %{"id" => @node <> ":diff", "total_bytes" => 900},
          "exit_code" => nil,
          "background" => false
        })

      value =
        Wire.workspace()
        |> Map.put("interactions", [interaction_wire(approval_wire())])
        |> Map.put(
          "transcript",
          Map.put(Wire.page(), "items", [%{Wire.transcript_item() | "tool" => tool}])
        )
        |> Map.put("runs", [
          Map.merge(Wire.run_summary(), %{
            "stop_reason" => "turn_budget",
            "error_kind" => nil,
            "stop_label" => "turn limit",
            "provider_name" => "llmotions",
            "retry_at" => nil
          })
        ])
        |> Map.put("changes", [
          Map.merge(Wire.change(), %{
            "op_id" => @node,
            "file_state" => "created",
            "added" => 2,
            "removed" => 0,
            "diff_ref" => %{"id" => "change-1:diff", "total_bytes" => 80}
          })
        ])
        |> Map.merge(%{
          "approval_mode" => "auto",
          "trusted" => false,
          "chat_provider" => "llmotions",
          "context_used" => 18_000,
          "context_window" => 131_072,
          "cost_usd" => 0.21,
          "title" => "Fix the login flow",
          "background" => [background]
        })

      message =
        event(@scope, 9, %{
          "op" => "watch_ready",
          "watch_ref" => "watch-1",
          "revision" => 7,
          "body_kind" => "workspace_snapshot",
          "value" => value
        })

      assert {:ok, %Delivery{kind: :watch_ready, body: page}} =
               Codec.event(through_json(message), watch(:workspace, @scope), @nonce)

      assert {page.approval_mode, page.trusted, page.title} ==
               {:auto, false, "Fix the login flow"}

      assert {page.context_used, page.context_window, page.chat_provider} ==
               {18_000, 131_072, "llmotions"}

      assert [%DTO.BackgroundCommand{state: :running, pid: 4242}] = page.background

      assert [%DTO.PendingInteraction{approval: %DTO.Approval{} = card}] = page.interactions

      assert {card.command, card.command_family, card.classification} ==
               {"ls -la notes", "ls -la", :safe}

      assert card.allowed_decisions == [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
      assert card.agent_name == "worker-b"

      assert [%DTO.RunSummary{stop_reason: "turn_budget", stop_label: "turn limit"}] = page.runs

      assert [%DTO.TranscriptItem{tool: %DTO.ToolCall{added: 12, removed: 3, diff_ref: ref}}] =
               page.transcript.items

      assert ref.id == @node <> ":diff"
      assert [%DTO.Change{file_state: :created, added: 2, op_id: @node}] = page.changes
    end

    test "an older daemon that omits every pass70 key still installs the snapshot" do
      legacy_approval =
        Map.take(approval_wire(), ~w(tool permission arguments_preview arguments_detail_ref))

      value =
        Wire.workspace()
        |> Map.put("interactions", [interaction_wire(legacy_approval)])

      message =
        event(@scope, 9, %{
          "op" => "watch_ready",
          "watch_ref" => "watch-1",
          "revision" => 7,
          "body_kind" => "workspace_snapshot",
          "value" => value
        })

      assert {:ok, %Delivery{body: page}} =
               Codec.event(through_json(message), watch(:workspace, @scope), @nonce)

      assert {page.approval_mode, page.trusted, page.background} == {nil, nil, []}

      assert [%{approval: %DTO.Approval{classification: :unknown, allowed_decisions: []}}] =
               page.interactions
    end

    test "always_prefix without a family is refused" do
      bad = Map.put(approval_wire(), "command_family", nil)
      assert {:error, :invalid_dto} = DTO.Approval.decode(bad)
      assert {:ok, %DTO.Approval{}} = DTO.Approval.decode(approval_wire())
    end

    test "a shell snapshot carries rate limits and the shell watch takes toast and rate deltas" do
      limit = %{
        "provider_id" => @provider,
        "provider" => "llmotions",
        "scope" => "requests",
        "used_percent" => 62,
        "resets_at" => 1_788_436_842_000,
        "retry_at" => 1_788_436_812_000,
        "revision" => 3
      }

      shell =
        Map.merge(Wire.page(), %{
          "runs" => [],
          "connection" => %{"state" => "connected", "source_epoch" => "epoch-1"},
          "counts" => %{
            "running" => 0,
            "waiting" => 0,
            "paused" => 0,
            "failed" => 0,
            "done" => 0,
            "unseen" => 0
          },
          "rate_limits" => [limit]
        })

      ready =
        event(@global, 9, %{
          "op" => "watch_ready",
          "watch_ref" => "watch-1",
          "revision" => 7,
          "body_kind" => "shell_snapshot",
          "value" => shell
        })

      assert {:ok, %Delivery{body: %DTO.ShellSnapshot{rate_limits: [rate]}}} =
               Codec.event(through_json(ready), watch(:shell, @global), @nonce)

      assert rate.used_percent == 62.0

      toast = %{
        "id" => @interaction,
        "level" => "waiting",
        "title" => "Waiting for you",
        "text" => "worker-b wants to run ls -la notes",
        "run_id" => @run,
        "conversation_id" => @run,
        "at" => 1_788_436_800_000,
        "revision" => 3
      }

      for {value, kind} <- [
            {delta("toast", @interaction, toast, @run, @conversation), :toast},
            {delta("rate_limit", @provider, limit, nil, @conversation), :rate_limit}
          ] do
        message =
          event(@global, 10, %{
            "op" => "delta",
            "watch_ref" => "watch-1",
            "value" => %{value | "sequence" => 10}
          })

        assert {:ok, %Delivery{kind: :delta, body: %Delta{kind: ^kind}}} =
                 Codec.event(through_json(message), watch(:shell, @global), @nonce)
      end
    end

    test "background upserts and removals travel with their run" do
      body = %{
        "id" => @node,
        "run_id" => @run,
        "agent_id" => nil,
        "pid" => nil,
        "command" => "npm run dev",
        "cwd" => nil,
        "state" => "exited",
        "exit_code" => 0,
        "started_at" => nil,
        "output_bytes" => 0,
        "revision" => 3
      }

      for value <- [
            delta("background_upsert", @node, body, @run, @conversation),
            delta("background_remove", @node, nil, @run, @conversation)
          ] do
        message = event(@scope, 4, %{"op" => "delta", "watch_ref" => "watch-1", "value" => value})

        assert {:ok, %Delivery{kind: :delta, body: %Delta{}}} =
                 Codec.event(through_json(message), watch(:workspace, @scope), @nonce)
      end

      wrong_run =
        delta(
          "background_upsert",
          @node,
          %{body | "run_id" => @conversation},
          @run,
          @conversation
        )

      assert {:error, :invalid_delta} = Delta.decode(wrong_run)
    end
  end
end
