defmodule SwarmCodeCLI.UI.DataSource.LiveServiceTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request, Watch}

  @epoch "33333333-3333-4333-8333-333333333333"
  @conversation "22222222-2222-4222-8222-222222222222"
  @nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @scope %Scope{kind: :conversation, id: @conversation, generation: 0}

  test "real daemon listener transports fixture backend queries, dispatch and watches" do
    dir = Path.join(System.tmp_dir!(), "swarm-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "daemon.sock")
    on_exit(fn -> File.rm_rf!(dir) end)

    backend =
      start_supervised!(
        {SwarmCodeCLI.ServiceBackendFixture, source_epoch: @epoch, conversation_id: @conversation}
      )

    _service =
      start_supervised!(
        {SwarmCode.Daemon.Service,
         socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: backend}
      )

    client =
      start_supervised!(
        {SwarmCodeCLI.UI.DataSource.Daemon,
         socket_path: path, nonce: @nonce, source_epoch: @epoch}
      )

    assert {:ok, "live-bind"} = DataSource.bind_owner(client, self(), "live-bind")

    query = %Request{
      request_id: "query-1",
      kind: {:query, :workspace, nil, :after, 20, 65_536},
      scope: @scope,
      generation: 0,
      origin: {:query, :workspace},
      deadline: System.monotonic_time(:millisecond) + 2_000,
      expected_response: :workspace_snapshot
    }

    assert :ok = DataSource.query(client, query)

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %{body: %DTO.WorkspaceSnapshot{conversation_id: @conversation}}},
                   2_000

    assert :ok = DataSource.consume(client, receipt, :applied)

    command = %Request{
      request_id: "dispatch-1",
      kind: {:dispatch, :send, "inspect the project", :main, []},
      scope: @scope,
      generation: 0,
      origin: {:draft, {@conversation, :main}},
      deadline: System.monotonic_time(:millisecond) + 2_000,
      expected_response: :outcome
    }

    assert :ok = DataSource.command(client, command)

    assert_receive {:swarm_code_ui_data, @epoch, command_receipt,
                    %{body: %DTO.Outcome{status: :accepted}}},
                   2_000

    assert :ok = DataSource.consume(client, command_receipt, :applied)

    watch = %Watch{
      watch_ref: "live-workspace",
      slot: :workspace,
      scope: @scope,
      generation: 0,
      page_size: 20,
      byte_limit: 65_536
    }

    assert :ok = DataSource.watch(client, watch)

    assert_receive {:swarm_code_ui_data, @epoch, watch_receipt,
                    %{kind: :watch_ready, body: %DTO.WorkspaceSnapshot{}}},
                   2_000

    assert :ok = DataSource.consume(client, watch_receipt, :applied)

    run_scope = %Scope{kind: :run, id: "33333333-3333-4333-8333-333333333333", generation: 1}
    run_watch = %{watch | watch_ref: "live-run", scope: run_scope, generation: 1}
    assert :ok = DataSource.watch(client, run_watch)

    assert_receive {:swarm_code_ui_data, @epoch, run_watch_receipt,
                    %{kind: :watch_ready, body: %DTO.RunDetailSnapshot{}}},
                   2_000

    assert :ok = DataSource.consume(client, run_watch_receipt, :applied)

    run_query = %{
      query
      | request_id: "run-query",
        kind: {:query, :workspace, nil, :after, 20, 65_536},
        scope: run_scope,
        generation: 1
    }

    assert :ok = DataSource.query(client, run_query)

    assert_receive {:swarm_code_ui_data, @epoch, run_query_receipt,
                    %{body: %DTO.RunDetailSnapshot{}}},
                   2_000

    assert :ok = DataSource.consume(client, run_query_receipt, :applied)
    assert :ok = DataSource.close(client)
  end
end
