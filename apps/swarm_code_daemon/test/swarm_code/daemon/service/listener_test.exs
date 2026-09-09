defmodule SwarmCode.Daemon.Service.ListenerTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Protocol.{Envelope, Frame, Message, Scope}
  alias SwarmCode.Daemon.Service

  @nonce String.duplicate("A", 43)
  @epoch "33333333-3333-4333-8333-333333333333"
  @id "11111111-1111-4111-8111-111111111111"

  setup do
    dir = Path.join(System.tmp_dir!(), "swarm-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "daemon.sock")}
  end

  test "authenticated request uses closed codec and socket disappears after owned shutdown", %{
    path: path
  } do
    backend = spawn_link(fn -> backend(self()) end)

    service =
      start_supervised!(
        {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: backend}
      )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok, body: %{"source_epoch" => @epoch}} = receive_frame(socket)
    request = query()
    send_frame(socket, request)

    assert %Message{
             type: :response,
             request_id: @id,
             body: %{"value" => %{"received" => "shell"}}
           } = receive_frame(socket)

    assert :ok = GenServer.stop(service)
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 1000)
    refute File.exists?(path)
    Process.exit(backend, :normal)
  end

  test "wrong nonce never reaches a backend", %{path: path} do
    service =
      start_supervised!(
        {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
      )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(String.duplicate("B", 43)))
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 1000)
    refute_receive {:"$gen_call", _, _}, 20
    assert Process.info(service, :status) != nil
  end

  test "existing endpoint and nonprivate directory refuse without deleting files", %{path: path} do
    File.write!(path, "keep")

    assert {:error, _} =
             Service.start_link(
               socket_path: path,
               nonce: @nonce,
               source_epoch: @epoch,
               backend: self()
             )

    assert File.read!(path) == "keep"
    File.rm!(path)
    File.chmod!(Path.dirname(path), 0o755)

    assert {:error, _} =
             Service.start_link(
               socket_path: path,
               nonce: @nonce,
               source_epoch: @epoch,
               backend: self()
             )

    refute File.exists?(path)
  end

  test "malformed request closes the authenticated peer without dispatch", %{path: path} do
    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
    )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)
    send_frame(socket, %{query() | body: %{"op" => "unknown", "timeout_ms" => 1000}})
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 1000)
    refute_receive {:"$gen_call", _, _}, 20
  end

  test "watch snapshot precedes deltas, ACK validates sequence and unwatch cleans ownership", %{
    path: path
  } do
    owner = self()
    backend = spawn_link(fn -> watch_backend(owner, nil) end)

    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: backend}
    )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)

    watch = %{
      query()
      | body: %{
          "op" => "watch",
          "watch_ref" => "test-watch",
          "slot" => "shell",
          "page_size" => 20,
          "byte_limit" => 65536,
          "timeout_ms" => 1000
        }
    }

    send_frame(socket, watch)

    assert %Message{type: :event, sequence: 4, body: %{"op" => "watch_ready"}} =
             receive_frame(socket)

    assert_receive {:registered, connection}, 1000
    send(backend, :emit)

    assert %Message{
             type: :event,
             sequence: 5,
             body: %{"op" => "delta", "value" => %{"sequence" => 5}}
           } = receive_frame(socket)

    refute_receive {:credited, ^connection}, 20

    send_frame(socket, %{
      query()
      | request_id: "22222222-2222-4222-8222-222222222222",
        body: %{"op" => "ack", "watch_ref" => "test-watch", "sequence" => 5, "timeout_ms" => 1000}
    })

    assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
             receive_frame(socket)

    assert_receive {:credited, ^connection}, 1000

    send_frame(socket, %{
      query()
      | request_id: "55555555-5555-4555-8555-555555555555",
        body: %{"op" => "unwatch", "watch_ref" => "test-watch", "timeout_ms" => 1000}
    })

    assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
             receive_frame(socket)

    assert_receive {:unwatched, ^connection}, 1000
    send(backend, :done)
  end

  test "backend timeout closes without reporting a definite rejection", %{path: path} do
    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
    )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)
    request = %{query() | body: Map.put(query().body, "timeout_ms", 100)}
    send_frame(socket, request)
    assert_receive {:"$gen_call", {worker, _}, {:service_request, _, _, _}}, 1000
    monitor = Process.monitor(worker)
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 2000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
  end

  test "untyped backend command failure never reports rejection", %{path: path} do
    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
    )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)

    command = %{
      query()
      | scope: %Scope{kind: :conversation, id: @epoch, generation: 0},
        body: %{
          "op" => "dispatch",
          "action" => "send",
          "text" => "task",
          "target" => %{"kind" => "main", "id" => nil},
          "attachment_refs" => [],
          "timeout_ms" => 1000
        }
    }

    send_frame(socket, command)
    assert_receive {:"$gen_call", from, {:service_request, _, _, _}}, 1000
    GenServer.reply(from, {:error, :backend_unavailable})
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 1000)
  end

  test "unwatch while snapshot is pending does not resurrect a watch", %{path: path} do
    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
    )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)
    send_frame(socket, watch_request())
    assert_receive {:"$gen_call", from, {:service_watch, connection, _, _, _}}, 1000

    send_frame(socket, %{
      query()
      | request_id: "22222222-2222-4222-8222-222222222222",
        body: %{
          "op" => "unwatch",
          "watch_ref" => "pending-watch",
          "timeout_ms" => 1000
        }
    })

    assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
             receive_frame(socket)

    assert_receive {:service_unwatch, ^connection, "pending-watch"}, 1000
    GenServer.reply(from, {:watch, 1, 1, "shell_snapshot", %{}})
    assert_receive {:service_unwatch, ^connection, "pending-watch"}, 1000
    refute_receive {:service_ready, ^connection, "pending-watch"}, 20
    assert {:error, :timeout} = :gen_tcp.recv(socket, 1, 20)
    :gen_tcp.close(socket)
  end

  test "connection death kills its pending request worker", %{path: path} do
    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
    )

    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)
    send_frame(socket, watch_request())
    assert_receive {:"$gen_call", {worker, _}, {:service_watch, connection, _, _, _}}, 1000
    monitor = Process.monitor(worker)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1000
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 1000)
  end

  test "unauthenticated and partial authenticated frames have deadlines", %{path: path} do
    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
    )

    {:ok, idle} = connect(path)
    assert {:error, :closed} = :gen_tcp.recv(idle, 1, 3000)
    {:ok, socket} = connect(path)
    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)
    :ok = :gen_tcp.send(socket, <<0, 0>>)
    assert {:error, :closed} = :gen_tcp.recv(socket, 1, 3000)
    refute_receive {:"$gen_call", _, _}, 20
  end

  test "shutdown preserves a replacement at the endpoint path", %{path: path} do
    service =
      start_supervised!(
        {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: self()}
      )

    File.rename!(path, path <> ".original")
    File.write!(path, "replacement")
    :ok = GenServer.stop(service)
    assert File.read!(path) == "replacement"
  end

  defp watch_request do
    %{
      query()
      | body: %{
          "op" => "watch",
          "watch_ref" => "pending-watch",
          "slot" => "shell",
          "page_size" => 20,
          "byte_limit" => 65536,
          "timeout_ms" => 1000
        }
    }
  end

  defp watch_backend(owner, connection) do
    receive do
      :done ->
        :ok

      {:"$gen_call", from, {:service_watch, conn, _id, _scope, _request}} ->
        GenServer.reply(from, {:watch, 4, 4, "shell_snapshot", %{}})
        watch_backend(owner, conn)

      {:service_ready, conn, "test-watch"} ->
        send(owner, {:registered, conn})
        watch_backend(owner, conn)

      :emit ->
        send(
          connection,
          {:service_delta, self(), "test-watch", %{"kind" => "counts_update", "revision" => 5}}
        )

        watch_backend(owner, connection)

      {:service_credit, conn, "test-watch", 5} ->
        send(owner, {:credited, conn})
        watch_backend(owner, connection)

      {:service_unwatch, conn, "test-watch"} ->
        send(owner, {:unwatched, conn})
        watch_backend(owner, nil)
    end
  end

  defp backend(_owner) do
    receive do
      {:"$gen_call", from, {:service_request, _id, _scope, request}} ->
        GenServer.reply(
          from,
          {:ok,
           %{
             "op" => "result",
             "response_kind" => "test",
             "value" => %{"received" => request.params["slot"]}
           }}
        )

        backend(nil)
    end
  end

  defp connect(path),
    do: :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

  defp send_frame(socket, message), do: :gen_tcp.send(socket, Frame.encode!(message))

  defp receive_frame(socket) do
    {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4, 2000)
    {:ok, bytes} = :gen_tcp.recv(socket, size, 2000)
    {:ok, message} = Envelope.decode(bytes)
    message
  end

  defp hello(nonce),
    do: %Message{
      version: 1,
      type: :hello,
      request_id: @id,
      nonce: nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: %{"op" => "hello", "client" => "swarm-code-cli", "body_version" => 1}
    }

  defp query,
    do: %Message{
      hello(@nonce)
      | type: :request,
        scope: %Scope{kind: :global, id: nil, generation: 0},
        body: %{
          "op" => "query",
          "slot" => "shell",
          "cursor" => nil,
          "direction" => "after",
          "page_size" => 20,
          "byte_limit" => 65536,
          "timeout_ms" => 1000
        }
    }
end
