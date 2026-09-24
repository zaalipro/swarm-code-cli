defmodule SwarmCodeCLI.UI.DataSource.DaemonTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Protocol.{Frame, FrameDecoder, Message, Scope, ServiceHandshake}
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Delivery, Request, Watch}

  @epoch "33333333-3333-4333-8333-333333333333"
  @connection "44444444-4444-4444-8444-444444444444"
  @nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @scope %Scope{kind: :conversation, id: "22222222-2222-4222-8222-222222222222", generation: 0}

  test "bind performs hello over a real local socket before admitting the owner" do
    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)

    assert {:ok, client} =
             SwarmCodeCLI.UI.DataSource.Daemon.start_link(
               socket_path: path,
               nonce: @nonce,
               source_epoch: @epoch,
               timeout: 1_000
             )

    owner = self()
    assert {:ok, "bind-1"} = DataSource.bind_owner(client, owner, "bind-1")
    assert_receive {:hello, ^server, %Message{type: :hello, body: body}}
    assert body == %{"op" => "hello", "client" => "swarm-code-cli", "body_version" => 1}

    assert :ok = DataSource.close(client)
  end

  test "watch delivery receives an owner receipt and ACK is emitted only after consume" do
    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    assert {:ok, "bind-1"} = DataSource.bind_owner(client, self(), "bind-1")

    watch = %Watch{
      watch_ref: "workspace-1",
      slot: :workspace,
      scope: @scope,
      generation: 0,
      page_size: 1,
      byte_limit: 65_536
    }

    assert :ok = DataSource.watch(client, watch)
    assert_receive {:request, ^server, %Message{body: %{"op" => "watch"}}}
    assert_receive {:swarm_code_ui_data, @epoch, receipt, %Delivery{kind: :watch_ready}}
    refute_receive {:ack, _, _}, 20
    assert :ok = DataSource.consume(client, receipt, :applied)

    assert_receive {:swarm_code_ui_data, @epoch, delta_receipt,
                    %Delivery{kind: :delta, sequence: 2}}

    refute_receive {:ack, _, _}, 20
    assert :ok = DataSource.consume(client, delta_receipt, :applied)
    assert_receive {:ack, ^server, %Message{body: %{"op" => "ack", "sequence" => 2}}}
    assert is_reference(receipt)
    assert :ok = DataSource.close(client)
  end

  test "owner death closes the socket and never ACKs outstanding receipts" do
    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    test = self()

    owner =
      spawn(fn ->
        result = DataSource.bind_owner(client, self(), "bind-1")
        send(test, {:owner_bound, self(), result})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owner_bound, ^owner, {:ok, "bind-1"}}, 2_000
    Process.exit(owner, :kill)
    assert_receive {:peer_closed, ^server}, 2_000
    refute_receive {:ack, _, _}, 20
    assert :ok = DataSource.close(client)
  end

  test "invalid bind reference refuses before opening a connection" do
    path = socket_path!()
    {listener, _server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    assert {:error, _} = DataSource.bind_owner(client, self(), String.duplicate("x", 257))
    assert :ok = DataSource.close(client)
  end

  test "query crosses the socket and restores local identity in the returned page" do
    {client, server} = connected!()
    request = query_request("local-query")
    assert :ok = DataSource.query(client, request)
    assert_receive {:request, ^server, %Message{body: %{"op" => "query"}} = wire}, 2_000
    assert wire.request_id != request.request_id
    assert wire.body["timeout_ms"] > 0 and wire.body["timeout_ms"] <= 2_000

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{
                      request_id: "local-query",
                      body: %DTO.TranscriptWindow{request_id: "local-query"}
                    }},
                   2_000

    assert :ok = DataSource.consume(client, receipt, :applied)
    assert :ok = DataSource.close(client)
  end

  test "command outcome is correlated and duplicate local identity cannot dispatch twice" do
    {client, server} = connected!()
    request = command_request("command-1", "fix")
    assert :ok = DataSource.command(client, request)
    assert_receive {:request, ^server, %Message{body: %{"op" => "dispatch"}}}, 2_000

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{
                      body: %DTO.Outcome{
                        status: :accepted,
                        request_id: "command-1",
                        identifiers: [@connection]
                      }
                    }},
                   2_000

    assert :ok = DataSource.consume(client, receipt, :applied)

    assert {:error, %AdmissionError{code: :request_conflict}} =
             DataSource.command(client, request)

    refute_receive {:request, ^server, %Message{body: %{"op" => "dispatch"}}}, 30
    assert :ok = DataSource.close(client)
  end

  test "a retried local command keeps its wire identity across connections" do
    {first, server_a} = connected!()
    {second, server_b} = connected!()
    assert :ok = DataSource.command(first, command_request("durable-command", "fix"))
    assert_receive {:request, ^server_a, %Message{body: %{"op" => "dispatch"}} = a}, 1000
    assert :ok = DataSource.command(second, command_request("durable-command", "fix"))
    assert_receive {:request, ^server_b, %Message{body: %{"op" => "dispatch"}} = b}, 1000
    assert a.request_id == b.request_id
    assert :ok = DataSource.close(first)
    assert :ok = DataSource.close(second)
  end

  test "a new session never reuses an earlier session's wire identity" do
    # The daemon's command ledger is durable and keyed by the wire id alone. The
    # plain CLI numbers its requests per session, so without the epoch in the
    # hash its third request landed on the previous session's ledger row: the
    # same text replayed that session's "accepted" with nothing executed, and a
    # different text was rejected as a conflict.
    later = "55555555-5555-4555-8555-555555555555"
    {first, server_a} = connected!()
    {second, server_b} = connected!(later)
    assert :ok = DataSource.command(first, command_request("plain-request-3", "fix"))
    assert_receive {:request, ^server_a, %Message{body: %{"op" => "dispatch"}} = a}, 1000
    assert :ok = DataSource.command(second, command_request("plain-request-3", "fix"))
    assert_receive {:request, ^server_b, %Message{body: %{"op" => "dispatch"}} = b}, 1000
    assert a.request_id != b.request_id
    assert :ok = DataSource.close(first)
    assert :ok = DataSource.close(second)
  end

  test "disconnect after command write produces unknown outcome instead of rejection" do
    {client, server} = connected!()
    assert :ok = DataSource.command(client, command_request("uncertain", "disconnect"))
    assert_receive {:request, ^server, %Message{body: %{"op" => "dispatch"}}}, 2_000

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{
                      body: %DTO.Outcome{request_id: "uncertain", status: :outcome_unknown}
                    }},
                   2_000

    assert :ok = DataSource.consume(client, receipt, :applied)

    assert {:error, %AdmissionError{code: :closed}} =
             DataSource.command(client, command_request("new", "fix"))
  end

  test "an expired wall-clock deadline refuses without a wire request" do
    {client, server} = connected!()
    request = %{query_request("expired") | deadline: System.system_time(:millisecond) - 1}
    assert {:error, %AdmissionError{code: :deadline_expired}} = DataSource.query(client, request)
    refute_receive {:request, ^server, _}, 30
    assert :ok = DataSource.close(client)
  end

  test "real TUI owner applies socket snapshots before returning delivery credit" do
    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    alias SwarmCodeCLI.UI.{SessionRuntime, Size, Capabilities, Init}
    size = %Size{columns: 120, rows: 40}
    caps = %Capabilities{size: size}

    runtime =
      start_supervised!(
        {SessionRuntime,
         data_source: client,
         frame_ms: 60_000,
         init: %Init{
           size: size,
           capabilities: caps,
           source_epoch: @epoch,
           destination: {:conversation, @scope.id}
         }}
      )

    assert {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)

    assert_receive {:ack, ^server,
                    %Message{
                      scope: %Scope{kind: :conversation},
                      body: %{"op" => "ack", "sequence" => 2}
                    }},
                   2_000

    ui = SessionRuntime.snapshot(runtime)
    assert ui.read_model.snapshots[:workspace].conversation_id == @scope.id
    assert ui.read_model.snapshots[:shell].counts.running == 3
    assert :ok = DataSource.close(client)
  end

  test "plain owner consumes socket deliveries after presenter output and reaches ready" do
    path = socket_path!()
    {listener, _server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    alias SwarmCodeCLI.Plain.{Options, Session}
    input = start_supervised!(SwarmCodeCLI.Demo.FiniteInput)
    {:ok, output} = StringIO.open("")

    session =
      start_supervised!(
        {Session,
         options: %Options{},
         data_source: client,
         input: input,
         output: output,
         error: output,
         source_epoch: @epoch,
         conversation_id: @scope.id,
         now: 0,
         observer: self()}
      )

    assert_receive {:plain_session, ^session, :ready}, 2_000
    assert Session.snapshot(session).presenter != nil
    assert :ok = Session.close(session, :detach)
  end

  test "a timed-out command returns unknown outcome and late response cannot settle it twice" do
    {client, server} = connected!()

    request = %{
      command_request("timed-out", "hold")
      | deadline: System.system_time(:millisecond) + 80
    }

    assert :ok = DataSource.command(client, request)
    assert_receive {:request, ^server, %Message{body: %{"op" => "dispatch"}}}, 1_000

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{
                      body: %DTO.Outcome{request_id: "timed-out", status: :outcome_unknown}
                    }},
                   1_000

    assert :ok = DataSource.consume(client, receipt, :applied)

    assert {:error, %AdmissionError{code: :request_conflict}} =
             DataSource.command(client, %{
               request
               | deadline: System.system_time(:millisecond) + 1_000
             })

    assert :ok = DataSource.close(client)
  end

  # pass71 S1: producers stamp deadlines with the wall clock (`state.now`); the
  # source used to compare them with the monotonic clock, so no request ever
  # expired. One injected clock drives both sides here.
  test "a deadline fires on the monotonic clock and a late reply is ignored" do
    clock = start_supervised!({Agent, fn -> %{system: 1_790_000_000_000, monotonic: -5_000} end})
    tick = fn kind -> Agent.get(clock, &Map.fetch!(&1, kind)) end
    advance = fn kind, ms -> Agent.update(clock, &Map.update!(&1, kind, fn v -> v + ms end)) end

    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)

    {:ok, client} =
      SwarmCodeCLI.UI.DataSource.Daemon.start_link(
        socket_path: path,
        nonce: @nonce,
        source_epoch: @epoch,
        timeout: 1_000,
        clock: tick
      )

    assert {:ok, "bind-1"} = DataSource.bind_owner(client, self(), "bind-1")

    request = %{command_request("late-1", "late") | deadline: tick.(:system) + 30_000}
    assert :ok = DataSource.command(client, request)

    assert_receive {:late, ^server, socket, %Message{body: %{"timeout_ms" => 30_000}} = sent},
                   1_000

    # A wall-clock step alone expires nothing.
    advance.(:system, 3_600_000)
    refute_receive {:swarm_code_ui_data, _, _, _}, 250

    advance.(:monotonic, 30_001)

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{
                      body: %DTO.Outcome{
                        request_id: "late-1",
                        status: :outcome_unknown,
                        error: %AdmissionError{code: :deadline_expired}
                      }
                    }},
                   1_000

    assert :ok = DataSource.consume(client, receipt, :applied)

    body = %{
      "status" => "accepted",
      "request_id" => sent.request_id,
      "identifiers" => [@connection],
      "interaction" => nil,
      "error" => nil,
      "corrective_action" => "none"
    }

    send_frame(socket, %{
      sent
      | type: :response,
        body: %{"op" => "result", "response_kind" => "outcome", "value" => body}
    })

    refute_receive {:swarm_code_ui_data, _, _, _}, 250

    # The connection survived the late reply.
    next = %{command_request("after-late", "fix") | deadline: tick.(:system) + 30_000}
    assert :ok = DataSource.command(client, next)

    assert_receive {:swarm_code_ui_data, @epoch, _,
                    %Delivery{body: %DTO.Outcome{request_id: "after-late", status: :accepted}}},
                   1_000

    assert :ok = DataSource.close(client)
  end

  # pass72 F (P's request 3): a real session closed with "the daemon connection
  # closed" and nothing in cli.log; the client now logs why it closes.
  test "a delivery the owner never consumes closes the connection and says why" do
    clock = start_supervised!({Agent, fn -> %{system: 1_790_000_000_000, monotonic: 0} end})
    tick = fn kind -> Agent.get(clock, &Map.fetch!(&1, kind)) end

    path = socket_path!()
    {listener, _server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)

    {:ok, client} =
      SwarmCodeCLI.UI.DataSource.Daemon.start_link(
        socket_path: path,
        nonce: @nonce,
        source_epoch: @epoch,
        timeout: 200,
        clock: tick
      )

    assert {:ok, "bind-1"} = DataSource.bind_owner(client, self(), "bind-1")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 DataSource.watch(client, %Watch{
                   watch_ref: "workspace-1",
                   slot: :workspace,
                   scope: @scope,
                   generation: 0,
                   page_size: 1,
                   byte_limit: 65_536
                 })

        assert_receive {:swarm_code_ui_data, @epoch, _receipt, %Delivery{kind: :watch_ready}},
                       1_000

        Agent.update(clock, &Map.update!(&1, :monotonic, fn v -> v + 10_000 end))
        assert closed_within?(client, 100)
      end)

    assert log =~ "closing the daemon connection: deadline:"
    assert log =~ "the session did not consume a delivery in time"
  end

  test "wrong-nonce command error is an unknown outcome rather than trusted remote refusal" do
    {client, _server} = connected!()
    assert :ok = DataSource.command(client, command_request("bad-reply", "wrong-nonce"))

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{body: %DTO.Outcome{status: :outcome_unknown}}},
                   1_000

    assert :ok = DataSource.consume(client, receipt, :applied)
  end

  test "held owner receives one receipt and no ACK while queued socket events remain bounded" do
    {client, server} = connected!()

    assert :ok =
             DataSource.watch(client, %Watch{
               watch_ref: "workspace-1",
               slot: :workspace,
               scope: @scope,
               generation: 0,
               page_size: 20,
               byte_limit: 65_536
             })

    assert_receive {:swarm_code_ui_data, @epoch, first, %Delivery{kind: :watch_ready}}, 1_000
    refute_receive {:swarm_code_ui_data, _, _, _}, 50
    refute_receive {:ack, _, _}, 50
    state = :sys.get_state(client)
    assert state.delivery_count == 2
    assert state.wire_bytes > 0 and state.wire_bytes <= 1_048_576
    assert state.decoded_bytes > 0 and state.decoded_bytes <= 2_097_152
    assert :ok = DataSource.consume(client, first, :applied)
    assert_receive {:swarm_code_ui_data, @epoch, second, %Delivery{sequence: 2}}, 1_000
    task = Task.async(fn -> DataSource.consume(client, second, :applied) end)
    assert {:error, %AdmissionError{code: :invalid_request}} = Task.await(task)
    refute_receive {:ack, _, _}, 30
    assert :ok = DataSource.consume(client, second, :applied)
    assert_receive {:ack, ^server, %Message{body: %{"sequence" => 2}}}, 1_000

    assert {:error, %AdmissionError{code: :invalid_request}} =
             DataSource.consume(client, second, :applied)

    assert :ok = DataSource.close(client)
  end

  test "forged remote errors and sequenced command replies cannot claim rejection or success" do
    for text <- ["bad-error", "bad-sequence"] do
      {client, _server} = connected!()
      assert :ok = DataSource.command(client, command_request(text, text))

      assert_receive {:swarm_code_ui_data, @epoch, receipt,
                      %Delivery{body: %DTO.Outcome{status: :outcome_unknown}}},
                     1_000

      assert :ok = DataSource.consume(client, receipt, :applied)
      assert :ok = DataSource.close(client)
    end
  end

  test "connection closure is announced only after its pending outcome is consumed" do
    {client, _server} = connected!()
    assert :ok = DataSource.command(client, command_request("disconnect-order", "disconnect"))

    assert_receive {:swarm_code_ui_data, @epoch, receipt,
                    %Delivery{body: %DTO.Outcome{status: :outcome_unknown}}},
                   1_000

    refute_receive {:swarm_code_ui_closed, ^client, @epoch}, 30
    assert :ok = DataSource.consume(client, receipt, :applied)
    assert_receive {:swarm_code_ui_closed, ^client, @epoch}, 1_000
  end

  test "watch saturation preserves the reserved unknown outcome for a written command" do
    {client, server} = connected!()
    assert :ok = DataSource.command(client, command_request("pending-during-flood", "hold"))

    assert :ok =
             DataSource.watch(client, %Watch{
               watch_ref: "saturation",
               slot: :workspace,
               scope: @scope,
               generation: 0,
               page_size: 20,
               byte_limit: 65_536
             })

    assert_receive {:swarm_code_ui_data, @epoch, first, %Delivery{kind: :watch_ready}}, 1_000
    assert_receive {:burst_sent, ^server}, 1_000
    # Deadline processing and transport overload both have to retain the pending
    # command; consuming the first receipt lets the terminal outcome drain.
    # The peer's close is the observable overload boundary; no clock sleep is needed.
    assert_receive {:peer_closed, ^server}, 2_000
    assert :ok = DataSource.consume(client, first, :applied)

    assert_receive {:swarm_code_ui_data, @epoch, outcome_receipt,
                    %Delivery{
                      body: %DTO.Outcome{
                        request_id: "pending-during-flood",
                        status: :outcome_unknown
                      }
                    }},
                   1_000

    assert :ok = DataSource.consume(client, outcome_receipt, :applied)
    assert_receive {:swarm_code_ui_closed, ^client, @epoch}, 1_000
  end

  # pass70 C4 (rel F4): a daemon that drops a watch's backlog asks for a
  # snapshot; the client re-opens the watch on a fresh wire reference, the UI
  # sees `resyncing` then a `watch_ready` whose sequences continue, and credit
  # goes to the new wire watch.
  test "snapshot_required re-opens the watch on the wire without closing the session" do
    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    assert {:ok, "bind-1"} = DataSource.bind_owner(client, self(), "bind-1")

    watch = %Watch{
      watch_ref: "resync-me",
      slot: :workspace,
      scope: @scope,
      generation: 0,
      page_size: 5,
      byte_limit: 65_536
    }

    assert :ok = DataSource.watch(client, watch)
    assert_receive {:request, ^server, %Message{body: %{"watch_ref" => "resync-me"}}}

    assert_receive {:swarm_code_ui_data, @epoch, ready,
                    %Delivery{kind: :watch_ready, watch_ref: "resync-me", body: first}}

    assert first.through_sequence == 1
    assert :ok = DataSource.consume(client, ready, :applied)

    assert_receive {:swarm_code_ui_data, @epoch, delta,
                    %Delivery{kind: :delta, watch_ref: "resync-me", sequence: 2}}

    # The old wire watch is already gone: its delta credits nothing.
    assert :ok = DataSource.consume(client, delta, :applied)
    refute_receive {:ack, ^server, %Message{body: %{"watch_ref" => "resync-me"}}}, 20

    assert_receive {:swarm_code_ui_data, @epoch, resync,
                    %Delivery{kind: :resyncing, watch_ref: "resync-me"}}

    assert :ok = DataSource.consume(client, resync, :applied)
    assert_receive {:request, ^server, %Message{body: %{"op" => "watch", "watch_ref" => wire}}}
    refute wire == "resync-me"

    assert_receive {:swarm_code_ui_data, @epoch, again,
                    %Delivery{kind: :watch_ready, watch_ref: "resync-me", body: second}}

    # The wire snapshot is at 1 on the new wire; the UI continues past 2.
    assert second.through_sequence == 3
    assert second.transcript.through_sequence == 3
    assert :ok = DataSource.consume(client, again, :applied)

    assert_receive {:swarm_code_ui_data, @epoch, next,
                    %Delivery{kind: :delta, watch_ref: "resync-me", sequence: 4, body: body}}

    assert body.sequence == 4
    assert :ok = DataSource.consume(client, next, :applied)
    assert_receive {:ack, ^server, %Message{body: %{"watch_ref" => ^wire, "sequence" => 2}}}
    assert Process.alive?(client)
    assert :ok = DataSource.close(client)
  end

  test "a resync query re-opens its watch and answers with the next watch_ready" do
    path = socket_path!()
    {listener, server} = socket_server(path, self())
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path)
    assert {:ok, "bind-1"} = DataSource.bind_owner(client, self(), "bind-1")

    watch = %Watch{
      watch_ref: "shell-1",
      slot: :shell,
      scope: %Scope{kind: :global, id: nil, generation: 0},
      generation: 0,
      page_size: 5,
      byte_limit: 65_536
    }

    assert :ok = DataSource.watch(client, watch)
    assert_receive {:request, ^server, %Message{body: %{"watch_ref" => "shell-1"}}}
    assert_receive {:swarm_code_ui_data, @epoch, ready, %Delivery{kind: :watch_ready}}
    assert :ok = DataSource.consume(client, ready, :applied)
    assert_receive {:swarm_code_ui_data, @epoch, counts, %Delivery{kind: :delta, sequence: 2}}
    assert :ok = DataSource.consume(client, counts, :applied)

    resync = %Request{
      request_id: "resync-1",
      kind: {:resync_watch, "shell-1"},
      scope: watch.scope,
      generation: 0,
      origin: {:watch, "shell-1"},
      deadline: System.system_time(:millisecond) + 5_000,
      expected_response: :watch_snapshot
    }

    assert :ok = DataSource.query(client, resync)
    assert_receive {:request, ^server, %Message{body: %{"op" => "watch", "watch_ref" => "~rw-1"}}}

    assert_receive {:swarm_code_ui_data, @epoch, _,
                    %Delivery{kind: :watch_ready, watch_ref: "shell-1", body: body}}

    assert body.through_sequence == 3
    assert :ok = DataSource.close(client)
  end

  # The deadline timer is real; poll the client's phase at its own pace.
  defp closed_within?(_client, 0), do: false

  defp closed_within?(client, tries) do
    if :sys.get_state(client).phase == :closed do
      true
    else
      receive do
      after
        20 -> closed_within?(client, tries - 1)
      end
    end
  end

  defp connected!(epoch \\ @epoch) do
    path = socket_path!()
    {listener, server} = socket_server(path, self(), epoch)
    on_exit(fn -> close_socket(listener, path) end)
    {:ok, client} = daemon(path, epoch)
    assert {:ok, "bind-1"} = DataSource.bind_owner(client, self(), "bind-1")
    {client, server}
  end

  defp query_request(id),
    do: %Request{
      request_id: id,
      kind: {:query, :transcript, nil, :after, 20, 65_536},
      scope: @scope,
      generation: 0,
      origin: {:query, :transcript},
      deadline: System.system_time(:millisecond) + 2_000,
      expected_response: :transcript_window
    }

  defp command_request(id, text),
    do: %{
      query_request(id)
      | kind: {:dispatch, :send, text, :main, []},
        origin: {:draft, {@scope.id, :main}},
        expected_response: :outcome
    }

  defp daemon(path, epoch \\ @epoch),
    do:
      SwarmCodeCLI.UI.DataSource.Daemon.start_link(
        socket_path: path,
        nonce: @nonce,
        source_epoch: epoch,
        timeout: 1_000
      )

  defp socket_path!,
    do:
      Path.join(
        System.tmp_dir!(),
        "swarm-code-daemon-test-#{System.unique_integer([:positive])}.sock"
      )

  defp socket_server(path, test, epoch \\ @epoch) do
    {:ok, listener} = :socket.open(:local, :stream, :default)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener, 4)

    server =
      spawn_link(fn ->
        {:ok, socket} = :socket.accept(listener)
        server_loop(socket, test, FrameDecoder.new(), epoch)
      end)

    {listener, server}
  end

  defp server_loop(socket, test, decoder, epoch) do
    case :socket.recv(socket, 0, 1_000) do
      {:ok, bytes} ->
        {:ok, messages, next_decoder} = FrameDecoder.push(decoder, bytes)

        Enum.each(messages, fn message ->
          case message.body["op"] do
            "hello" ->
              send(test, {:hello, self(), message})
              send_frame(socket, hello_ok(message.request_id, message.nonce, epoch))

            "watch" ->
              send(test, {:request, self(), message})

              if message.body["watch_ref"] == "saturation" do
                send_frame(socket, snapshot_for(message))

                Enum.each(2..33, fn seq ->
                  value = delta()

                  value = %{
                    value
                    | sequence: seq,
                      body: %{
                        value.body
                        | "watch_ref" => "saturation",
                          "value" => %{value.body["value"] | "sequence" => seq, "revision" => seq}
                      }
                  }

                  send_frame(socket, value)
                end)

                send(test, {:burst_sent, self()})
              else
                if message.body["watch_ref"] == "resync-me" do
                  send_frame(socket, snapshot_for(message))
                  send_frame(socket, counts_for(message))

                  send_frame(socket, %Message{
                    version: 1,
                    type: :snapshot_required,
                    request_id: nil,
                    nonce: message.nonce,
                    scope: message.scope,
                    sequence: 3,
                    occurred_at: "2026-09-23T00:00:00Z",
                    body: %{
                      "op" => "snapshot_required",
                      "watch_ref" => "resync-me",
                      "reason" => "overflow"
                    }
                  })
                end

                if message.body["watch_ref"] == "resync-me" do
                  :ok
                else
                  if message.body["watch_ref"] == "workspace-1" do
                    send_frame(socket, watch_ready())
                    send_frame(socket, delta())
                  else
                    send_frame(socket, snapshot_for(message))

                    if message.body["slot"] in ["shell", "workspace"],
                      do: send_frame(socket, counts_for(message))
                  end
                end
              end

            "unwatch" ->
              send_frame(socket, %{
                message
                | type: :response,
                  body: %{"op" => "result", "response_kind" => "acknowledged", "value" => %{}}
              })

            "ack" ->
              send(test, {:ack, self(), message})

              send_frame(socket, %{
                message
                | type: :response,
                  body: %{"op" => "result", "response_kind" => "acknowledged", "value" => %{}}
              })

            "query" ->
              send(test, {:request, self(), message})

              page =
                watch_ready().body["value"]["transcript"]
                |> Map.put("request_id", message.request_id)

              send_frame(socket, %{
                message
                | type: :response,
                  body: %{
                    "op" => "result",
                    "response_kind" => "transcript_window",
                    "value" => page
                  }
              })

            "dispatch" ->
              send(test, {:request, self(), message})

              cond do
                message.body["text"] == "hold" ->
                  :ok

                message.body["text"] == "late" ->
                  send(test, {:late, self(), socket, message})

                message.body["text"] == "bad-error" ->
                  send_frame(socket, %{
                    message
                    | type: :error,
                      body: %{
                        "op" => "error",
                        "code" => "not_allowed",
                        "message" => "arbitrary diagnostics"
                      }
                  })

                message.body["text"] == "bad-sequence" ->
                  body = %{
                    "status" => "accepted",
                    "request_id" => message.request_id,
                    "identifiers" => [@connection],
                    "interaction" => nil,
                    "error" => nil,
                    "corrective_action" => "none"
                  }

                  send_frame(socket, %{
                    message
                    | type: :response,
                      sequence: 99,
                      body: %{"op" => "result", "response_kind" => "outcome", "value" => body}
                  })

                message.body["text"] == "wrong-nonce" ->
                  send_frame(socket, %{
                    message
                    | type: :error,
                      nonce: String.duplicate("B", 42) <> "A",
                      body: %{
                        "op" => "error",
                        "code" => "not_allowed",
                        "message" => "request is not allowed"
                      }
                  })

                message.body["text"] == "disconnect" ->
                  :socket.close(socket)

                true ->
                  body = %{
                    "status" => "accepted",
                    "request_id" => message.request_id,
                    "identifiers" => [@connection],
                    "interaction" => nil,
                    "error" => nil,
                    "corrective_action" => "none"
                  }

                  send_frame(socket, %{
                    message
                    | type: :response,
                      body: %{"op" => "result", "response_kind" => "outcome", "value" => body}
                  })
              end

            _ ->
              :ok
          end
        end)

        server_loop(socket, test, next_decoder, epoch)

      {:error, :closed} ->
        send(test, {:peer_closed, self()})

      {:error, :timeout} ->
        server_loop(socket, test, decoder, epoch)
    end
  end

  defp send_frame(socket, message) do
    {:ok, frame} = Frame.encode(message)

    case :socket.send(socket, IO.iodata_to_binary(frame)) do
      :ok -> :ok
      {:error, :closed} -> :ok
      {:error, :epipe} -> :ok
    end
  end

  defp hello_ok(request_id, nonce, epoch) do
    {:ok, body} =
      ServiceHandshake.encode_hello_ok(%ServiceHandshake.HelloOk{
        source_epoch: epoch,
        connection_id: @connection,
        capabilities: [
          :query,
          :detail,
          :watch,
          :conversation_open,
          :dispatch_send,
          :run_pause,
          :run_continue,
          :run_stop,
          :run_steer,
          :approval_resolve
        ],
        max_frame_bytes: 1_048_576
      })

    %Message{
      version: 1,
      type: :hello_ok,
      request_id: request_id,
      nonce: nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: body
    }
  end

  defp watch_ready do
    page = %{
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => nil,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => [],
      "through_sequence" => 1
    }

    value =
      Map.merge(page, %{
        "allowed_actions" => [],
        "revision" => 1,
        "seen_revision" => 0,
        "runs_page" => page,
        "interactions_page" => page,
        "conversation_id" => @scope.id,
        "runs" => [],
        "interactions" => [],
        "transcript" => Map.put(page, "items", [])
      })

    %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: 1,
      occurred_at: "2026-09-07T00:00:00Z",
      body: %{
        "op" => "watch_ready",
        "watch_ref" => "workspace-1",
        "revision" => 1,
        "body_kind" => "workspace_snapshot",
        "value" => value
      }
    }
  end

  defp snapshot_for(request) do
    base = watch_ready()
    common = Map.drop(base.body["value"]["transcript"], ["items"])

    counts = %{
      "running" => 0,
      "waiting" => 0,
      "paused" => 0,
      "failed" => 0,
      "done" => 0,
      "unseen" => 0
    }

    {kind, value} =
      case request.body["slot"] do
        "shell" ->
          {"shell_snapshot",
           Map.merge(common, %{
             "runs" => [],
             "counts" => counts,
             "connection" => %{"state" => "connected", "source_epoch" => @epoch}
           })}

        "activity" ->
          {"activity_snapshot", Map.merge(common, %{"items" => [], "counts" => counts})}

        "workspace" ->
          {"workspace_snapshot", base.body["value"]}
      end

    %{
      base
      | scope: request.scope,
        body: %{
          base.body
          | "watch_ref" => request.body["watch_ref"],
            "body_kind" => kind,
            "value" => value
        }
    }
  end

  defp counts_for(request) do
    base = delta()

    %{
      base
      | scope: request.scope,
        body: %{
          "op" => "delta",
          "watch_ref" => request.body["watch_ref"],
          "value" => %{
            "kind" => "counts_update",
            "entity_id" => nil,
            "run_id" => nil,
            "conversation_id" => nil,
            "channel" => nil,
            "attempt_id" => nil,
            "text" => nil,
            "sequence" => 2,
            "revision" => 2,
            "body" => %{
              "running" => 3,
              "waiting" => 0,
              "paused" => 0,
              "failed" => 0,
              "done" => 0,
              "unseen" => 0
            }
          }
        }
    }
  end

  defp delta do
    message = watch_ready()

    %{
      message
      | sequence: 2,
        body: %{
          "op" => "delta",
          "watch_ref" => "workspace-1",
          "value" => %{
            "kind" => "stream_append",
            "entity_id" => "message-1",
            "run_id" => @connection,
            "conversation_id" => @scope.id,
            "channel" => "text",
            "attempt_id" => "actual-operation-1",
            "text" => "Hello",
            "body" => nil,
            "sequence" => 2,
            "revision" => 2
          }
        }
    }
  end

  defp close_socket(listener, path) do
    _ = :socket.close(listener)
    _ = File.rm(path)
  end
end
