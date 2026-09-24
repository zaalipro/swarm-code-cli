defmodule SwarmCode.Daemon.Service.Pass73ConnectionTest do
  @moduledoc """
  pass73 T11: the session died with "the daemon connection closed" while
  several runs were live. Every way the daemon used to close a healthy
  client's connection on its own is pinned here: an acknowledgement racing a
  watch the daemon had just dropped (overflow), a stale acknowledgement, the
  4,096th request id of a connection, a 33rd request while watches were
  pending, and a client that paused reading for more than two seconds. Each
  now keeps the connection, and every close that remains says why in the log.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SwarmCode.Protocol.{Envelope, Frame, Message, Scope}
  alias SwarmCode.Daemon.Service

  @nonce String.duplicate("A", 43)
  @epoch "33333333-3333-4333-8333-333333333333"
  @id "11111111-1111-4111-8111-111111111111"

  setup do
    dir = Path.join(System.tmp_dir!(), "p73-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "daemon.sock")}
  end

  test "an ack for a watch the daemon dropped on overflow keeps the connection", %{path: path} do
    {socket, backend} = connected_with_backend(path)
    watch!(socket, "test-watch")

    # Sixteen deltas ride unacknowledged; the seventeenth drops the watch.
    for _ <- 1..17, do: send(backend, {:emit, "test-watch"})
    for _ <- 1..16, do: assert(%Message{type: :event} = receive_frame(socket))
    assert %Message{type: :snapshot_required} = receive_frame(socket)

    # The client consumed a delta before it read the snapshot_required frame:
    # its ack names the watch that is already gone.
    send_frame(socket, ack("test-watch", 5))

    assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
             receive_frame(socket)

    assert_alive(socket)
  end

  test "an ack the backend already dropped (backend overflow) keeps the connection",
       %{path: path} do
    {socket, backend} = connected_with_backend(path)
    watch!(socket, "test-watch")
    send(backend, {:emit, "test-watch"})
    assert %Message{type: :event, sequence: 5} = receive_frame(socket)
    send(backend, {:overflow, "test-watch"})
    assert %Message{type: :snapshot_required} = receive_frame(socket)

    send_frame(socket, ack("test-watch", 5))

    assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
             receive_frame(socket)

    assert_alive(socket)
  end

  test "a repeated ack of a sequence already acknowledged keeps the connection",
       %{path: path} do
    {socket, backend} = connected_with_backend(path)
    watch!(socket, "test-watch")
    send(backend, {:emit, "test-watch"})
    assert %Message{type: :event, sequence: 5} = receive_frame(socket)

    send_frame(socket, ack("test-watch", 5))
    assert %Message{type: :response} = receive_frame(socket)
    send_frame(socket, ack("test-watch", 5))

    assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
             receive_frame(socket)

    assert_alive(socket)
  end

  # Every delta the client consumes is acknowledged with a request of its own,
  # so a busy session spends request ids fast; the 4,097th closed it.
  test "a connection outlives 4,096 request ids", %{path: path} do
    {socket, _backend} = connected_with_backend(path)

    for n <- 1..4_200 do
      send_frame(socket, %{
        request()
        | request_id: uuid(n),
          body: %{"op" => "unwatch", "watch_ref" => "gone-#{n}", "timeout_ms" => 1000}
      })

      assert %Message{type: :response, body: %{"response_kind" => "acknowledged"}} =
               receive_frame(socket)
    end

    assert_alive(socket)
  end

  test "a reused request id is still refused while it is recent", %{path: path} do
    {socket, _backend} = connected_with_backend(path)
    unwatch = %{request() | body: %{"op" => "unwatch", "watch_ref" => "x", "timeout_ms" => 1000}}
    send_frame(socket, unwatch)
    assert %Message{type: :response} = receive_frame(socket)

    log =
      capture_log(fn ->
        send_frame(socket, unwatch)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    assert log =~ "SwarmCode daemon closed a client connection: a request reused a recent id"
  end

  # A watch whose snapshot is still being built is not one of the client's 32
  # requests: with watches pending, the 33rd request of any kind closed the
  # connection. Past the limit a request is refused on its own.
  test "requests past the in-flight limit are refused, the connection stays",
       %{path: path} do
    {socket, backend} = connected_with_backend(path)
    send(backend, :hold)

    for n <- 1..4 do
      send_frame(socket, %{watch_request("pending-#{n}") | request_id: uuid(10_000 + n)})
    end

    for n <- 1..32, do: send_frame(socket, %{request() | request_id: uuid(20_000 + n)})
    send_frame(socket, %{request() | request_id: uuid(30_000)})

    assert %Message{
             type: :error,
             request_id: refused,
             body: %{"code" => "capacity_exceeded"}
           } = receive_frame(socket)

    assert refused == uuid(30_000)
    send(backend, :release)
    frames = for _ <- 1..36, do: receive_frame(socket)
    assert Enum.count(frames, &(&1.type == :response)) == 32
    assert Enum.count(frames, &(&1.type == :event)) == 4
  end

  # The daemon wrote with a two-second send timeout: a client that stopped
  # reading for longer (its owner busy with a big snapshot, a paused terminal)
  # lost its connection. The client itself tolerates thirty seconds.
  test "a client that pauses reading for three seconds keeps the connection",
       %{path: path} do
    {socket, backend} = connected_with_backend(path)
    send(backend, {:reply_bytes, 400_000})

    for n <- 1..3, do: send_frame(socket, %{request() | request_id: uuid(40_000 + n)})

    receive do
    after
      3_000 -> :ok
    end

    for _ <- 1..3, do: assert(%Message{type: :response} = receive_frame(socket, 5_000))
    send(backend, {:reply_bytes, 10})
    assert_alive(socket)
  end

  test "a close the daemon decides says why", %{path: path} do
    {socket, _backend} = connected_with_backend(path)

    log =
      capture_log(fn ->
        :ok =
          :gen_tcp.send(socket, Frame.encode!(%{request() | nonce: String.duplicate("B", 43)}))

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2_000)
      end)

    assert log =~ "SwarmCode daemon closed a client connection: a request carried the wrong nonce"
  end

  test "a client that goes away is noted", %{path: path} do
    {socket, _backend} = connected_with_backend(path)

    log =
      capture_log([level: :info], fn ->
        :gen_tcp.close(socket)

        receive do
        after
          200 -> :ok
        end
      end)

    assert log =~ "SwarmCode daemon: the client closed its connection"
  end

  defp assert_alive(socket) do
    request = %{request() | request_id: "99999999-9999-4999-8999-999999999999"}
    send_frame(socket, request)
    assert %Message{type: :response, request_id: id} = receive_frame(socket)
    assert id == request.request_id
  end

  defp connected_with_backend(path) do
    owner = self()

    backend =
      spawn_link(fn -> backend(%{owner: owner, connection: nil, hold: false, bytes: 10}) end)

    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: backend}
    )

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = receive_frame(socket)
    {socket, backend}
  end

  defp watch!(socket, ref) do
    send_frame(socket, watch_request(ref))

    assert %Message{type: :event, sequence: 4, body: %{"op" => "watch_ready"}} =
             receive_frame(socket)

    assert_receive {:ready, _connection}, 1000
  end

  # A backend double: watches answer at sequence 4, reads answer with a body
  # of `bytes`, and `:hold` keeps every call waiting until `:release`.
  defp backend(state) do
    receive do
      :hold ->
        backend(Map.merge(state, %{hold: true, held: []}))

      :release ->
        Enum.each(Enum.reverse(state.held), &answer(&1, state))
        backend(%{state | hold: false, held: []})

      {:reply_bytes, bytes} ->
        backend(%{state | bytes: bytes})

      {:"$gen_call", from, {:service_watch, conn, _id, _scope, _request}} = call ->
        if state.hold,
          do: backend(%{state | held: [call | state.held]}),
          else:
            (
              GenServer.reply(from, {:watch, 4, 4, "shell_snapshot", %{}})
              backend(%{state | connection: conn})
            )

      {:"$gen_call", _from, {:service_request, _, _, _}} = call ->
        if state.hold do
          backend(%{state | held: [call | state.held]})
        else
          answer(call, state)
          backend(state)
        end

      {:service_ready, conn, _ref} ->
        send(state.owner, {:ready, conn})
        backend(%{state | connection: conn})

      {:emit, ref} ->
        send(
          state.connection,
          {:service_delta, self(), ref, %{"kind" => "counts_update", "revision" => 5}}
        )

        backend(state)

      {:overflow, ref} ->
        send(state.connection, {:service_overflow, self(), ref})
        backend(state)

      _ ->
        backend(state)
    end
  end

  defp answer({:"$gen_call", from, {:service_watch, _, _, _, _}}, _state),
    do: GenServer.reply(from, {:watch, 4, 4, "shell_snapshot", %{}})

  defp answer({:"$gen_call", from, {:service_request, _, _, _}}, state),
    do:
      GenServer.reply(
        from,
        {:ok,
         %{
           "op" => "result",
           "response_kind" => "test",
           "value" => %{"text" => String.duplicate("x", state.bytes)}
         }}
      )

  defp watch_request(ref),
    do: %{
      request()
      | request_id: uuid(:erlang.phash2(ref) + 50_000),
        body: %{
          "op" => "watch",
          "watch_ref" => ref,
          "slot" => "shell",
          "page_size" => 20,
          "byte_limit" => 65536,
          "timeout_ms" => 5000
        }
    }

  defp ack(ref, sequence),
    do: %{
      request()
      | request_id: Ecto.UUID.generate(),
        body: %{"op" => "ack", "watch_ref" => ref, "sequence" => sequence, "timeout_ms" => 1000}
    }

  defp uuid(n) do
    hex = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "aaaaaaaa-aaaa-4aaa-8aaa-" <> hex
  end

  defp send_frame(socket, message), do: :gen_tcp.send(socket, Frame.encode!(message))

  defp receive_frame(socket, timeout \\ 2000) do
    {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4, timeout)
    {:ok, bytes} = :gen_tcp.recv(socket, size, timeout)
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

  defp request,
    do: %Message{
      hello(@nonce)
      | type: :request,
        request_id: Ecto.UUID.generate(),
        scope: %Scope{kind: :global, id: nil, generation: 0},
        body: %{
          "op" => "query",
          "slot" => "shell",
          "cursor" => nil,
          "direction" => "after",
          "page_size" => 20,
          "byte_limit" => 65536,
          "timeout_ms" => 5000
        }
    }
end
