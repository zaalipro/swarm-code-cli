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
        try do
          case handshake(state) do
            {:ok, state} -> {:ok, state.tools}
            {:error, reason, _state} -> {:error, safe(state, reason)}
          end
        rescue
          e -> {:error, safe(state, "malformed response: " <> Exception.message(e))}
        after
          close(state)
        end

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
      buffer: "",
      next_id: 1,
      tools: [],
      session_id: nil,
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
      ping: nil
    }
  end

  @impl true
  def handle_info(:connect, state) do
    # spec 36 §A3: every caller waiting on the connection we are about to drop
    # is answered here, first. Otherwise their `{:request_timeout, id}` timers
    # outlive the reconnect and, ~120 s later, tear down the *new* connection.
    # spec 60 T11: queued HTTP callers are answered too, and the generation moves on.
    state =
      state
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
    {messages, buffer} = split_lines(state.buffer <> data)
    state = %{state | buffer: buffer}

    state =
      Enum.reduce(messages, state, fn message, state ->
        case Jason.decode(message) do
          {:ok, %{"id" => id} = json} when is_integer(id) ->
            reply_pending(state, id, rpc_reply(state, json))

          _other ->
            state
        end
      end)

    {:noreply, state}
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

          _ok_or_malformed ->
            {:noreply, drain_http_queue(state)}
        end
    end
  end

  # spec 60 T11: a settle from before the last reconnect.
  def handle_info({:http_settled, _gen, _session, _outcome}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

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
      GenServer.reply(from, {:error, "not connected"})
      state
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

  defp dispatch_http(state, from, method, params, timeout) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    client = self()
    gen = state.http_gen
    snapshot = %{state | pending: %{}, http_queue: :queue.new()}

    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
      # spec 60 T11: a raise in here used to leave the caller waiting for its whole
      # timeout and `http_establishing?` true for ever.
      {result, session, outcome} =
        try do
          case send_message(snapshot, request_message(id, method, params), id, timeout) do
            {:ok, %{"result" => result}, new_state} ->
              {tool_result(new_state, result), new_state.session_id, :ok}

            {:ok, %{"error" => err}, new_state} ->
              {{:error, rpc_error(new_state, err)}, new_state.session_id, :ok}

            {:ok, _other, new_state} ->
              {{:error, "unexpected response to #{method}"}, new_state.session_id, :ok}

            {:error, reason, new_state} ->
              {{:error, reason}, new_state.session_id, {:transport_error, reason}}
          end
        rescue
          e ->
            {{:error, safe(snapshot, "malformed response: " <> Exception.message(e))}, nil,
             {:malformed, Exception.message(e)}}
        end

      GenServer.reply(from, result)
      send(client, {:http_settled, gen, session, outcome})
    end)

    state
  end

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

  defp reply_pending(state, id, reply) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {{:ping, timer}, pending} ->
        Process.cancel_timer(timer)
        %{state | pending: pending, ping: nil}

      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn
      {_id, {:ping, timer}} ->
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

    with {:ok, _info, state} <- request(state, "initialize", params, @handshake_timeout),
         state <- notify(state, "notifications/initialized", %{}),
         {:ok, tools, state} <- list_tools(state, nil, []) do
      {:ok, %{state | tools: tools}}
    else
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  # spec 60 T12: a repeated cursor or a run past @max_tool_pages keeps what it has.
  defp list_tools(state, cursor, acc, seen \\ MapSet.new(), pages \\ 1) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case request(state, "tools/list", params, @handshake_timeout) do
      {:ok, %{"tools" => tools} = result, state} when is_list(tools) ->
        acc = acc ++ tools

        case result["nextCursor"] do
          next when is_binary(next) and next != "" ->
            cond do
              MapSet.member?(seen, next) or pages >= @max_tool_pages ->
                Logger.warning(
                  "swarm_code mcp #{state.server.name}: tools/list cursor #{inspect(next)} " <>
                    "repeated or over #{@max_tool_pages} pages — keeping #{length(acc)} tools"
                )

                {:ok, acc, state}

              true ->
                list_tools(state, next, acc, MapSet.put(seen, next), pages + 1)
            end

          _ ->
            {:ok, acc, state}
        end

      {:ok, _other, state} ->
        {:ok, acc, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  ## ---------------------------------------------------------------- requests

  defp request(state, method, params, timeout) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case send_message(state, message, id, timeout) do
      {:ok, %{"result" => result}, state} -> {:ok, result, state}
      {:ok, %{"error" => err}, state} -> {:error, rpc_error(state, err), state}
      {:ok, _other, state} -> {:error, "unexpected response to #{method}", state}
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
              {:cd, String.to_charlist(cwd(server))}
            ])

          {:ok, %{state | port: port, buffer: ""}}
        rescue
          e -> {:error, "could not start #{server.command}: " <> Exception.message(e)}
        end
    end
  end

  # spec 60 T11: a reconnect drops the dead session and the flags that described it.
  defp open(%{server: %Server{transport: "http"}} = state),
    do: {:ok, %{state | session_id: nil, http_stateless?: false, http_establishing?: false}}

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

    %{state | port: nil, buffer: ""}
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

  defp send_message(%{server: %Server{transport: "http"} = server} = state, message, id, timeout) do
    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
        Enum.map(server.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end) ++
        if(state.session_id, do: [{"mcp-session-id", state.session_id}], else: [])

    # spec 60 T10: no credentialed redirect across origins. spec 60 T12: the body is
    # collected bounded, and an SSE stream is halted on the correlated event.
    case Req.post(SwarmCode.Domain.LLM.HTTP.request(server.url),
           json: message,
           headers: headers,
           retry: false,
           receive_timeout: timeout,
           decode_body: false,
           into: mcp_collector(id)
         ) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        state = remember_session(state, resp)

        if resp.private[:skip] == :length do
          {:error, safe(state, "response over 16 MB"), state}
        else
          case decode_response(resp, id) do
            {:ok, json} -> {:ok, json, state}
            :none -> {:error, "no response for request #{id}", state}
          end
        end

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, safe(state, "HTTP #{status}: " <> snippet(resp.private[:body] || "")), state}

      {:error, exception} ->
        {:error, safe(state, "request failed: " <> Exception.message(exception)), state}
    end
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
    body = resp.private[:body] || ""

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
  defp mcp_collector(id) do
    fn {:data, chunk}, {req, resp} ->
      body = (resp.private[:body] || "") <> chunk

      cond do
        byte_size(body) > @max_http_body ->
          {:halt, {req, Req.Response.put_private(resp, :skip, :length)}}

        sse?(resp) ->
          {events, rest} = SSE.parse(resp.private[:sse_buf] || "", chunk)

          resp =
            resp
            |> Req.Response.put_private(:body, body)
            |> Req.Response.put_private(:sse_buf, rest)

          case id && Enum.find_value(events, &reply_for(&1, id)) do
            nil -> {:cont, {req, resp}}
            json -> {:halt, {req, Req.Response.put_private(resp, :reply, json)}}
          end

        true ->
          {:cont, {req, Req.Response.put_private(resp, :body, body)}}
      end
    end
  end

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
        {messages, buffer} = split_lines(state.buffer <> data)
        state = %{state | buffer: buffer}

        case Enum.find_value(messages, fn m ->
               case Jason.decode(m) do
                 {:ok, %{"id" => ^id} = json} -> json
                 _ -> nil
               end
             end) do
          nil -> await_stdio(state, id, deadline)
          json -> {:ok, json, state}
        end

      {^port, {:exit_status, code}} ->
        {:error, "process exited with status #{code}", %{state | port: nil}}
    after
      remaining -> {:error, "timed out waiting for a response", state}
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
    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
        Enum.map(server.headers || %{}, fn {k, v} -> {to_string(k), to_string(v)} end) ++
        if(state.session_id, do: [{"mcp-session-id", state.session_id}], else: [])

    Req.post(SwarmCode.Domain.LLM.HTTP.request(server.url),
      json: %{"jsonrpc" => "2.0", "method" => method, "params" => params},
      headers: headers,
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

  defp tool_result(state, result), do: {:ok, safe(state, content_text(result))}

  defp content_text(%{"content" => items}) when is_list(items) do
    items
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp content_text(%{"structuredContent" => data}), do: Jason.encode!(data)
  defp content_text(other), do: Jason.encode!(other)

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

  defp fail(state, reason) do
    reason = reason |> to_string() |> String.slice(0, 200)
    safe_reason = safe(state, reason)
    Logger.warning("swarm_code MCP #{state.server.name}: connection failed")

    state = close(state)
    MCP.forget_tools(state.server.id)
    MCP.put_status(state.server.id, {:error, safe_reason})

    backoff = Application.get_env(:swarm_code_daemon, :mcp_backoff, @backoff)
    delay = Enum.at(backoff, state.attempt) || List.last(backoff)

    # Spec 43 §1.6 (C9): a command that does not exist will not exist in a
    # minute either. Three strikes, then the client waits for `reconnect/1`
    # (Settings) instead of warning, probing and re-rendering for ever.
    if permanent?(reason) and state.attempt >= length(backoff) - 1 do
      Logger.warning("swarm_code MCP #{state.server.name}: giving up until reconnected")
    else
      Process.send_after(self(), :connect, delay)
    end

    %{
      state
      | status: {:error, safe_reason},
        attempt: min(state.attempt + 1, length(backoff) - 1)
    }
  end

  defp permanent?(reason) do
    String.starts_with?(reason, "command not found") or String.contains?(reason, "enoent")
  end
end
