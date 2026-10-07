defmodule SwarmCodeCLI.UI.DataSource.C020WireTest do
  @moduledoc """
  cli020 lane C: the client half of the new requests. Each intent validates
  with its bounds, becomes a request scoped to its conversation, encodes to the
  op the service decodes, and the new workspace fields decode (and default when
  an older daemon omits them).
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.{Intent, RequestResolver}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec

  @conversation "22222222-2222-4222-8222-222222222222"
  @other "77777777-7777-4777-8777-777777777777"
  @nonce String.duplicate("A", 43)
  @wire "11111111-1111-4111-8111-111111111111"
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}

  defp command(intent, scope \\ @scope),
    do: Request.conversation_command(intent, scope, "local-1", 5_000)

  defp body(intent) do
    {:ok, request} = command(intent)
    {:ok, message} = Codec.request(request, @wire, @nonce, 0)
    assert {:ok, _} = ServiceRequest.decode(message.body, @scope)
    Map.drop(message.body, ["timeout_ms"])
  end

  describe "C1 the queue" do
    test "queue.resume and queue.edit encode to the service's ops" do
      assert body({:queue_resume, @conversation}) == %{"op" => "queue.resume"}

      assert body({:queue_edit, @conversation, "0123456789abcdef", {:drop, 2}}) == %{
               "op" => "queue.edit",
               "revision" => "0123456789abcdef",
               "action" => "drop",
               "position" => 2
             }

      assert %{"action" => "clear", "position" => nil} =
               body({:queue_edit, @conversation, "0123456789abcdef", :clear})
    end

    test "the bounds and the scope are checked" do
      refute Intent.valid?({:queue_edit, @conversation, "XYZ", :clear})
      refute Intent.valid?({:queue_edit, @conversation, "0123456789abcdef", {:drop, 0}})
      refute Intent.valid?({:queue_resume, "not-a-uuid"})
      assert {:error, :invalid_request} = command({:queue_resume, @other})
    end

    test "the resolver admits a queue command from its conversation origin" do
      {:ok, context} =
        RequestResolver.Context.validate(%RequestResolver.Context{
          scope: @scope,
          scope_generation: 2,
          origin: {:conversation, :queue},
          active_run_id: nil,
          active_run_state: nil,
          active_node_id: nil,
          active_agent_id: nil,
          subject_revision: nil,
          interaction: nil,
          editor_text: "",
          dispatch_target: :main,
          attachment_refs: [],
          allowed_actions: [:send, :queue]
        })

      assert {:ok, %Request{origin: {:conversation, :queue}}} =
               RequestResolver.resolve({:queue_resume, @conversation}, context, "r-1", 5_000)

      assert {:error, :not_allowed} =
               RequestResolver.resolve(
                 {:queue_resume, @conversation},
                 %{context | allowed_actions: [:send]},
                 "r-2",
                 5_000
               )
    end

    test "the workspace carries the queue facts and an older daemon defaults them" do
      {:ok, meta} =
        DTO.WorkspaceMetadata.decode(%{
          "conversation_id" => @conversation,
          "mode" => "build",
          "chat_model" => nil,
          "swarm_model" => nil,
          "effort" => nil,
          "swarm_effort" => nil,
          "queued_count" => 2,
          "queue_paused" => true,
          "queue_revision" => "0123456789abcdef"
        })

      assert {meta.queued_count, meta.queue_paused, meta.queue_revision} ==
               {2, true, "0123456789abcdef"}

      {:ok, old} =
        DTO.WorkspaceMetadata.decode(%{
          "conversation_id" => @conversation,
          "mode" => "build",
          "chat_model" => nil,
          "swarm_model" => nil,
          "effort" => nil,
          "swarm_effort" => nil
        })

      assert {old.queued_count, old.queue_paused, old.queue_revision} == {0, false, nil}
    end
  end

  describe "C6 run.retry" do
    test "{:retry_run, run, revision} encodes to run.retry" do
      run = "33333333-3333-4333-8333-333333333333"

      request = %Request{
        request_id: "local-2",
        kind: {:retry_run, run, 7},
        scope: @scope,
        generation: 2,
        origin: {:run_revision, run, 7},
        deadline: 5_000,
        expected_response: :outcome
      }

      {:ok, message} = Codec.request(request, @wire, @nonce, 0)

      assert {:ok, %ServiceRequest{operation: :run_retry}} =
               ServiceRequest.decode(message.body, @scope)

      assert Map.drop(message.body, ["timeout_ms"]) == %{
               "op" => "run.retry",
               "run_id" => run,
               "revision" => 7
             }
    end
  end

  describe "C14 clipboard slots" do
    test "the two ops encode and their answers decode" do
      token = String.duplicate("ab", 16)
      assert body({:attachment_slot, @conversation}) == %{"op" => "attachment.slot"}

      assert body({:attach_slot, @conversation, token}) == %{
               "op" => "attachment.attach_slot",
               "token" => token
             }

      refute Intent.valid?({:attach_slot, @conversation, "../../etc/passwd"})

      {:ok, outcome} =
        DTO.Outcome.decode(%{
          "status" => "accepted",
          "request_id" => "local-1",
          "identifiers" => [],
          "interaction" => nil,
          "feedback" => nil,
          "error" => nil,
          "corrective_action" => "none",
          "result" => %{
            "kind" => "attachment",
            "attachment" => %{
              "id" => @other,
              "name" => "clipboard-120000.png",
              "mime" => "image/png",
              "bytes" => 10
            }
          }
        })

      assert outcome.result.attachment.bytes == 10
    end
  end

  describe "C15 the shell escape" do
    test "shell.run and shell.stop encode; bounds are checked" do
      assert body({:shell_run, @conversation, "ls -la"}) == %{
               "op" => "shell.run",
               "command" => "ls -la"
             }

      assert body({:shell_stop, @conversation}) == %{"op" => "shell.stop"}
      refute Intent.valid?({:shell_run, @conversation, ""})
      refute Intent.valid?({:shell_run, @conversation, "a" <> <<0>>})
      refute Intent.valid?({:shell_run, @conversation, String.duplicate("x", 4097)})
    end
  end

  describe "C16 rewind" do
    test "rewind.turns and rewind.apply encode" do
      assert body({:rewind_turns, @conversation}) == %{"op" => "rewind.turns"}

      assert body({:rewind_apply, @conversation, @other, :conversation}) == %{
               "op" => "rewind.apply",
               "message_id" => @other,
               "scope" => "conversation"
             }

      refute Intent.valid?({:rewind_apply, @conversation, @other, :everything})
    end
  end

  describe "C20 history" do
    test "history.search encodes; the query is bounded" do
      assert body({:history_search, @conversation, "dep"}) == %{
               "op" => "history.search",
               "query" => "dep"
             }

      assert body({:history_search, @conversation, ""}) == %{
               "op" => "history.search",
               "query" => ""
             }

      refute Intent.valid?({:history_search, @conversation, String.duplicate("q", 201)})
    end
  end
end
