defmodule SwarmCode.Daemon.Hardening.MCPQueueTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log
  alias SwarmCode.Domain.MCP.{Client, Server}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup do
    SwarmCode.Test.C74S2.repo!("mcp-queue")
    :ok
  end

  # pass76 test-flake-audit: a bound on waiting for a message, so a real
  # failure still ends the test. It is never a timing assertion.
  @wait 10_000
  # A caller deadline that does not fire on its own during a test. A deadline
  # of 100-200 ms raced the test's own setup under load (the call expired before
  # the state it was meant to be in was observed), so a test that needs an
  # expired caller moves that call's deadline into the past and delivers the
  # `{:call_deadline, ref}` its timer would send, once the state under test is
  # reached (`expire/2`). The real timer is covered by "a queued caller's own
  # deadline timer expires it".
  @idle 60_000

  for transport <- [:http, :stdio] do
    test "#{transport} handshake queues own dead, expired and live callers" do
      {client, release} = fixture(unquote(transport), :handshake)
      dead = caller(client, "dead", @idle)
      expired = caller(client, "expired", @idle)
      live = caller(client, "live", @idle)
      calls = queued(client, :waiting, 3)
      assert_owners(calls)
      Process.exit(dead, :kill)
      expire(client, Enum.find(calls, &(&1.pid == expired)))
      assert_receive {:reply, ^expired, {:error, "timed out waiting for a response"}}, @wait
      eventually(fn -> map_size(:sys.get_state(client).calls) == 1 end)
      release.()

      assert_receive {:wire, barrier,
                      %{"method" => "tools/call", "params" => %{"name" => "live"}}},
                     @wait

      assert assert_dispatch_owner(client, live) == Enum.find(calls, &(&1.pid == live))
      if unquote(transport) == :http, do: send(barrier, :release), else: release.()
      assert_receive {:reply, ^live, {:ok, "live", []}}, @wait
      refute_receive {:wire, _, %{"method" => "tools/call"}}, 50
      assert_clean(client, calls)
    end
  end

  test "a queued caller's own deadline timer expires it" do
    {client, _release} = fixture(:http, :handshake)
    pid = caller(client, "timer", 150)
    assert_receive {:reply, ^pid, {:error, "timed out waiting for a response"}}, @wait
    assert_clean(client, [])
  end

  test "HTTP session establishment queue retains one owner and original deadline" do
    {client, _release} = fixture(:http, :establish)
    eventually(fn -> GenServer.call(client, :status) == :ready end)
    first = caller(client, "hold", @idle)

    assert_receive {:wire, barrier, %{"method" => "tools/call", "params" => %{"name" => "hold"}}},
                   @wait

    dead = caller(client, "dead", @idle)
    expired = caller(client, "expired", @idle)
    live = caller(client, "live", @idle)
    calls = queued(client, :http_queue, 3)
    assert_owners(calls)
    Process.exit(dead, :kill)
    expire(client, Enum.find(calls, &(&1.pid == expired)))
    assert_receive {:reply, ^expired, {:error, "timed out waiting for a response"}}, @wait
    send(barrier, :release)
    assert_receive {:reply, ^first, {:ok, "hold", []}}, @wait

    assert_receive {:wire, live_barrier,
                    %{"method" => "tools/call", "params" => %{"name" => "live"}}},
                   @wait

    assert assert_dispatch_owner(client, live) == Enum.find(calls, &(&1.pid == live))
    send(live_barrier, :release)
    assert_receive {:reply, ^live, {:ok, "live", []}}, @wait
    refute_receive {:wire, _, %{"method" => "tools/call"}}, 50
    assert_clean(client, calls)
  end

  test "session-expired retry keeps the admission monitor, timer and signed deadline" do
    {client, _release} = fixture(:http, :retry)
    eventually(fn -> GenServer.call(client, :status) == :ready end)
    pid = caller(client, "retry", @idle)
    assert_receive {:wire, barrier, %{"method" => "tools/call"}}, @wait
    state = :sys.get_state(client)
    [original] = Map.values(state.calls)
    assert_owners([original])
    send(barrier, :release)
    assert_receive {:wire, handshake, %{"method" => "initialize"}}, @wait
    eventually(fn -> :sys.get_state(client).handshake.then != nil end)
    state = :sys.get_state(client)
    assert state.handshake.then == {:retry_call, original.ref, {:error, "HTTP 404: "}}
    assert Map.fetch!(state.calls, original.ref) == %{original | retry?: false}
    send(handshake, :release)
    assert_receive {:wire, retry, %{"method" => "tools/call"}}, @wait
    state = :sys.get_state(client)
    assert Map.fetch!(state.calls, original.ref) == %{original | retry?: false}
    assert Process.alive?(original.pid)
    assert original.deadline_ms - System.monotonic_time(:millisecond) > 0
    send(retry, :release)
    assert_receive {:reply, ^pid, {:ok, "retry", []}}, @wait
    assert_clean(client, [original])
    send(client, {:call_deadline, original.ref})
    send(client, {make_ref(), {:mcp_http, 0, {:ok, "stale"}, nil, :ok}})
    assert GenServer.call(client, :status) == :ready
    refute_receive {:reply, ^pid, _}, 50
  end

  for transport <- [:http, :stdio] do
    test "#{transport} reconnect and stop settle handshake admissions once" do
      {client, release} = fixture(unquote(transport), :handshake)
      pid = caller(client, "reconnect", @idle)
      calls = queued(client, :waiting, 1)
      SwarmCode.Domain.MCP.reconnect(:sys.get_state(client).server.id)
      assert_receive {:reply, ^pid, {:error, "reconnecting"}}, @wait
      assert_clean(client, calls)
      if unquote(transport) == :http, do: release.()
      assert_receive {:wire, barrier, %{"method" => "initialize"}}, @wait
      stopped = caller(client, "stopped", @idle)
      calls = queued(client, :waiting, 1)
      port = :sys.get_state(client).port
      os_pid = if port, do: SwarmCode.Domain.OSProcess.port_pid(port)
      GenServer.stop(client)
      assert_receive {:reply, ^stopped, {:error, message}}, @wait
      assert message =~ "stopped"
      for call <- calls, do: assert(Process.read_timer(call.timer) == false)
      if os_pid, do: assert_process_gone(os_pid)
      if unquote(transport) == :http, do: send(barrier, :release)
      refute_receive {:wire, _, %{"method" => "tools/call"}}, 50
    end
  end

  for abandoned <- [:dead, :expired] do
    test "ready result ahead of #{abandoned} notification cannot dispatch" do
      {client, release} = fixture(:http, :handshake)
      pid = caller(client, "abandoned", @idle)
      [call] = queued(client, :waiting, 1)
      :ok = :sys.suspend(client)
      on_exit(fn -> if Process.alive?(client), do: :sys.resume(client) end)
      release.()
      task_ref = :sys.get_state(client).handshake.task.ref

      eventually(fn ->
        {:messages, messages} = Process.info(client, :messages)
        Enum.any?(messages, &match?({^task_ref, {:ok, _}}, &1))
      end)

      if unquote(abandoned) == :dead do
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @wait
      else
        # The ready result is already in the mailbox, so the deadline queues
        # behind it exactly as an expiry that fired just after it would.
        expire(client, call)
      end

      :ok = :sys.resume(client)

      if unquote(abandoned) == :expired do
        assert_receive {:reply, ^pid, {:error, "timed out waiting for a response"}}, @wait
      end

      assert_clean(client, [call])
      refute_receive {:wire, _, %{"method" => "tools/call"}}, 50
      refute_receive {:reply, ^pid, _}, 50
    end

    test "#{abandoned} caller during session recovery never retries" do
      {client, _release} = fixture(:http, :retry)
      eventually(fn -> GenServer.call(client, :status) == :ready end)
      pid = caller(client, "abandoned", @idle)
      assert_receive {:wire, attempt, %{"method" => "tools/call"}}, @wait
      [call] = Map.values(:sys.get_state(client).calls)
      send(attempt, :release)
      assert_receive {:wire, recovery, %{"method" => "initialize"}}, @wait

      if unquote(abandoned) == :dead do
        Process.exit(pid, :kill)
      else
        expire(client, call)
        assert_receive {:reply, ^pid, {:error, "timed out waiting for a response"}}, @wait
      end

      eventually(fn -> :sys.get_state(client).calls == %{} end)
      assert :sys.get_state(client).handshake.then == nil
      send(recovery, :release)
      eventually(fn -> GenServer.call(client, :status) == :ready end)
      assert_clean(client, [call])
      refute_receive {:wire, _, %{"method" => "tools/call"}}, 50
      refute_receive {:reply, ^pid, _}, 50
    end
  end

  test "HTTP task crash settles once and releases the session establishment queue" do
    {client, _release} = fixture(:http, :establish)
    eventually(fn -> GenServer.call(client, :status) == :ready end)
    first = caller(client, "hold", @idle)
    assert_receive {:wire, barrier, %{"method" => "tools/call"}}, @wait
    live = caller(client, "live", @idle)
    queued = queued(client, :http_queue, 1)
    state = :sys.get_state(client)
    [entry] = Map.values(state.http_tasks)
    [original] = Enum.reject(Map.values(state.calls), &(&1.pid == live))
    Process.exit(entry.task.pid, :kill)
    assert_receive {:reply, ^first, {:error, "request failed: :killed"}}, @wait
    send(barrier, :release)

    assert_receive {:wire, live_barrier,
                    %{"method" => "tools/call", "params" => %{"name" => "live"}}},
                   @wait

    assert assert_dispatch_owner(client, live) == hd(queued)
    send(live_barrier, :release)
    assert_receive {:reply, ^live, {:ok, "live", []}}, @wait
    assert_clean(client, [original | queued])
    send(client, {entry.task.ref, {:mcp_http, 0, {:ok, "late"}, nil, :ok}})
    refute_receive {:reply, ^first, _}, 50
  end

  test "active HTTP deadline stops its owned task and replies once" do
    {client, _release} = fixture(:http, :establish)
    eventually(fn -> GenServer.call(client, :status) == :ready end)
    pid = caller(client, "hold", @idle)
    assert_receive {:wire, barrier, %{"method" => "tools/call"}}, @wait
    state = :sys.get_state(client)
    [call] = Map.values(state.calls)
    [entry] = Map.values(state.http_tasks)
    task_down = Process.monitor(entry.task.pid)
    expire(client, call)
    assert_receive {:reply, ^pid, {:error, "timed out waiting for a response"}}, @wait
    assert_receive {:DOWN, ^task_down, :process, _pid, _reason}, @wait
    send(barrier, :release)
    assert_clean(client, [call])
    refute_receive {:reply, ^pid, _}, 50
  end

  for abandoned <- [:dead, :expired] do
    test "active stdio #{abandoned} caller is cancelled without accepting its late response" do
      {client, release} = fixture(:stdio, :handshake)
      release.()
      eventually(fn -> GenServer.call(client, :status) == :ready end)
      pid = caller(client, "hold", @idle)
      assert_receive {:wire, _, %{"method" => "tools/call"}}, @wait
      [call] = Map.values(:sys.get_state(client).calls)

      if unquote(abandoned) == :dead do
        Process.exit(pid, :kill)
      else
        expire(client, call)
        assert_receive {:reply, ^pid, {:error, "timed out waiting for a response"}}, @wait
      end

      eventually(fn -> :sys.get_state(client).calls == %{} end)
      release.()
      assert_receive {:wire, _, %{"method" => "notifications/cancelled"}}, @wait
      live = caller(client, "live", @idle)

      assert_receive {:wire, _, %{"method" => "tools/call", "params" => %{"name" => "live"}}},
                     @wait

      assert_dispatch_owner(client, live)
      release.()
      assert_receive {:reply, ^live, {:ok, "live", []}}, @wait
      assert_clean(client, [call])
      refute_receive {:reply, ^pid, _}, 50
    end
  end

  test "stdio disconnect settles queued callers once and reaps the local server" do
    {client, release} = fixture(:stdio, :disconnect)
    pid = caller(client, "disconnected", @idle)
    calls = queued(client, :waiting, 1)
    os_pid = SwarmCode.Domain.OSProcess.port_pid(:sys.get_state(client).port)
    release.()
    assert_receive {:reply, ^pid, {:error, "process exited with status 7"}}, @wait
    assert_clean(client, calls)
    assert_process_gone(os_pid)
    refute_receive {:wire, _, %{"method" => "tools/call"}}, 50
    refute_receive {:reply, ^pid, _}, 50
  end

  defp caller(client, name, timeout) do
    owner = self()

    spawn(fn ->
      result = GenServer.call(client, {:call_tool, name, %{}, timeout}, timeout + @wait)
      send(owner, {:reply, self(), result})
    end)
  end

  # The state a call is in once its deadline has passed and the timer's message
  # was sent: the signed deadline is in the past (a dispatch checks it) and the
  # `{:call_deadline, ref}` follows. `:sys.replace_state/2` is also handled by a
  # suspended client, so the message queues behind whatever is already in its
  # mailbox, exactly as a timer that fired a moment later would.
  defp expire(client, call) do
    assert is_integer(Process.read_timer(call.timer))
    past = System.monotonic_time(:millisecond) - 1

    :sys.replace_state(client, fn state ->
      %{state | calls: Map.update!(state.calls, call.ref, &%{&1 | deadline_ms: past})}
    end)

    send(client, {:call_deadline, call.ref})
  end

  defp eventually(fun, tries \\ 2_000)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, tries - 1)
        )
  end

  defp queued(client, queue, count) do
    eventually(fn -> :queue.len(Map.fetch!(:sys.get_state(client), queue)) == count end)
    state = :sys.get_state(client)
    calls = Enum.map(:queue.to_list(Map.fetch!(state, queue)), &Map.fetch!(state.calls, &1))
    {:monitors, monitors} = Process.info(client, :monitors)
    for call <- calls, do: assert(Enum.count(monitors, &(&1 == {:process, call.pid})) == 1)
    calls
  end

  defp assert_owners(calls) do
    for call <- calls do
      assert is_reference(call.ref)
      assert is_reference(call.mref)
      assert is_reference(call.timer)
      assert is_integer(call.deadline_ms)
      assert Process.alive?(call.pid)
      assert call.deadline_ms - System.monotonic_time(:millisecond) > 0
    end
  end

  defp assert_dispatch_owner(client, pid) do
    state = :sys.get_state(client)
    call = Enum.find(Map.values(state.calls), &(&1.pid == pid))
    assert_owners([call])
    {:monitors, monitors} = Process.info(client, :monitors)
    assert Enum.count(monitors, &(&1 == {:process, pid})) == 1
    ref = call.ref

    assert Enum.any?(state.pending, &match?({_id, {:call, ^ref}}, &1)) or
             Enum.any?(state.http_tasks, fn {_id, entry} -> entry.call == ref end)

    call
  end

  defp assert_clean(client, calls) do
    eventually(fn -> :sys.get_state(client).calls == %{} end)
    state = :sys.get_state(client)
    assert :queue.is_empty(state.waiting)
    assert :queue.is_empty(state.http_queue)
    assert state.http_tasks == %{}
    {:monitors, monitors} = Process.info(client, :monitors)

    for call <- calls do
      assert Process.read_timer(call.timer) == false
      refute {:process, call.pid} in monitors
      send(client, {:call_deadline, call.ref})
      send(client, {:DOWN, call.mref, :process, call.pid, :normal})
    end

    GenServer.call(client, :status)
    assert :sys.get_state(client).calls == %{}
  end

  defp fixture(:http, mode) do
    owner = self()

    fixture =
      HTTP.start(fn socket, request, _index ->
        if request.method == "POST" do
          json = Jason.decode!(request.body)
          send(owner, {:wire, self(), json})
          method = json["method"]
          name = get_in(json, ["params", "name"])
          initialized = Process.get(:initialized, 0)
          attempts = Process.get(:attempts, 0)

          hold =
            (method == "initialize" and
               (mode == :handshake or (mode == :retry and initialized > 0))) or
              (method == "tools/call" and (name in ["hold", "live"] or mode == :retry))

          if hold do
            receive do
              :release -> :ok
            after
              30_000 -> raise "MCP fixture barrier timed out"
            end
          end

          cond do
            method == "initialize" ->
              Process.put(:initialized, initialized + 1)
              headers = if mode == :retry, do: [{"mcp-session-id", "fixture"}], else: []
              respond(socket, json, %{"protocolVersion" => "2025-06-18"}, headers)

            method == "tools/list" ->
              respond(socket, json, %{"tools" => []})

            method == "tools/call" ->
              Process.put(:attempts, attempts + 1)

              if mode == :retry and attempts == 0 do
                HTTP.respond(socket, 404, "")
              else
                headers =
                  if mode in [:establish, :retry], do: [{"mcp-session-id", "fixture"}], else: []

                respond(
                  socket,
                  json,
                  %{"content" => [%{"type" => "text", "text" => name}]},
                  headers
                )
              end

            true ->
              HTTP.respond(socket, 202, "")
          end
        else
          HTTP.respond(socket, 202, "")
        end
      end)

    on_exit(fn -> HTTP.stop(fixture) end)
    client = start_client(%Server{transport: "http", url: fixture.url})
    assert_receive {:wire, barrier, %{"method" => "initialize"}}, @wait
    {client, fn -> send(barrier, :release) end}
  end

  defp fixture(:stdio, mode) when mode in [:handshake, :disconnect] do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    root = Path.join(System.tmp_dir!(), "mcp-queue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "server.py")

    File.write!(script, """
    import sys, socket, json
    control = socket.create_connection(('127.0.0.1', int(sys.argv[1])))
    for line in sys.stdin:
        msg = json.loads(line)
        control.sendall((json.dumps(msg) + '\\n').encode())
        method = msg.get('method')
        if method == 'initialize':
            if control.recv(1) == b'q':
                sys.exit(7)
            result = {'protocolVersion': '2025-06-18'}
        elif method == 'tools/list':
            result = {'tools': []}
        elif method == 'tools/call':
            if msg['params']['name'] in ['hold', 'live']:
                control.recv(1)
            result = {'content': [{'type': 'text', 'text': msg['params']['name']}]}
        elif method == 'ping':
            result = {}
        else:
            continue
        print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'], 'result': result}), flush=True)
    """)

    owner = self()

    reader =
      spawn_link(fn ->
        accept_stdio(listener, owner)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.unlink(reader)
      monitor = Process.monitor(reader)
      if Process.alive?(reader), do: Process.exit(reader, :shutdown)
      assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 1_000
      File.rm_rf!(root)
    end)

    client =
      start_client(%Server{
        transport: "stdio",
        command: System.find_executable("python3"),
        args: [script, Integer.to_string(port)]
      })

    assert_receive {:control, socket}, @wait
    assert_receive {:wire, _, %{"method" => "initialize"}}, @wait
    {client, fn -> :gen_tcp.send(socket, if(mode == :disconnect, do: "q", else: "x")) end}
  end

  defp respond(socket, json, result, headers \\ []) do
    HTTP.respond(
      socket,
      200,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => json["id"], "result" => result}),
      [{"content-type", "application/json"} | headers]
    )
  end

  defp read_stdio(socket, owner) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, line} ->
        send(owner, {:wire, self(), Jason.decode!(line)})
        read_stdio(socket, owner)

      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp accept_stdio(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(owner, {:control, socket})
        read_stdio(socket, owner)
        accept_stdio(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp assert_process_gone(pid) do
    eventually(fn ->
      {_output, status} = System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "pid="])
      status == 1
    end)
  end

  defp start_client(server) do
    server = %{server | id: Ecto.UUID.generate(), name: "queue-fixture"}
    {:ok, client} = Client.start_link(server)
    Process.unlink(client)

    on_exit(fn ->
      if Process.alive?(client) do
        port = :sys.get_state(client).port
        os_pid = if port, do: SwarmCode.Domain.OSProcess.port_pid(port)
        GenServer.stop(client)
        if os_pid, do: assert_process_gone(os_pid)
      end
    end)

    client
  end
end
