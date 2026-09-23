defmodule SwarmCode.Domain.MCP.Client do
  @moduledoc """
  One connection to an MCP server (JSON-RPC 2.0 over stdio or streamable HTTP).

  The handshake (`initialize` → `notifications/initialized` → `tools/list`) is
  serialised: it runs inside `handle_info(:connect, …)` with a blocking receive,
  so nothing else is in flight while it happens. The discovered tools land in the
  shared ETS table so every agent can call them.

  Steady-state `tools/call` requests may be concurrent: each one is registered in
  `pending` under its JSON-RPC id and answered through `GenServer.reply/2` when
  the matching id comes back (stdio) or when its `Task` finishes (HTTP), so a
  slow call never blocks a fast one. Replies are correlated by id only — a late
  answer for a request that already timed out is dropped, and no caller is ever
  replied to twice.

  Stdio servers are terminated as a process tree (`SwarmCode.Domain.OSProcess`), because
  `npx`/`uvx`/`sh -c` wrappers leave the real server as a grandchild.
  """
  use GenServer, restart: :transient
  require Logger

  alias SwarmCode.Domain.LLM.SSE
  alias SwarmCode.Domain.MCP
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Tools.RunCommand

  @protocol_version "2025-06-18"
  @client_info %{"name" => "SwarmCode", "version" => "0.1.0"}
  @handshake_timeout 30_000
  # spec 60 T12: an HTTP body past this is refused; `tools/list` stops after this many pages.
  @max_http_body 16_000_000
  # spec 73 T14: a stdio line past this fails the transport, the way an HTTP
  # body past `@max_http_body` is refused — the bound is enforced while reading.
  @max_stdio_buffer 16_000_000
  @max_tool_pages 50
  @backoff [5_000, 15_000, 60_000]

  def start_link(%Server{} = server),
    do:
      GenServer.start_link(__MODULE__, server, name: MCP.via(server.id), hibernate_after: 15_000)

  def child_spec(%Server{} = server) do
    %{
      id: {__MODULE__, server.id},
      start: {__MODULE__, :start_link, [server]},
      restart: :transient
    }
  end

  @doc "Connects, lists the tools and disconnects again — used by Settings → Test."
  @spec probe(Server.t()) :: {:ok, [map()]} | {:error, String.t()}
  def probe(%Server{} = server) do
    state = new_state(server)

    case open(state) do
      {:ok, state} ->
        # spec 60 T17: a raise inside the handshake used to skip `close/1` and
        # leak the stdio child tree.
        # spec 61 T4: `close/1` needs the state the handshake produced, not the
        # one it started from — the session to delete is only learned in there.
        {result, state} =
          try do
            case handshake(state) do
              {:ok, state} -> {{:ok, state.tools}, state}
              {:error, reason, state} -> {{:error, safe(state, reason)}, state}
            end
          rescue
            e -> {{:error, safe(state, "malformed response: " <> Exception.message(e))}, state}
          catch
            kind, value ->
              close(state)
              :erlang.raise(kind, value, __STACKTRACE__)
          end

        close(state)
        result

      {:error, reason} ->
        {:error, safe(state, reason)}
    end
  end

  ## ------------------------------------------------------------------ server

  @impl true
  def init(%Server{} = server) do
    # Sakana task 10: without trapping exits a supervisor shutdown skips
    # `terminate/2`, so the subprocess tree was never reaped on stop/disable.
    Process.flag(:trap_exit, true)
    MCP.ensure_tables()
    send(self(), :connect)
    {:ok, new_state(server)}
  end

  defp new_state(server) do
    %{
      server: server,
      # Spec 33 §3: the configured values that must never come back out in an
      # error, a tool result, a status or a log.
      secrets: Server.secrets(server),
      port: nil,
      # spec 73 T14: the bytes of an incomplete stdio line, newest part first,
      # joined only when a newline arrives — `buffer <> data` re-copied and
      # re-split the whole accumulation on every 64 KB port chunk.
      buffer: [],
      buffer_size: 0,
      next_id: 1,
      tools: [],
      session_id: nil,
      # spec 61 T3: the version the server negotiated in the initialize result.
      # MCP 2025-06-18 wants it back on every later HTTP request; `nil` until
      # the handshake is past its first step, so `initialize` itself is clean.
      protocol_version: nil,
      attempt: 0,
      status: :connecting,
      # Sakana task 11: HTTP calls that arrive before a session exists wait
      # here while exactly one request establishes it, so two concurrent calls
      # cannot create (or pick) two different sessions.
      http_queue: :queue.new(),
      http_establishing?: false,
      http_stateless?: false,
      # spec 60 T11: bumped on every `:connect`; a settle from an older generation is ignored.
      http_gen: 0,
      # Spec 13 §11 A-9: JSON-RPC id => {caller, timeout timer} of the calls
      # that are in flight right now. Spec 51 §7.8: a health-check ping sits
      # here too, under `{:ping, timer}` — nobody is waiting for its answer.
      pending: %{},
      # The id of the one ping that may be in flight (spec 51 §7.8, R21).
      ping: nil,
      # spec 67 T8 (B11): the armed backoff `:connect`, so a reconnect that
      # overtakes it (Settings → Reconnect, a second failure) can cancel it.
      connect_timer: nil,
      # spec 67 T28 (G37): the server's own diagnostics — `notifications/message`
      # and, on stdio, whatever it wrote to stderr. Newest first, capped at
      # `@output_lines`; mirrored into the MCP output table so Settings can read
      # it without calling a client that is busy with a two-minute tool call.
      output: []
    }
  end

  # spec 67 T28 (G37): a 20-line ring buffer is what a diagnostic is worth — it
  # is the last thing the server said before it broke, not a log file.
  @output_lines 20

  defp push_output(state, line) when is_binary(line) do
    line = state |> safe(line) |> String.trim_trailing() |> String.slice(0, 2_000)

    if line == "" do
      state
    else
      output = Enum.take([line | state.output], @output_lines)
      MCP.put_output(state.server.id, output)
      %{state | output: output}
    end
  end

  defp push_output(state, _other), do: state

  @impl true
  def handle_info(:connect, state) do
    # spec 36 §A3: every caller waiting on the connection we are about to drop
    # is answered here, first. Otherwise their `{:request_timeout, id}` timers
    # outlive the reconnect and, ~120 s later, tear down the *new* connection.
    # spec 60 T11: queued HTTP callers are answered too, and the generation moves on.
    # spec 67 T8 (B11): the backoff's own `:connect` goes first — a manual
    # reconnect during the backoff used to succeed and be torn down by it
    # seconds later, re-handshaking a healthy connection.
    state =
      state
      |> cancel_connect_timer()
      |> fail_pending("reconnecting")
      |> fail_http_queue("reconnecting")
      |> close()
      |> Map.update!(:http_gen, &(&1 + 1))

    MCP.put_status(state.server.id, :connecting)

    case open(%{state | status: :connecting}) do
      {:ok, state} ->
        case handshake(state) do
          {:ok, state} ->
            MCP.put_tools(state.server, state.tools)
            MCP.put_status(state.server.id, :ready)
            {:noreply, %{state | status: :ready, attempt: 0}}

          {:error, reason, state} ->
            {:noreply, fail(state, reason)}
        end

      {:error, reason} ->
        {:noreply, fail(state, reason)}
    end
  end

  # The stdio process died while we were idle.
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    reason = "process exited with status #{code}"
    state = fail_pending(%{state | port: nil}, reason)
    {:noreply, fail(state, reason)}
  end

  # Spec 13 §11 A-9: every answer of an in-flight `tools/call` arrives here.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case stdio_lines(state, data) do
      {:ok, messages, state} ->
        {:noreply, Enum.reduce(messages, state, &handle_line/2)}

      # spec 73 T14: one line over the cap is a broken server, not a big result.
      {:error, reason, state} ->
        state = fail_pending(state, reason)
        {:noreply, fail(state, reason)}
    end
  end

  # Sakana task 9: a stdio child that never answers used to leave the client
  # `:ready` for ever — the caller got its timeout and the wedged subprocess
  # kept the connection "healthy". The caller still gets the exact timeout, then
  # the transport fails, the subprocess tree is reaped and the backoff reconnects.
  def handle_info({:request_timeout, id}, state) do
    # spec 36 §A3: `Process.cancel_timer/1` cannot recall a message that is
    # already in the mailbox, so a late reply — or a reconnect that failed the
    # request first — leaves a timeout for an id nobody waits on. Acting on it
    # would kill a healthy connection.
    if Map.has_key?(state.pending, id) do
      reason = "timed out waiting for a response"
      state = reply_pending(state, id, {:error, reason})

      case state.server.transport do
        # Spec 51 §7.8 (R21): one slow-but-healthy tool used to answer "timed
        # out" to EVERY pending caller, kill the server tree, forget its tools
        # and back off 5/15/60 s. The caller that waited is answered — as HTTP
        # always did — and the transport is asked whether it is still there.
        "stdio" -> {:noreply, send_ping(state)}
        _other -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # The server never answered the ping either: it is wedged, so this is the old
  # behaviour — every caller gets its error and the subprocess tree is reaped.
  def handle_info({:ping_timeout, id}, state) do
    if Map.has_key?(state.pending, id) do
      reason = "the server stopped responding"
      state = fail_pending(state, reason)
      {:noreply, fail(state, reason)}
    else
      {:noreply, state}
    end
  end

  # Sakana task 11: one HTTP round trip finished. The session it learned (if
  # any) is adopted before the queued calls go out, and only a *transport*
  # failure reconnects — application-level error text never does.
  # spec 60 T11: only a settle of the current generation is read; a conflicting
  # session answers the queued callers instead of dropping them; a malformed
  # reply never marks the server stateless.
  def handle_info({:http_settled, gen, session_id, outcome}, %{http_gen: gen} = state) do
    case merge_session(state, session_id) do
      {:error, reason} ->
        {:noreply, fail(fail_http_queue(%{state | http_establishing?: false}, reason), reason)}

      {:ok, state} ->
        state = %{state | http_establishing?: false}

        state =
          if is_nil(state.session_id) and is_nil(session_id) and outcome == :ok,
            do: %{state | http_stateless?: true},
            else: state

        case outcome do
          {:transport_error, reason} ->
            {:noreply, fail(fail_http_queue(state, reason), reason)}

          # spec 61 T1: a revoked token is not fixed by waiting — the tools go,
          # the status says why, and nothing reconnects until Settings asks.
          {:permanent, reason} ->
            {:noreply, fail(fail_http_queue(state, reason), reason, permanent: true)}

          # spec 61 T1: one refused call (429, 5xx, a client-side timeout) is the
          # caller's problem, not the connection's: it keeps its status and tools.
          _ok_or_call_error_or_malformed ->
            {:noreply, drain_http_queue(state)}
        end
    end
  end

  # spec 60 T11: a settle from before the last reconnect.
  def handle_info({:http_settled, _gen, _session, _outcome}, state), do: {:noreply, state}

  # spec 61 T1: the server forgot our session (404/410). Re-initialize right
  # away — no backoff, no forgotten tools — and give the call one more try.
  def handle_info({:http_session_expired, gen, call, error}, %{http_gen: gen} = state) do
    {from, method, params, timeout} = call

    state = %{
      state
      | http_establishing?: false,
        session_id: nil,
        protocol_version: nil,
        http_stateless?: false
    }

    case handshake(state) do
      {:ok, state} ->
        MCP.put_tools(state.server, state.tools)
        MCP.put_status(state.server.id, :ready)
        state = %{state | status: :ready, attempt: 0}
        state = dispatch_http(state, from, method, params, timeout, false)
        {:noreply, drain_http_queue(state)}

      {:error, reason, state} ->
        GenServer.reply(from, error)
        {:noreply, fail(fail_http_queue(state, reason), reason)}
    end
  end

  # A reconnect overtook the retry: the caller gets the error it already had.
  def handle_info({:http_session_expired, _gen, {from, _m, _p, _t}, error}, state) do
    GenServer.reply(from, error)
    {:noreply, state}
  end

  # spec 62 T1: the owner switched a tool on or off. The cached row is the one a
  # reconnect republishes from, so it has to learn the new set without a restart.
  def handle_info({:tools_toggled, disabled}, state) when is_list(disabled) do
    {:noreply, %{state | server: %{state.server | disabled_tools: disabled}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## ----------------------------------------------- notifications (spec 67 T28)

  # spec 67 T28 (G37): every JSON-RPC message without an integer `id` used to be
  # dropped on the floor, so a server's own log lines, its warnings and the
  # `tools/list_changed` that says its catalogue moved reached nobody. A line
  # that is not JSON at all is the stdio child's stderr (`:stderr_to_stdout`).
  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{} = json} -> dispatch(state, json)
      {:ok, _other} -> state
      _error -> push_output(state, line)
    end
  end

  # spec 73 T78: a message carrying both `id` and `method` is a request *from*
  # the server (`ping`, which an MCP server may send without any capability
  # negotiation). It used to match the reply clause when its id collided with
  # a pending call — answering that caller "unexpected response" — and was
  # never answered otherwise. It is answered first, so it can never be a reply.
  defp dispatch(state, %{"id" => id, "method" => method}) when not is_nil(id),
    do: server_request(state, id, method)

  defp dispatch(state, %{"id" => id} = json) when is_integer(id),
    do: reply_pending(state, id, json)

  defp dispatch(state, %{"method" => method} = json),
    do: notification(state, method, json["params"] || %{})

  defp dispatch(state, _other), do: state

  defp server_request(state, id, "ping"),
    do: send_json(state, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}})

  defp server_request(state, id, method) do
    name = if is_binary(method), do: method, else: inspect(method)

    send_json(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "method not found: " <> name}
    })
  end

  defp send_json(%{port: nil} = state, _message), do: state

  defp send_json(state, message) do
    Port.command(state.port, Jason.encode!(message) <> "\n")
    state
  end

  @doc false
  def log_line(%{"level" => level, "data" => data}) when is_binary(level),
    do: "[" <> level <> "] " <> log_data(data)

  def log_line(params), do: log_data(params)

  defp log_data(data) when is_binary(data), do: data
  defp log_data(%{"message" => message}) when is_binary(message), do: message
  defp log_data(data), do: Jason.encode!(data)

  defp notification(state, "notifications/message", params) do
    line = log_line(params)
    Logger.info("swarm_code mcp #{state.server.name}: " <> safe(state, line))
    push_output(state, line)
  end

  # The server republished its catalogue. spec 73 T15: `tools/list` used to be
  # re-issued in place, blocking on the port from inside `handle_info` — and
  # `await_stdio/3` dropped every reply whose id was not the one it waited
  # for, so a worker's in-flight `tools/call` answer that landed during the
  # re-list was lost and that worker waited its full timeout. The re-list now
  # rides the pending map like a tool call, page by page, and finishes in
  # `reply_pending/3`; nothing blocks while calls are in flight. Only stdio
  # reaches here (`handle_line/2` and `await_stdio/3` read the port).
  defp notification(
         %{status: :ready, server: %Server{transport: "stdio"}} = state,
         "notifications/tools/list_changed",
         _params
       ) do
    list_tools_async(state, nil, [], MapSet.new(), 1)
  end

  defp notification(state, _method, _params), do: state

  # spec 73 T15: one `tools/list` page as a pending request; the accumulator
  # rides in the pending entry and `list_tools_page/3` resumes from there.
  defp list_tools_async(state, cursor, acc, seen, pages) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    start_request(
      state,
      {:list_tools, {acc, seen, pages}},
      "tools/list",
      params,
      @handshake_timeout
    )
  end

  defp list_tools_page(state, {acc, seen, pages}, {:ok, result}) do
    case next_tools_page(state, result, acc, seen, pages) do
      {:done, tools} -> publish_tools(state, tools)
      {:more, next, acc, seen, pages} -> list_tools_async(state, next, acc, seen, pages)
    end
  end

  defp list_tools_page(state, _ctx, {:error, reason}),
    do: push_output(state, "tools/list_changed failed: " <> to_string(reason))

  defp publish_tools(state, tools) do
    state = %{state | tools: tools}
    MCP.put_tools(state.server, tools)
    MCP.broadcast()
    push_output(state, "tools/list_changed: #{length(tools)} tools")
  end

  defp rpc_reply(state, %{"result" => result}), do: tool_result(state, result)
  defp rpc_reply(state, %{"error" => err}), do: {:error, rpc_error(state, err)}
  defp rpc_reply(_state, _other), do: {:error, "unexpected response"}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}

  # Spec 13 §11 A-9: a tool call used to hold this GenServer for up to two
  # minutes, so a second concurrent call died on the client-side call timeout
  # with a misleading "MCP server is not connected". The request is now in
  # flight while the process keeps answering; the answer comes back through
  # `GenServer.reply/2`.
  def handle_call({:call_tool, tool_name, args, timeout}, from, state) do
    params = %{"name" => tool_name, "arguments" => args || %{}}

    if state.status != :ready do
      {:reply, {:error, "MCP server #{state.server.name} is not connected"}, state}
    else
      {:noreply, start_request(state, from, "tools/call", params, timeout)}
    end
  end

  # One in-flight `tools/call`. stdio keeps the port in this process (only the
  # owner may read it) and matches the JSON-RPC id when the line arrives; HTTP
  # does its round trip in a Task.
  defp start_request(
         %{server: %Server{transport: "stdio"}} = state,
         from,
         method,
         params,
         timeout
       ) do
    id = state.next_id
    state = %{state | next_id: id + 1}

    if state.port == nil do
      answer(state, from, {:error, "not connected"})
    else
      Port.command(
        state.port,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <>
          "\n"
      )

      timer = Process.send_after(self(), {:request_timeout, id}, timeout)
      %{state | pending: Map.put(state.pending, id, {from, timer})}
    end
  end

  defp start_request(%{server: %Server{transport: "http"}} = state, from, method, params, timeout) do
    cond do
      state.session_id != nil or state.http_stateless? ->
        dispatch_http(state, from, method, params, timeout)

      state.http_establishing? ->
        %{state | http_queue: :queue.in({from, method, params, timeout}, state.http_queue)}

      true ->
        dispatch_http(%{state | http_establishing?: true}, from, method, params, timeout)
    end
  end

  # spec 61 T1: `retry?` is false for the one retry a re-handshake allows itself,
  # so a server that 404s for ever cannot loop through initialize.
  defp dispatch_http(state, from, method, params, timeout, retry? \\ true) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    client = self()
    gen = state.http_gen
    # spec 73 T81: only what the round trip reads — `send_message/4`,
    # `base_headers/1`, `remember_session/2`, `safe/2` and `learned/2` — is
    # copied into the task; the tool catalogue and the output ring stay here.
    snapshot =
      Map.take(state, [:server, :secrets, :session_id, :protocol_version, :http_stateless?])

    # spec 67 T8 (B12): the settle reports only a session this call *learned*.
    # Echoing the snapshot's own id back was read, once a concurrent call had
    # re-established the session, as "conflicting mcp-session-id" — and that
    # failed a connection that was fine.
    had = snapshot.session_id

    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
      # spec 60 T11: a raise in here used to leave the caller waiting for its whole
      # timeout and `http_establishing?` true for ever.
      {result, session, outcome} =
        try do
          case send_message(snapshot, request_message(id, method, params), id, timeout) do
            {:ok, %{"result" => result}, new_state} ->
              {tool_result(new_state, result), learned(had, new_state.session_id), :ok}

            {:ok, %{"error" => err}, new_state} ->
              {{:error, rpc_error(new_state, err)}, learned(had, new_state.session_id), :ok}

            {:ok, _other, new_state} ->
              {{:error, "unexpected response to #{method}"}, learned(had, new_state.session_id),
               :ok}

            {:error, reason, class, new_state} ->
              class = if class == :session_expired and not retry?, do: :call_error, else: class
              {{:error, reason}, learned(had, new_state.session_id), {class, reason}}
          end
        rescue
          e ->
            {{:error, safe(snapshot, "malformed response: " <> Exception.message(e))}, nil,
             {:malformed, Exception.message(e)}}
        end

      case outcome do
        # The caller is not answered yet: the client re-handshakes and calls again.
        {:session_expired, _reason} ->
          send(client, {:http_session_expired, gen, {from, method, params, timeout}, result})

        _settled ->
          GenServer.reply(from, result)
          send(client, {:http_settled, gen, session, outcome})
      end
    end)

    state
  end

  # spec 67 T8 (B12): `nil` unless the round trip changed the id it went out
  # with — `merge_session(state, nil)` is the no-op, so a call that started
  # under a since-retired session settles without a word about it.
  defp learned(had, had), do: nil
  defp learned(_had, new), do: new

  # The response carried a session id: adopt it, unless the server contradicts
  # one we already have — that is a protocol failure, not a silent overwrite.
  defp merge_session(state, nil), do: {:ok, state}

  defp merge_session(%{session_id: nil} = state, id) when is_binary(id),
    do: {:ok, %{state | session_id: id}}

  defp merge_session(%{session_id: same} = state, same), do: {:ok, state}

  defp merge_session(_state, _other), do: {:error, "conflicting mcp-session-id"}

  defp drain_http_queue(state) do
    case :queue.out(state.http_queue) do
      {{:value, {from, method, params, timeout}}, rest} ->
        state = %{state | http_queue: rest}
        state = dispatch_http(state, from, method, params, timeout)
        drain_http_queue(state)

      {:empty, _rest} ->
        state
    end
  end

  defp fail_http_queue(state, reason) do
    state.http_queue
    |> :queue.to_list()
    |> Enum.each(fn {from, _method, _params, _timeout} ->
      GenServer.reply(from, {:error, reason})
    end)

    %{state | http_queue: :queue.new()}
  end

  defp request_message(id, method, params),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

  # Spec 51 §7.8 (R21): a JSON-RPC `ping` the client sent itself after a request
  # timeout. Any answer at all — a result or a `method not found` error — proves
  # the transport is alive; the reply itself is thrown away. One at a time, and
  # never when there is no port to write to. The 10 s wait is overridable the
  # same way `@backoff` is, so a test does not have to sit through it.
  @ping_timeout 10_000

  defp ping_timeout, do: Application.get_env(:swarm_code_daemon, :mcp_ping_timeout, @ping_timeout)

  defp send_ping(%{ping: ping} = state) when ping != nil, do: state

  defp send_ping(%{port: nil} = state) do
    reason = "not connected"
    state |> fail_pending(reason) |> fail(reason)
  end

  defp send_ping(state) do
    id = state.next_id
    state = %{state | next_id: id + 1}

    Port.command(
      state.port,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}) <> "\n"
    )

    timer = Process.send_after(self(), {:ping_timeout, id}, ping_timeout())
    %{state | pending: Map.put(state.pending, id, {:ping, timer}), ping: id}
  end

  # `reply` is the decoded JSON-RPC message, or `{:error, reason}` from a
  # timeout or a failed transport. spec 73 T15: the entry may be a re-list
  # page (`{:list_tools, ctx}`) instead of a caller.
  defp reply_pending(state, id, reply) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{:ping, timer}, pending} ->
        Process.cancel_timer(timer)
        %{state | pending: pending, ping: nil}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        answer(%{state | pending: pending}, from, reply)
    end
  end

  # spec 73 T15: what a finished request does with its reply — a caller is
  # answered with the tool result, a re-list page is folded into the catalogue.
  defp answer(state, {:list_tools, ctx}, reply),
    do: list_tools_page(state, ctx, list_reply(state, reply))

  defp answer(state, from, reply) do
    GenServer.reply(from, call_reply(state, reply))
    state
  end

  defp call_reply(state, %{} = json), do: rpc_reply(state, json)
  defp call_reply(_state, {:error, _reason} = error), do: error

  defp list_reply(_state, %{"result" => result}), do: {:ok, result}
  defp list_reply(state, %{"error" => err}), do: {:error, rpc_error(state, err)}
  defp list_reply(_state, {:error, _reason} = error), do: error
  defp list_reply(_state, _other), do: {:error, "unexpected response to tools/list"}

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn
      {_id, {:ping, timer}} ->
        Process.cancel_timer(timer)

      {_id, {{:list_tools, _ctx}, timer}} ->
        Process.cancel_timer(timer)

      {_id, {from, timer}} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}, ping: nil}
  end

  @impl true
  def terminate(_reason, state) do
    close(state)
    MCP.forget(state.server.id)
    :ok
  end

  # spec 60 T13: a crash report prints the whole GenServer state — the configured
  # keys and headers live in `secrets`, so they never go into the log.
  @impl true
  def format_status(%{state: %{secrets: _} = state} = status),
    do: %{status | state: %{state | secrets: :redacted}}

  def format_status(status), do: status

  ## --------------------------------------------------------------- handshake

  defp handshake(state) do
    params = %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => @client_info
    }

    with {:ok, info, state} <- request(state, "initialize", params, @handshake_timeout),
         # spec 61 T3: from here on every HTTP request carries the negotiated version.
         state = %{state | protocol_version: negotiated_version(info)},
         state <- notify(state, "notifications/initialized", %{}),
         {:ok, tools, state} <- list_tools(state, nil, []) do
      {:ok, %{state | tools: tools}}
    else
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  # spec 61 T3: a server that answers without one gets the version we asked for.
  defp negotiated_version(%{"protocolVersion" => v}) when is_binary(v) and v != "", do: v
  defp negotiated_version(_info), do: @protocol_version

  # spec 60 T12: a repeated cursor or a run past @max_tool_pages keeps what it has.
  # The blocking form, used by the handshake (nothing else is in flight then).
  defp list_tools(state, cursor, acc, seen \\ MapSet.new(), pages \\ 1) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case request(state, "tools/list", params, @handshake_timeout) do
      {:ok, result, state} ->
        case next_tools_page(state, result, acc, seen, pages) do
          {:done, tools} -> {:ok, tools, state}
          {:more, next, acc, seen, pages} -> list_tools(state, next, acc, seen, pages)
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # spec 73 T15: one page of `tools/list`, shared by the handshake's blocking
  # walk and the re-list's pending-map walk.
  defp next_tools_page(state, %{"tools" => tools} = result, acc, seen, pages)
       when is_list(tools) do
    acc = acc ++ tools

    case result["nextCursor"] do
      next when is_binary(next) and next != "" ->
        if MapSet.member?(seen, next) or pages >= @max_tool_pages do
          Logger.warning(
            "swarm_code mcp #{state.server.name}: tools/list cursor #{inspect(next)} " <>
              "repeated or over #{@max_tool_pages} pages — keeping #{length(acc)} tools"
          )

          {:done, acc}
        else
          {:more, next, acc, MapSet.put(seen, next), pages + 1}
        end

      _ ->
        {:done, acc}
    end
  end

  defp next_tools_page(_state, _other, acc, _seen, _pages), do: {:done, acc}

  ## ---------------------------------------------------------------- requests

  defp request(state, method, params, timeout) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case send_message(state, message, id, timeout) do
      {:ok, %{"result" => result}, state} -> {:ok, result, state}
      {:ok, %{"error" => err}, state} -> {:error, rpc_error(state, err), state}
      {:ok, _other, state} -> {:error, "unexpected response to #{method}", state}
      # spec 61 T1: the handshake fails the same way whatever the class is.
      {:error, reason, _class, state} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  # One boundary: everything that leaves this module as text goes through it.
  defp safe(%{secrets: secrets}, text), do: SwarmCode.Domain.LLM.HTTP.redact(text, secrets)
  defp safe(_state, text), do: SwarmCode.Domain.LLM.HTTP.redact(text)

  defp rpc_error(state, %{"code" => code, "message" => message}) when is_binary(message),
    do: safe(state, "#{code} #{message}")

  # spec 60 T11: a message that is not text is shown, not interpolated (which raised).
  defp rpc_error(state, %{"code" => code, "message" => message}),
    do: safe(state, "#{code} #{inspect(message)}")

  defp rpc_error(state, other), do: safe(state, inspect(other))

  ## ------------------------------------------------------------------- stdio

  defp open(%{server: %Server{transport: "stdio"} = server} = state) do
    executable = System.find_executable(server.command)

    cond do
      is_nil(executable) ->
        {:error, "command not found: #{server.command}"}

      true ->
        try do
          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :exit_status,
              {:args, server.args || []},
              {:env, env(server)},
              {:cd, String.to_charlist(cwd(server))},
              # spec 67 T28 (G37): a stdio server's stderr is where it says it
              # could not find its config, its token expired or it is about to
              # exit. It went to the void; it is now read as ordinary port data
              # and every line that is not JSON-RPC lands in the ring buffer.
              :stderr_to_stdout
            ])

          {:ok, %{state | port: port, buffer: [], buffer_size: 0}}
        rescue
          e -> {:error, "could not start #{server.command}: " <> Exception.message(e)}
        end
    end
  end

  # spec 60 T11: a reconnect drops the dead session and the flags that described it.
  # spec 61 T3: and the version that session negotiated.
  defp open(%{server: %Server{transport: "http"}} = state),
    do:
      {:ok,
       %{
         state
         | session_id: nil,
           protocol_version: nil,
           http_stateless?: false,
           http_establishing?: false
       }}

  # spec 61 T4: an HTTP session is a server-side resource — close, disable,
  # delete, reconnect and the Settings → Test probe all end it explicitly
  # (`DELETE <url>` with the session header). Best effort: it runs in a task, so
  # it never blocks this process, and every error is ignored.
  defp close(%{server: %Server{transport: "http"}, session_id: id} = state) when is_binary(id) do
    delete_session(state)
    %{state | session_id: nil, protocol_version: nil, http_stateless?: false}
  end

  defp close(%{port: nil} = state), do: state

  # Spec 13 §11 A-8: `Port.close/1` only detaches the port — the stdio child
  # kept running, so every reconnect orphaned another server process.
  #
  # Sakana task 10: `kill -9 <os_pid>` only reached the wrapper. `npx`, `uvx`
  # and `sh -c` all leave the real server as a grandchild, so the whole tree is
  # signalled (TERM, then KILL) before the port is detached.
  defp close(%{port: port} = state) do
    port |> SwarmCode.Domain.OSProcess.port_pid() |> SwarmCode.Domain.OSProcess.kill_tree()

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    %{state | port: nil, buffer: [], buffer_size: 0}
  end

  defp env(server) do
    extra =
      for {k, v} <- server.env || %{},
          do: {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}

    RunCommand.clean_env() ++ extra
  end

  defp cwd(server) do
    with id when is_binary(id) <- server.project_id,
         %{root_path: root} <- SwarmCode.Domain.Projects.get(id),
         true <- File.dir?(root) do
      root
    else
      _ -> System.user_home!()
    end
  end

  defp send_message(%{server: %Server{transport: "stdio"}} = state, message, id, timeout) do
    if state.port == nil do
      {:error, "not connected", state}
    else
      Port.command(state.port, Jason.encode!(message) <> "\n")
      await_stdio(state, id, System.monotonic_time(:millisecond) + timeout)
    end
  end

  # spec 61 T1: every HTTP failure leaves here classified, so the settle handler
  # never has to read the error text to decide whether the transport died.
  # `{:error, reason, class, state}`, where class is one of
  # `:call_error` (answer this caller, keep the connection), `:session_expired`
  # (re-handshake and retry once), `:permanent` (a revoked token: fail, no
  # reconnect) or `:transport_error` (fail with the backoff, as before).
  defp send_message(%{server: %Server{transport: "http"} = server} = state, message, id, timeout) do
    # spec 60 T10: no credentialed redirect across origins. spec 60 T12: the body is
    # collected bounded, and an SSE stream is halted on the correlated event.
    case Req.post(SwarmCode.Domain.LLM.HTTP.request(server.url),
           json: message,
           headers: base_headers(state),
           retry: false,
           receive_timeout: timeout,
           decode_body: false,
           into: mcp_collector(id)
         ) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        state = remember_session(state, resp)

        if resp.private[:skip] == :length do
          {:error, safe(state, "response over 16 MB"), :call_error, state}
        else
          case decode_response(resp, id) do
            {:ok, json} -> {:ok, json, state}
            :none -> {:error, "no response for request #{id}", :call_error, state}
          end
        end

      {:ok, %Req.Response{status: status} = resp} ->
        reason = safe(state, "HTTP #{status}: " <> snippet(body_of(resp)))
        {:error, reason, http_class(status, state.session_id), state}

      # spec 61 T2: both transports say "timed out" the same way, so
      # `Tools.with_limit_hint/2` points at Settings → Limits → Tool timeout.
      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, "timed out waiting for a response after #{timeout} ms", :call_error, state}

      {:error, exception} ->
        reason = safe(state, "request failed: " <> Exception.message(exception))
        {:error, reason, :transport_error, state}
    end
  end

  # spec 61 T1: the status table of the spec, in one place.
  defp http_class(status, session_id) do
    cond do
      status in [401, 403] -> :permanent
      status in [404, 410] and is_binary(session_id) -> :session_expired
      status >= 400 -> :call_error
      true -> :transport_error
    end
  end

  # spec 61 T3: `MCP-Protocol-Version` rides on every request after initialize.
  defp base_headers(%{server: server} = state) do
    [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
      Enum.map(server.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end) ++
      if(state.session_id, do: [{"mcp-session-id", state.session_id}], else: []) ++
      if(state.protocol_version,
        do: [{"mcp-protocol-version", state.protocol_version}],
        else: []
      )
  end

  # spec 61 T4: fire-and-forget; the caller is never held up and a failure here
  # changes nothing (the session is gone for us either way).
  defp delete_session(%{server: server} = state) do
    headers = base_headers(state)

    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
      try do
        Req.delete(SwarmCode.Domain.LLM.HTTP.request(server.url),
          headers: headers,
          retry: false,
          receive_timeout: 2_000,
          decode_body: false
        )
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  catch
    # the task supervisor is already down (application shutdown)
    _, _ -> :ok
  end

  defp remember_session(state, resp) do
    case Req.Response.get_header(resp, "mcp-session-id") do
      [id | _] -> %{state | session_id: id}
      _ -> state
    end
  end

  # spec 60 T12: the collector may already hold the correlated reply; the post-EOF
  # scan of the whole body stays as the fallback.
  defp decode_response(resp, id) do
    case resp.private[:reply] do
      %{} = json -> {:ok, json}
      _ -> decode_body(resp, id)
    end
  end

  defp decode_body(resp, id) do
    body = body_of(resp)

    if sse?(resp) do
      {events, _rest} = SSE.parse("", body)

      Enum.find_value(events, :none, fn event ->
        case Jason.decode(event.data) do
          {:ok, %{"id" => ^id} = json} -> {:ok, json}
          _ -> nil
        end
      end)
    else
      case Jason.decode(body) do
        {:ok, %{"id" => ^id} = json} ->
          {:ok, json}

        {:ok, [_ | _] = list} ->
          Enum.find_value(list, :none, fn
            %{"id" => ^id} = json -> {:ok, json}
            _ -> nil
          end)

        _ ->
          :none
      end
    end
  end

  # spec 60 T12: bytes stay in `resp.private`; SSE halts on the correlated event; over the cap → :skip.
  # spec 73 T42: as a reversed parts list with a running byte count — the
  # previous body was referenced from the private map, so `body <> chunk`
  # copied the accumulation on every chunk; `body_of/1` joins once.
  defp mcp_collector(id) do
    fn {:data, chunk}, {req, resp} ->
      parts = [chunk | resp.private[:body_parts] || []]
      size = (resp.private[:body_size] || 0) + byte_size(chunk)

      cond do
        size > @max_http_body ->
          {:halt, {req, Req.Response.put_private(resp, :skip, :length)}}

        sse?(resp) ->
          {events, rest} = SSE.parse(resp.private[:sse_buf] || "", chunk)

          resp =
            resp
            |> put_body_parts(parts, size)
            |> Req.Response.put_private(:sse_buf, rest)

          case id && Enum.find_value(events, &reply_for(&1, id)) do
            nil -> {:cont, {req, resp}}
            json -> {:halt, {req, Req.Response.put_private(resp, :reply, json)}}
          end

        true ->
          {:cont, {req, put_body_parts(resp, parts, size)}}
      end
    end
  end

  defp put_body_parts(resp, parts, size) do
    resp
    |> Req.Response.put_private(:body_parts, parts)
    |> Req.Response.put_private(:body_size, size)
  end

  # spec 73 T42: the collected body, joined once.
  defp body_of(resp), do: IO.iodata_to_binary(Enum.reverse(resp.private[:body_parts] || []))

  defp reply_for(%{data: data}, id) do
    case Jason.decode(data) do
      {:ok, %{"id" => ^id} = json} -> json
      _ -> nil
    end
  end

  defp sse?(resp) do
    resp |> Req.Response.get_header("content-type") |> Enum.any?(&(&1 =~ "text/event-stream"))
  end

  defp snippet(body) do
    body |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
  end

  # Only messages of OUR port are taken out of the mailbox; anything else waits.
  defp await_stdio(state, id, deadline) do
    port = state.port
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        case stdio_lines(state, data) do
          {:ok, messages, state} -> await_stdio_lines(state, id, deadline, messages)
          {:error, reason, state} -> {:error, reason, state}
        end

      {^port, {:exit_status, code}} ->
        {:error, "process exited with status #{code}", %{state | port: nil}}
    after
      remaining -> {:error, "timed out waiting for a response", state}
    end
  end

  defp await_stdio_lines(state, id, deadline, messages) do
    # spec 67 T28 (G37): the lines that are not the answer being waited for
    # are the server's diagnostics — the handshake path dropped them too,
    # which is exactly when a misconfigured server is loudest.
    #
    # spec 68 T11: decode each message once; capture the matching response
    # in the reduce accumulator to avoid a second scan.
    {state, found} =
      Enum.reduce(messages, {state, nil}, fn m, {state, found} ->
        case Jason.decode(m) do
          # spec 73 T78: a server request whose id collides with ours is not
          # the reply — `dispatch/2` answers it.
          {:ok, %{"id" => ^id} = json} when not is_map_key(json, "method") ->
            {state, json}

          # spec 73 T15: the answer to another pending request is delivered,
          # not dropped; notifications and server requests go where they
          # always did.
          {:ok, %{} = json} ->
            {dispatch(state, json), found}

          {:ok, _other} ->
            {state, found}

          _error ->
            {push_output(state, m), found}
        end
      end)

    case found do
      nil -> await_stdio(state, id, deadline)
      json -> {:ok, json, state}
    end
  end

  # spec 73 T14: the complete lines a port chunk finishes, bounded while
  # reading. A chunk without a newline is only prepended to the parts list
  # (no copy of what came before); the join and the split happen once per
  # newline, so a 10 MB single-line result costs one linear pass instead of
  # one copy and one scan of the whole accumulation per chunk.
  defp stdio_lines(state, data) do
    size = state.buffer_size + byte_size(data)

    cond do
      size > max_stdio_buffer() ->
        {:error, "stdio line over #{stdio_cap_text()}", %{state | buffer: [], buffer_size: 0}}

      :binary.match(data, "\n") == :nomatch ->
        {:ok, [], %{state | buffer: [data | state.buffer], buffer_size: size}}

      true ->
        {messages, rest} = split_lines(IO.iodata_to_binary(Enum.reverse([data | state.buffer])))
        parts = if rest == "", do: [], else: [rest]
        {:ok, messages, %{state | buffer: parts, buffer_size: byte_size(rest)}}
    end
  end

  # Overridable like `@backoff`, so a test does not have to write 16 MB.
  defp max_stdio_buffer,
    do: Application.get_env(:swarm_code_daemon, :mcp_max_stdio_buffer, @max_stdio_buffer)

  defp stdio_cap_text do
    case max_stdio_buffer() do
      cap when rem(cap, 1_000_000) == 0 -> "#{div(cap, 1_000_000)} MB"
      cap -> "#{cap} bytes"
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.reject(complete, &(String.trim(&1) == "")), rest}
  end

  defp notify(%{server: %Server{transport: "stdio"}} = state, method, params) do
    if state.port,
      do:
        Port.command(
          state.port,
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"
        )

    state
  end

  defp notify(%{server: %Server{transport: "http"} = server} = state, method, params) do
    Req.post(SwarmCode.Domain.LLM.HTTP.request(server.url),
      json: %{"jsonrpc" => "2.0", "method" => method, "params" => params},
      headers: base_headers(state),
      retry: false,
      receive_timeout: 15_000,
      decode_body: false,
      # spec 60 T12
      into: mcp_collector(nil)
    )

    state
  rescue
    _ -> state
  end

  ## ------------------------------------------------------------------ result

  # A server may echo its own request — headers included — in either branch.
  defp tool_result(state, %{"isError" => true} = result),
    do: {:error, safe(state, content_text(result))}

  # spec 67 T34 (G35): a Playwright or Figma screenshot came back as the string
  # `[image image/png]` and the pixels were dropped on the floor. The images ride
  # beside the text from here to `LLM.Anthropic.tool_result/1`.
  defp tool_result(state, result),
    do: {:ok, safe(state, content_text(result)), images(result)}

  @doc false
  def content_text(%{"content" => items} = result) when is_list(items) do
    text =
      items
      # An image whose bytes are carried as a block is not also announced as
      # `[image image/png]`; one without usable data still is.
      |> Enum.reject(&carried_image?/1)
      |> Enum.map(&item_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    # spec 67 T34 (G35): `content: []` with a `structuredContent` beside it —
    # the shape MCP 2025-06-18 recommends for a typed result — used to read as
    # the empty string, so the model was handed a blank tool result.
    case {text, result} do
      {"", %{"structuredContent" => data}} -> Jason.encode!(data)
      {text, _result} -> text
    end
  end

  def content_text(%{"structuredContent" => data}), do: Jason.encode!(data)
  def content_text(other), do: Jason.encode!(other)

  @doc false
  def images(%{"content" => items}) when is_list(items) do
    for %{"type" => "image", "data" => data} = item <- items,
        is_binary(data) and data != "" do
      mime = to_string(item["mimeType"] || "image/png")
      %{mime: mime, data: data, tokens: image_tokens(data, mime)}
    end
  end

  def images(_result), do: []

  defp carried_image?(%{"type" => "image", "data" => data}), do: is_binary(data) and data != ""
  defp carried_image?(_item), do: false

  defp image_tokens(data, mime) do
    case Base.decode64(data) do
      {:ok, binary} -> SwarmCode.Domain.Attachments.image_tokens(binary, mime)
      :error -> SwarmCode.Domain.Attachments.image_token_cap()
    end
  end

  # spec 60 T11
  defp item_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp item_text(%{"type" => "image", "mimeType" => mime}), do: "[image #{mime}]"
  defp item_text(%{"type" => "image"}), do: "[image]"

  defp item_text(%{"type" => "resource", "resource" => resource}) when is_map(resource) do
    resource["text"] || "[resource #{resource["uri"]}]"
  end

  defp item_text(%{"type" => "resource_link", "uri" => uri}), do: "[resource #{uri}]"
  defp item_text(other), do: Jason.encode!(other)

  ## ------------------------------------------------------------- reconnecting

  # Sakana task 11: this used to classify HTTP failures by matching the *tool's*
  # error text, so a tool answering "the upstream API timed out" reconnected a
  # perfectly healthy transport. Transport failures are now tagged at the source
  # (`{:transport_error, reason}`) and this text test is gone.

  defp fail(state, reason, opts \\ []) do
    reason = reason |> to_string() |> String.slice(0, 200)
    safe_reason = safe(state, reason)
    Logger.warning("swarm_code MCP #{state.server.name}: connection failed")

    # spec 67 T8 (B11): two failures used to arm two timers, and the second
    # `:connect` tore down whatever the first had rebuilt.
    state = state |> cancel_connect_timer() |> close()
    MCP.forget_tools(state.server.id)
    MCP.put_status(state.server.id, {:error, safe_reason})

    backoff = Application.get_env(:swarm_code_daemon, :mcp_backoff, @backoff)
    delay = Enum.at(backoff, state.attempt) || List.last(backoff)

    # Spec 43 §1.6 (C9): a command that does not exist will not exist in a
    # minute either. Three strikes, then the client waits for `reconnect/1`
    # (Settings) instead of warning, probing and re-rendering for ever.
    # spec 61 T1: `permanent: true` is the 401/403 case — the credential is
    # wrong, so the client waits for `reconnect/1` instead of retrying.
    timer =
      if Keyword.get(opts, :permanent, false) or
           (permanent?(reason) and state.attempt >= length(backoff) - 1) do
        Logger.warning("swarm_code MCP #{state.server.name}: giving up until reconnected")
        nil
      else
        Process.send_after(self(), :connect, delay)
      end

    %{
      state
      | status: {:error, safe_reason},
        attempt: min(state.attempt + 1, length(backoff) - 1),
        connect_timer: timer
    }
  end

  # spec 67 T8 (B11): drops the armed backoff. `cancel_timer/1` answers `false`
  # once the timer has fired, and then its `:connect` may still be queued
  # behind the message being handled — it is drained, so a reconnect burst
  # handshakes once instead of tearing its own work down.
  defp cancel_connect_timer(%{connect_timer: nil} = state), do: state

  defp cancel_connect_timer(%{connect_timer: ref} = state) when is_reference(ref) do
    if Process.cancel_timer(ref) == false do
      receive do
        :connect -> :ok
      after
        0 -> :ok
      end
    end

    %{state | connect_timer: nil}
  end

  defp permanent?(reason) do
    String.starts_with?(reason, "command not found") or String.contains?(reason, "enoent")
  end
end
