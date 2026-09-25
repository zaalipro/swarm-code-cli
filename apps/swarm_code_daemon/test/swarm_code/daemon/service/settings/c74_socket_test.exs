defmodule SwarmCode.Daemon.Service.Settings.C74SocketTest do
  @moduledoc """
  pass74 S1-16: settings end to end over the socket — a real `Service` and
  `Connection` in front of a real `PersistedBackend` on a fixture database.
  Hello grants `settings`; `settings.query open` answers; `values.patch` is
  accepted, then refused as changed elsewhere; a client reconnecting after a
  lost reply gets the saved answer replayed and a rejected `outcome` for a
  used id with another body; a deadline on a query and on a command keeps the
  connection open; `provider.set_key` answers (unsupported without S2's
  handler); and no frame the daemon writes holds the canary.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service
  alias SwarmCode.Daemon.Service.{PersistedBackend, Settings}
  alias SwarmCode.Daemon.Service.Settings.Router
  alias SwarmCode.Domain.{Engine, Repo, UIState}
  alias SwarmCode.Protocol.{Envelope, Frame, Message, Scope}
  alias SwarmCode.Test.C74S1

  @moduletag timeout: 120_000
  @nonce String.duplicate("B", 43)
  @hello_id "11111111-1111-4111-8111-111111111111"

  setup do
    %{dir: dir} = C74S1.repo!("c74-s1-socket")
    unless Process.whereis(UIState), do: start_supervised!(UIState)
    on_exit(fn -> Application.delete_env(:swarm_code_daemon, :settings_job_seam) end)
    fixture = C74S1.appendix_a!(dir)
    epoch = Ecto.UUID.generate()

    backend =
      start_supervised!(
        {PersistedBackend,
         mode: :persisted,
         repo: Repo,
         project_root: fixture.ailogic.root_path,
         project_id: fixture.ailogic.id,
         conversation_id: fixture.conversation.id,
         source_epoch: epoch}
      )

    on_exit(fn -> Engine.stop_all(fixture.conversation.id) end)

    socket_dir = Path.join(dir, "sock")
    File.mkdir_p!(socket_dir)
    File.chmod!(socket_dir, 0o700)
    path = Path.join(socket_dir, "s")

    start_supervised!(
      {Service, socket_path: path, nonce: @nonce, source_epoch: epoch, backend: backend}
    )

    {socket, hello_ok} = connect(path)
    Map.merge(fixture, %{socket: socket, hello_ok: hello_ok, path: path})
  end

  test "settings over the socket, with no canary in any frame the daemon writes", c do
    assert "settings" in c.hello_ok.body["capabilities"]

    # open: the four views in one answer.
    send_frame(c.socket, query(uuid(1), %{"view" => "open"}))

    assert %Message{
             type: :response,
             body: %{"response_kind" => "settings_snapshot", "value" => open}
           } = receive_frame(c.socket)

    assert %{"available" => true, "view" => "open", "body" => body} = open
    assert Map.keys(body) |> Enum.sort() == ["facts", "overview", "projects", "values"]

    # values.patch accepted, then refused as changed elsewhere.
    send_frame(c.socket, patch(uuid(2), 7, 6))
    assert %{"status" => "accepted"} = result(receive_frame(c.socket))
    send_frame(c.socket, patch(uuid(3), 8, 6))

    assert %{"status" => "conflict", "results" => [%{"current" => 7}]} =
             result(receive_frame(c.socket))

    # A client that lost the reply reconnects and retries (a connection
    # refuses its own recent ids): the same body replays the saved answer,
    # another body under a used id is a rejected outcome.
    {retry, _} = connect(c.path)
    send_frame(retry, patch(uuid(2), 7, 6))
    assert %{"status" => "accepted"} = result(receive_frame(retry))
    send_frame(retry, patch(uuid(3), 9, 7))

    assert %Message{
             type: :response,
             body: %{"response_kind" => "outcome", "value" => %{"status" => "rejected"}}
           } = receive_frame(retry)

    :gen_tcp.close(retry)

    # provider.set_key with a pasted key: answered, never echoed.
    send_frame(c.socket, set_key(uuid(4), c.deepseek.id))
    assert %{"status" => status} = result(receive_frame(c.socket))

    # Without S2's providers handler in the build the action is unsupported.
    if Settings.Providers in Router.loaded_modules(),
      do: assert(status in ["accepted", "unchanged", "rejected", "conflict"]),
      else: assert(status == "unsupported")

    frames = Process.get(:frames)
    assert length(frames) >= 8
    refute Enum.any?(frames, &String.contains?(&1, C74S1.canary()))
  end

  test "a deadline on a settings query and on a command keeps the connection open", c do
    me = self()

    Application.put_env(:swarm_code_daemon, :settings_job_seam, fn kind, _params ->
      send(me, {:held, kind, self()})

      receive do
        :release -> :continue
      end
    end)

    send_frame(c.socket, query(uuid(10), %{"view" => "facts"}, 400))

    assert %Message{type: :error, request_id: id, body: %{"code" => "deadline_expired"}} =
             receive_frame(c.socket, 5_000)

    assert id == uuid(10)
    assert_receive {:held, :query, query_job}, 2_000

    send_frame(c.socket, patch(uuid(11), 7, 6, 400))

    assert %Message{
             type: :response,
             body: %{"response_kind" => "outcome", "value" => %{"status" => "outcome_unknown"}}
           } = receive_frame(c.socket, 5_000)

    assert_receive {:held, :command, command_job}, 2_000
    Application.delete_env(:swarm_code_daemon, :settings_job_seam)
    Enum.each([query_job, command_job], &send(&1, :release))

    # Still open: the next read answers.
    send_frame(
      c.socket,
      query(uuid(12), %{"view" => "values", "keys" => ["limits.max_concurrent_agents"]})
    )

    assert %Message{
             type: :response,
             request_id: next,
             body: %{"response_kind" => "settings_snapshot"}
           } =
             receive_frame(c.socket, 5_000)

    assert next == uuid(12)
  end

  ## -------------------------------------------------------------- frames

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 2_000)

    send_frame(socket, hello())
    assert %Message{type: :hello_ok} = hello_ok = receive_frame(socket)
    {socket, hello_ok}
  end

  defp result(%Message{
         type: :response,
         body: %{"response_kind" => "settings_result", "value" => v}
       }),
       do: v

  defp query(id, params, timeout \\ 15_000) do
    body =
      SwarmCode.Settings.WireBounds.param_keys(:settings_query)
      |> Map.new(&{&1, nil})
      |> Map.merge(params)
      |> Map.merge(%{"op" => "settings.query", "timeout_ms" => timeout})

    request(id, body)
  end

  defp patch(id, value, expected, timeout \\ 15_000) do
    request(id, %{
      "op" => "settings.command",
      "timeout_ms" => timeout,
      "action" => "values.patch",
      "target" => nil,
      "attributes" => %{
        "changes" => [
          %{"key" => "limits.max_concurrent_agents", "value" => value, "target" => nil}
        ]
      },
      "expected" => %{"limits.max_concurrent_agents" => expected},
      "secrets" => [],
      "dry_run" => false
    })
  end

  defp set_key(id, provider_id) do
    request(id, %{
      "op" => "settings.command",
      "timeout_ms" => 15_000,
      "action" => "provider.set_key",
      "target" => %{"id" => provider_id},
      "attributes" => %{"test_first" => false},
      "expected" => %{"key" => %{"set" => true, "hint" => "a1b2"}},
      "secrets" => [%{"slot" => "api_key", "value" => C74S1.canary()}],
      "dry_run" => false
    })
  end

  defp request(id, body),
    do: %Message{
      version: 1,
      type: :request,
      request_id: id,
      nonce: @nonce,
      scope: %Scope{kind: :global, id: nil, generation: 0},
      sequence: nil,
      occurred_at: nil,
      body: body
    }

  defp hello,
    do: %Message{
      version: 1,
      type: :hello,
      request_id: @hello_id,
      nonce: @nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: %{"op" => "hello", "client" => "swarm-code-cli", "body_version" => 1}
    }

  defp uuid(n) do
    hex = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "cccccccc-cccc-4ccc-8ccc-" <> hex
  end

  defp send_frame(socket, message), do: :ok = :gen_tcp.send(socket, Frame.encode!(message))

  # Every frame the daemon writes is kept (raw bytes) for the canary check.
  defp receive_frame(socket, timeout \\ 10_000) do
    {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4, timeout)
    {:ok, bytes} = :gen_tcp.recv(socket, size, timeout)
    Process.put(:frames, [bytes | Process.get(:frames, [])])
    {:ok, message} = Envelope.decode(bytes)
    message
  end
end
