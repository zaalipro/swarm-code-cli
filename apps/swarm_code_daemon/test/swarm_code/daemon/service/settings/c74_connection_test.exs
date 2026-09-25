defmodule SwarmCode.Daemon.Service.Settings.C74ConnectionTest do
  @moduledoc """
  pass74 S1-5: settings requests over a real Connection. A deadline on a
  settings query answers a typed error, on a settings command an
  `outcome_unknown` outcome; neither closes the connection. The connection
  keeps a settings command's message without its secrets, and its crash
  report holds neither the message nor the log.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service
  alias SwarmCode.Daemon.Service.Connection
  alias SwarmCode.Protocol.{Envelope, Frame, Message, Scope}

  @nonce String.duplicate("A", 43)
  @epoch "33333333-3333-4333-8333-333333333333"
  @id "11111111-1111-4111-8111-111111111111"
  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  setup do
    dir = Path.join(System.tmp_dir!(), "c74-conn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "daemon.sock")}
  end

  test "hello grants settings by default", %{path: path} do
    {_socket, _backend, hello_ok} = connected(path)
    assert "settings" in hello_ok.body["capabilities"]
    assert :settings in Service.default_capabilities()
    assert length(Service.default_capabilities()) == 17
  end

  test "a deadline on a settings query is a typed read error; the connection stays", %{path: path} do
    {socket, backend, _} = connected(path)
    send(backend, :hold)
    send_frame(socket, settings_query(uuid(1), 300))

    assert %Message{type: :error, request_id: request_id, body: %{"code" => "deadline_expired"}} =
             receive_frame(socket, 3_000)

    assert request_id == uuid(1)
    send(backend, :release)
    assert_alive(socket)
  end

  test "a deadline on a settings command is an unknown outcome; the connection stays", %{
    path: path
  } do
    {socket, backend, _} = connected(path)
    send(backend, :hold)
    send_frame(socket, settings_command(uuid(2), 300, @canary))

    assert %Message{
             type: :response,
             body: %{"response_kind" => "outcome", "value" => %{"status" => "outcome_unknown"}}
           } = receive_frame(socket, 3_000)

    send(backend, :release)
    assert_alive(socket)
  end

  test "the connection stores the command without its secrets; its status is redacted", %{
    path: path
  } do
    {socket, backend, _} = connected(path)
    send(backend, :hold)
    send_frame(socket, settings_command(uuid(3), 5_000, @canary))
    assert_receive {:held, request}, 2_000
    assert request.params["secrets"] == [%{"slot" => "api_key", "value" => @canary}]
    refute inspect(request) =~ @canary

    [connection] = connections()
    state = :sys.get_state(connection)
    refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ @canary

    status = Connection.format_status(%{state: state, message: {:x, @canary}, log: [@canary]})
    assert status.message == :redacted and status.log == :redacted
    refute inspect(status, limit: :infinity) =~ @canary
    send(backend, :release)
  end

  defp connections do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(clients()), is_pid(pid), do: pid
  end

  defp clients do
    [{_, service, _, _}] = Supervisor.which_children(Process.get(:sup))
    state = :sys.get_state(service)
    state.clients
  end

  defp assert_alive(socket) do
    send_frame(socket, settings_query(uuid(99), 2_000))
    assert %Message{type: :response, request_id: id} = receive_frame(socket)
    assert id == uuid(99)
  end

  defp connected(path) do
    owner = self()
    backend = spawn_link(fn -> backend(%{owner: owner, hold: false, held: []}) end)

    sup =
      start_supervised!(%{
        id: :c74_service_sup,
        start:
          {Supervisor, :start_link,
           [
             [
               {Service, socket_path: path, nonce: @nonce, source_epoch: @epoch, backend: backend}
             ],
             [strategy: :one_for_one]
           ]}
      })

    Process.put(:sup, sup)

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

    send_frame(socket, hello(@nonce))
    assert %Message{type: :hello_ok} = hello_ok = receive_frame(socket)
    {socket, backend, hello_ok}
  end

  defp backend(state) do
    receive do
      :hold ->
        backend(%{state | hold: true})

      :release ->
        Enum.each(state.held, &answer/1)
        backend(%{state | hold: false, held: []})

      {:"$gen_call", _from, {:service_request, _id, _scope, request}} = call ->
        if state.hold do
          send(state.owner, {:held, request})
          backend(%{state | held: [call | state.held]})
        else
          answer(call)
          backend(state)
        end

      _ ->
        backend(state)
    end
  end

  defp answer({:"$gen_call", from, {:service_request, id, _scope, _request}}) do
    GenServer.reply(
      from,
      {:ok,
       %{
         "op" => "result",
         "response_kind" => "settings_snapshot",
         "value" => %{
           "request_id" => id,
           "view" => "values",
           "revision" => 0,
           "available" => true,
           "message" => nil,
           "body" => %{}
         }
       }}
    )
  end

  defp settings_query(id, timeout),
    do: %{
      request(id)
      | body: %{
          "op" => "settings.query",
          "timeout_ms" => timeout,
          "view" => "values",
          "sections" => nil,
          "keys" => nil,
          "kind" => nil,
          "id" => nil,
          "project_id" => nil,
          "cursor" => nil,
          "page_size" => 200,
          "byte_limit" => 900_000,
          "options" => nil
        }
    }

  defp settings_command(id, timeout, secret),
    do: %{
      request(id)
      | body: %{
          "op" => "settings.command",
          "timeout_ms" => timeout,
          "action" => "provider.set_key",
          "target" => %{"id" => @id},
          "attributes" => %{"test_first" => false},
          "expected" => %{"key" => %{"set" => false, "hint" => nil}},
          "secrets" => [%{"slot" => "api_key", "value" => secret}],
          "dry_run" => false
        }
    }

  defp request(id),
    do: %Message{
      version: 1,
      type: :request,
      request_id: id,
      nonce: @nonce,
      scope: %Scope{kind: :global, id: nil, generation: 0},
      sequence: nil,
      occurred_at: nil,
      body: %{}
    }

  defp uuid(n) do
    hex = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "bbbbbbbb-bbbb-4bbb-8bbb-" <> hex
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
end
