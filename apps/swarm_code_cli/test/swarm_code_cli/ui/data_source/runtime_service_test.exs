defmodule SwarmCodeCLI.UI.DataSource.RuntimeServiceTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service
  alias SwarmCode.Daemon.Service.LiveBackend
  alias SwarmCode.Protocol.Scope
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{Daemon, Delta, DTO, Request, Watch}

  @conversation "22222222-2222-4222-8222-222222222222"
  @epoch "33333333-3333-4333-8333-333333333333"
  @project "44444444-4444-4444-8444-444444444444"
  @nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @scope %Scope{kind: :conversation, id: @conversation, generation: 0}

  test "socket session approves real edits and tests, then reconnects to its completed transcript" do
    root = Path.join("/tmp", "sc-accept-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    owner = self()

    server =
      HTTP.start(fn socket, request, turn ->
        body = Jason.decode!(request.body)

        case turn do
          1 ->
            assert List.last(body["messages"])["content"] == "Write and test answer.txt"

            tool(socket, "write-answer", "write_file", %{
              "path" => "answer.txt",
              "content" => "42\n"
            })

          2 ->
            assert Enum.any?(
                     body["messages"],
                     &(&1["role"] == "tool" and String.contains?(&1["content"], "wrote"))
                   )

            tool(socket, "test-answer", "run_command", %{
              "command" => "printf '42\\n' | cmp - answer.txt && printf verified"
            })

          3 ->
            assert Enum.any?(
                     body["messages"],
                     &(&1["role"] == "tool" and String.contains?(&1["content"], "verified"))
                   )

            HTTP.stream(socket, [
              HTTP.sse(%{
                "choices" => [
                  %{"delta" => %{"content" => "Verified answer.txt."}, "finish_reason" => "stop"}
                ]
              })
            ])

            send(owner, :provider_completed)
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Provider.new(
        name: "acceptance",
        base_url: server.url,
        api_key: "fixture",
        default_model: "fixture"
      )

    backend =
      start_supervised!(
        {LiveBackend,
         mode: :transient,
         provider: provider,
         project_root: root,
         project_id: @project,
         conversation_id: @conversation,
         source_epoch: @epoch,
         approval: :ask}
      )

    path = Path.join(root, "daemon.sock")

    start_supervised!(
      {Service, socket_path: path, backend: backend, nonce: @nonce, source_epoch: @epoch}
    )

    client = start_supervised!({Daemon, socket_path: path, nonce: @nonce, source_epoch: @epoch})
    assert {:ok, "owner-1"} = DataSource.bind_owner(client, self(), "owner-1")

    assert :ok =
             DataSource.watch(client, %Watch{
               watch_ref: "workspace",
               slot: :workspace,
               scope: @scope,
               generation: 0,
               page_size: 20,
               byte_limit: 262_144
             })

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %{kind: :watch_ready, body: %DTO.WorkspaceSnapshot{}}},
                   5_000

    assert :ok = DataSource.consume(client, receipt, :applied)

    assert :ok =
             DataSource.command(
               client,
               request(
                 "send",
                 {:dispatch, :send, "Write and test answer.txt", :main, []},
                 {:draft, {@conversation, :main}}
               )
             )

    facts =
      collect(
        client,
        %{approved: MapSet.new(), tools: [], run: nil, final: nil, root: root},
        System.monotonic_time(:millisecond) + 15_000
      )

    assert MapSet.size(facts.approved) == 2
    assert File.read!(Path.join(root, "answer.txt")) == "42\n"
    assert Enum.any?(facts.tools, &String.contains?(&1, "verified"))
    assert facts.final == "Verified answer.txt."
    assert_receive :provider_completed
    assert :ok = DataSource.close(client)

    # A new socket/client recovers daemon-owned state; this is reconnect evidence,
    # not daemon restart/persistence evidence.
    again =
      start_supervised!({Daemon, socket_path: path, nonce: @nonce, source_epoch: @epoch},
        id: :reconnected
      )

    assert {:ok, "owner-2"} = DataSource.bind_owner(again, self(), "owner-2")

    query = %{
      request("history", {:query, :workspace, nil, :after, 20, 262_144}, {:query, :workspace})
      | expected_response: :workspace_snapshot
    }

    assert :ok = DataSource.query(again, query)

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %{body: %DTO.WorkspaceSnapshot{} = snapshot}},
                   5_000

    assert Enum.any?(snapshot.runs, &(&1.id == facts.run and &1.state == :done))
    assert Enum.any?(snapshot.transcript.items, &(&1.text == "Verified answer.txt."))
    assert :ok = DataSource.consume(again, receipt, :applied)
    DataSource.close(again)
  end

  defp collect(client, facts, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:swarm_code_ui_data, @epoch, receipt, %{body: body}} ->
        assert :ok = DataSource.consume(client, receipt, :applied)

        case body do
          %DTO.Outcome{status: :accepted} ->
            collect(client, facts, deadline)

          %DTO.Outcome{} = rejected ->
            flunk("command failed: #{inspect(rejected)}")

          %Delta{kind: :interaction_upsert, body: %DTO.PendingInteraction{} = pending} ->
            unless MapSet.member?(facts.approved, pending.id) do
              if pending.approval.tool == "write_file",
                do: refute(File.exists?(Path.join(facts.root, "answer.txt")))

              intent =
                {:resolve_approval, pending.run_id, pending.node_id, pending.id,
                 pending.expected_revision, :approve}

              assert :ok =
                       DataSource.command(
                         client,
                         request(
                           "approve-" <> pending.id,
                           intent,
                           {:interaction, pending.id, pending.expected_revision}
                         )
                       )
            end

            collect(client, %{facts | approved: MapSet.put(facts.approved, pending.id)}, deadline)

          %Delta{kind: :node_upsert, body: %DTO.TranscriptItem{role: :tool, text: text}} ->
            collect(client, %{facts | tools: [text | facts.tools]}, deadline)

          %Delta{kind: :node_upsert, body: %DTO.TranscriptItem{role: :assistant, text: text}} ->
            collect(client, %{facts | final: text}, deadline)

          %Delta{kind: :run_update, body: %DTO.RunSummary{state: :done, id: id}} ->
            %{facts | run: id}

          %Delta{} ->
            collect(client, facts, deadline)

          other ->
            flunk("unexpected payload: #{inspect(other)}")
        end

      {:swarm_code_ui_closed, ^client, @epoch} ->
        flunk("live socket closed before completion")
    after
      timeout -> flunk("live run did not complete")
    end
  end

  defp request(id, kind, origin),
    do: %Request{
      request_id: id,
      kind: kind,
      scope: @scope,
      generation: 0,
      origin: origin,
      deadline: System.system_time(:millisecond) + 5_000,
      expected_response: :outcome
    }

  defp tool(socket, id, name, args),
    do:
      HTTP.stream(socket, [
        HTTP.sse(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => id,
                    "type" => "function",
                    "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        })
      ])
end
