# spec 70 B2
defmodule SwarmCode.Domain.LSP.Client do
  @moduledoc """
  A GenServer that speaks LSP JSON-RPC 2.0 over stdio to a language server.

  One client per {project, language}. Port in raw `:binary` mode; messages are
  framed with `Content-Length: N\\r\\n\\r\\n<json>` per the LSP spec.
  # spec 70 B8
  """
  # spec 74 BUGS-17: `:temporary` — a crashing client used to be restarted
  # at once (and its server with it), and a few crashes in a second took
  # ClientSup past its restart intensity, killing every language server of
  # every project. `LSP.request/5` starts a new client lazily instead.
  use GenServer, restart: :temporary

  require Logger

  @idle_timeout 300_000
  @request_timeout 30_000
  @init_timeout 30_000

  # spec 70 B2 — 1 MB cap on didOpen file content
  @max_file_size 1_048_576

  # spec 70 B8 — 16 MB cap on the read buffer
  @max_buffer_size 16_777_216

  # spec 74 BUGS-73: the open documents a server is told about, at most; the
  # least recently used one is closed past it.
  @max_open_docs 200

  ## ------------------------------------------------------------------ public

  @doc """
  Start a client linked to its supervisor. `env` is the server's whole
  environment (spec 74 BUGS-7); the three-element form uses the scrubbed
  `RunCommand.clean_env/1` defaults.
  """
  def start_link({project_root, language, command}),
    do: start_link({project_root, language, command, default_env()})

  def start_link({project_root, language, command, env}) do
    name = {:via, Registry, {SwarmCode.Domain.Registry, {:lsp, project_root, language}}}
    GenServer.start_link(__MODULE__, {project_root, language, command, env}, name: name)
  end

  defp default_env, do: SwarmCode.Domain.Tools.RunCommand.clean_env(%{})

  @doc "Send a request and wait for the response."
  def request(pid, method, params, timeout \\ @request_timeout) do
    # spec 73 T79: the text a `textDocument/*` request may have to `didOpen`
    # is read here, in the caller (the tool's op task), not inside the
    # GenServer that owns the port and every pending request — a disk read
    # there stalled every other agent waiting on the same server.
    text = did_open_text(method, params)
    # spec 74 BUGS-73: its digest too, so the client can tell an edited file
    # from the text the server already holds without keeping that text.
    text = if text, do: {text, :crypto.hash(:sha256, text)}
    # Extra 5 s so the internal timer fires before GenServer.call times out.
    GenServer.call(pid, {:request, method, params, timeout, text}, timeout + 5_000)
  catch
    # spec 74 EFFICIENCY-53: the client stopped (its idle shutdown, a
    # worktree's cleanup) between the lookup and the call — `LSP.request/5`
    # retries once on a fresh client.
    :exit, {reason, {GenServer, :call, _}}
    when reason in [:normal, :noproc] or
           (is_tuple(reason) and elem(reason, 0) == :shutdown) ->
      {:error, :gone}

    :exit, {:noproc, _} ->
      {:error, "server not running"}

    :exit, {:timeout, _} ->
      {:error, "timed out"}

    # spec 74 BUGS-17: every other exit is an answer too — a `{:shutdown, _}`
    # that reached `Operation.run`'s re-exit clause left the agent waiting
    # for an `op_done` that never came.
    :exit, reason ->
      {:error, "language server unavailable: " <> exit_text(reason)}
  end

  defp exit_text({reason, {GenServer, :call, _args}}), do: exit_text(reason)
  defp exit_text(reason), do: inspect(reason, limit: 5, printable_limit: 200)

  @doc "Stop the client gracefully."
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  def child_spec({project_root, language, command}),
    do: child_spec({project_root, language, command, default_env()})

  def child_spec({project_root, language, command, env}) do
    %{
      id: {__MODULE__, project_root, language},
      start: {__MODULE__, :start_link, [{project_root, language, command, env}]},
      restart: :temporary,
      shutdown: 10_000
    }
  end

  ## ------------------------------------------------------------------ server

  @impl true
  def init({project_root, language, command, env}) do
    Process.flag(:trap_exit, true)

    [executable | args] = command

    # spec 70 B2 (finisher): `:spawn_executable` takes a path, not a name — it
    # does not search PATH — so resolve first and refuse cleanly when the server
    # is not installed instead of dying with `:enoent` in the supervisor.
    # spec 74 BUGS-7: resolved on the child's own (scrubbed) PATH.
    case find_executable(executable, env) do
      nil -> {:stop, {:not_installed, executable}}
      path -> open_port(path, args, project_root, language, command, env)
    end
  end

  defp find_executable(executable, env) do
    case List.keyfind(env, ~c"PATH", 0) do
      {~c"PATH", path} when is_list(path) ->
        case :os.find_executable(String.to_charlist(executable), path) do
          false -> nil
          found -> List.to_string(found)
        end

      _no_path ->
        System.find_executable(executable)
    end
  end

  defp open_port(path, args, project_root, language, command, env) do
    # spec 70 B8 — raw :binary mode for Content-Length framing; no
    # :stderr_to_stdout so server log lines cannot corrupt the frame stream.
    # spec 74 BUGS-7: `{:env, …}` — the server inherited the whole BEAM
    # environment, provider keys included; every other child spawn scrubs it.
    port =
      Port.open({:spawn_executable, path}, [
        :binary,
        :exit_status,
        {:args, args},
        {:cd, project_root},
        {:env, env}
      ])

    state = %{
      project_root: project_root,
      language: language,
      command: command,
      port: port,
      # spec 73 T14: the bytes of an incomplete frame, newest part first, with
      # their size and — once the header is in — the byte count the frame
      # needs; `buffer <> data` copied the whole accumulation per chunk.
      buffer: [],
      buffer_size: 0,
      frame_need: nil,
      next_id: 1,
      pending: %{},
      initialized?: false,
      # spec 74 BUGS-73: `uri => %{version, digest, used}` — what the server
      # holds for each open document, and when it was last asked about.
      open_docs: %{},
      doc_clock: 0,
      idle_timer: nil,
      request_timeout: @request_timeout
    }

    # Send initialize request and wait synchronously.
    {id, state} = next_id(state)

    init_request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        # spec 73 T21
        "rootUri" => SwarmCode.Domain.LSP.Language.file_uri(project_root),
        "capabilities" => %{},
        "processId" => System.pid() |> String.trim() |> String.to_integer(),
        # cli021 K7 (CLI patch): the CLI introduces itself with its own version.
        "clientInfo" => %{"name" => "ncode", "version" => "0.2.1"}
      }
    }

    send_json(port, init_request)

    case await_response(port, id, @init_timeout) do
      {:ok, _result, buffer} ->
        # Send initialized notification.
        send_json(port, %{
          "jsonrpc" => "2.0",
          "method" => "initialized",
          "params" => %{}
        })

        state = %{state | initialized?: true}
        state = put_buffer(state, buffer)
        state = arm_idle_timer(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params, timeout, text}, from, state) do
    state = reset_idle_timer(state)

    # Ensure didOpen (or didChange) for text document requests.
    state = sync_document(state, method, params, text)

    {id, state} = next_id(state)

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }

    # spec 74 BUGS-17: a request that cannot be encoded is an answer, not a
    # crash of the client that owns every other caller's request.
    case send_json(state.port, request) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, timer})
        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  # spec 70 B8 — raw binary from the port; parse Content-Length framed messages.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    size = state.buffer_size + byte_size(data)

    cond do
      size > @max_buffer_size ->
        Logger.error("LSP buffer exceeded 16 MB, stopping client")
        {:stop, :buffer_overflow, state}

      # spec 73 T14: the frame's header is in and its body is still short —
      # keep the chunk without joining or re-parsing.
      is_integer(state.frame_need) and size < state.frame_need ->
        {:noreply, %{state | buffer: [data | state.buffer], buffer_size: size}}

      true ->
        buffer = IO.iodata_to_binary(Enum.reverse([data | state.buffer]))
        {messages, rest} = parse_messages(buffer, [])
        state = put_buffer(state, rest)
        state = Enum.reduce(messages, state, &dispatch_message/2)
        {:noreply, state}
    end
  end

  def handle_info(:idle_timeout, state) do
    # Send shutdown request with a short timeout, then exit notification.
    {id, state} = next_id(state)

    send_json(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "shutdown",
      "params" => nil
    })

    # spec 74 EFFICIENCY-53: no blocking wait for the shutdown answer — a
    # request that arrived meanwhile sat in this mailbox for up to 5 s and then
    # died with the client. The exit notification follows at once, and
    # `terminate/2` kills the server's process tree; a caller that raced the
    # stop gets `{:error, :gone}` and `LSP.request/5` starts a fresh client.
    send_json(state.port, %{
      "jsonrpc" => "2.0",
      "method" => "exit",
      "params" => nil
    })

    {:stop, :normal, state}
  end

  def handle_info({port, {:exit_status, _code}}, %{port: port} = state) do
    # Server exited — fail all pending requests.
    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, "server exited"})
    end)

    {:stop, :normal, %{state | pending: %{}, port: nil}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, "timed out"})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Ignore EXIT from linked port.
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = state) do
    # Cancel all pending timers.
    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, "client shutting down"})
    end)

    if port do
      port |> SwarmCode.Domain.OSProcess.port_pid() |> SwarmCode.Domain.OSProcess.kill_tree()

      try do
        Port.close(port)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## ----------------------------------------------------------------- private

  # spec 70 B8 — Content-Length framing parser

  defp parse_messages(buffer, acc) do
    case parse_one_message(buffer) do
      {:ok, msg, rest} -> parse_messages(rest, [msg | acc])
      {:skip, rest} -> parse_messages(rest, acc)
      :incomplete -> {Enum.reverse(acc), buffer}
    end
  end

  defp parse_one_message(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {pos, 4} ->
        headers = binary_part(buffer, 0, pos)
        body_start = pos + 4

        case parse_content_length(headers) do
          {:ok, length} ->
            available = byte_size(buffer) - body_start

            if available >= length do
              body = binary_part(buffer, body_start, length)
              rest = binary_part(buffer, body_start + length, available - length)

              case Jason.decode(body) do
                {:ok, msg} -> {:ok, msg, rest}
                {:error, _} -> {:skip, rest}
              end
            else
              :incomplete
            end

          :error ->
            # No valid Content-Length — skip past the header block.
            rest = binary_part(buffer, body_start, byte_size(buffer) - body_start)
            {:skip, rest}
        end

      :nomatch ->
        :incomplete
    end
  end

  # spec 73 T14: the incomplete tail of the stream, as parts, with the size
  # the frame it starts needs once its `Content-Length` header is complete.
  defp put_buffer(state, ""), do: %{state | buffer: [], buffer_size: 0, frame_need: nil}

  defp put_buffer(state, rest) do
    need =
      case :binary.match(rest, "\r\n\r\n") do
        {pos, 4} ->
          case parse_content_length(binary_part(rest, 0, pos)) do
            {:ok, length} -> pos + 4 + length
            :error -> nil
          end

        :nomatch ->
          nil
      end

    %{state | buffer: [rest], buffer_size: byte_size(rest), frame_need: need}
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn header ->
      case String.split(header, ":", parts: 2) do
        [key, value] ->
          if String.downcase(String.trim(key)) == "content-length" do
            case Integer.parse(String.trim(value)) do
              {n, _} -> {:ok, n}
              :error -> nil
            end
          end

        _ ->
          nil
      end
    end)
  end

  # spec 73 T78: a message with both `id` and `method` is a request from the
  # server (`client/registerCapability`, `window/workDoneProgress/create`,
  # `workspace/configuration`). Our ids and most servers' ids both start at
  # small integers, so it used to match the pending clause below and answer
  # the waiting caller `{:ok, nil}` while the real reply was then dropped as
  # unknown; a non-colliding one was never answered, and pyright waits on
  # `workspace/configuration` for ever. It is answered here, first.
  defp dispatch_message(%{"id" => id, "method" => method} = msg, state) when not is_nil(id) do
    answer_server(state, id, method, msg["params"])
    state
  end

  defp dispatch_message(%{"id" => id} = msg, state) when is_map_key(state.pending, id) do
    {{from, timer}, pending} = Map.pop(state.pending, id)
    Process.cancel_timer(timer)

    result =
      if Map.has_key?(msg, "error") do
        error = msg["error"]
        {:error, error["message"] || inspect(error)}
      else
        {:ok, msg["result"]}
      end

    GenServer.reply(from, result)
    %{state | pending: pending}
  end

  defp dispatch_message(%{"id" => _id}, state), do: state
  defp dispatch_message(%{"method" => _}, state), do: state
  defp dispatch_message(_other, state), do: state

  # spec 73 T78: the empty answers a client without UI or settings can give.
  # `workspace/configuration` wants one settings value per item — `nil` each.
  defp answer_server(state, id, method, _params)
       when method in [
              "client/registerCapability",
              "client/unregisterCapability",
              "window/workDoneProgress/create"
            ],
       do: send_json(state.port, %{"jsonrpc" => "2.0", "id" => id, "result" => nil})

  defp answer_server(state, id, "workspace/configuration", params) do
    items = (is_map(params) && params["items"]) || []
    result = Enum.map(List.wrap(items), fn _item -> nil end)
    send_json(state.port, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp answer_server(state, id, method, _params) do
    send_json(state.port, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "method not found: #{method}"}
    })
  end

  defp next_id(state) do
    {state.next_id, %{state | next_id: state.next_id + 1}}
  end

  # spec 70 B8 — Content-Length framing on write
  # spec 74 BUGS-17: `Jason.encode!/1` raised inside `handle_call` for a
  # non-UTF-8 document; an encoding error is returned instead.
  defp send_json(port, msg) do
    case Jason.encode(msg) do
      {:ok, body} ->
        header = "Content-Length: #{byte_size(body)}\r\n\r\n"
        Port.command(port, [header, body])
        :ok

      {:error, error} ->
        {:error, "cannot encode the LSP message: " <> Exception.message(error)}
    end
  end

  defp arm_idle_timer(state) do
    timer = Process.send_after(self(), :idle_timeout, @idle_timeout)
    %{state | idle_timer: timer}
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    arm_idle_timer(state)
  end

  # spec 73 T79: the file's text (1 MB cap) for a `textDocument/*` request,
  # read in the caller; nil when the request opens nothing.
  #
  # spec 74 BUGS-17: LSP text is JSON, so it must be valid UTF-8 — a Latin-1
  # file (or a 1 MB cut through a character) crashed the client. Invalid
  # bytes become U+FFFD here, in the caller.
  defp did_open_text(method, params) do
    with true <- String.starts_with?(method, "textDocument/"),
         uri when is_binary(uri) <- get_in(params, ["textDocument", "uri"]) do
      case File.read(uri_to_path(uri)) do
        {:ok, data} when byte_size(data) <= @max_file_size ->
          String.replace_invalid(data)

        {:ok, data} ->
          data |> binary_part(0, @max_file_size) |> String.replace_invalid()

        {:error, _} ->
          ""
      end
    else
      _ -> nil
    end
  end

  # The text arrives with the call (spec 73 T79); this only checks `open_docs`
  # and sends.
  #
  # spec 74 BUGS-73: a server treats an open document's text as the truth and
  # stops reading the file, and nothing ever sent `didChange` — every answer
  # after an edit came from the text of the first request. The text read for
  # this request is compared (by digest) with what the server holds: a new
  # document is opened at version 1, a changed one gets a whole-text
  # `didChange` (valid under Full and Incremental sync) at the next version,
  # and past @max_open_docs the least recently used document is closed.
  defp sync_document(state, method, params, text) do
    with true <- String.starts_with?(method, "textDocument/"),
         uri when is_binary(uri) <- get_in(params, ["textDocument", "uri"]) do
      {text, digest} = text || {"", :crypto.hash(:sha256, "")}
      clock = state.doc_clock + 1
      state = %{state | doc_clock: clock}

      case state.open_docs do
        %{^uri => %{digest: ^digest} = doc} ->
          put_doc(state, uri, %{doc | used: clock})

        %{^uri => doc} ->
          version = doc.version + 1

          send_json(state.port, %{
            "jsonrpc" => "2.0",
            "method" => "textDocument/didChange",
            "params" => %{
              "textDocument" => %{"uri" => uri, "version" => version},
              "contentChanges" => [%{"text" => text}]
            }
          })

          put_doc(state, uri, %{version: version, digest: digest, used: clock})

        _closed ->
          path = uri_to_path(uri)
          lang_id = SwarmCode.Domain.LSP.Language.detect(path) || "text"

          send_json(state.port, %{
            "jsonrpc" => "2.0",
            "method" => "textDocument/didOpen",
            "params" => %{
              "textDocument" => %{
                "uri" => uri,
                "languageId" => lang_id,
                "version" => 1,
                "text" => text
              }
            }
          })

          state
          |> put_doc(uri, %{version: 1, digest: digest, used: clock})
          |> close_least_used()
      end
    else
      _not_a_document -> state
    end
  end

  defp put_doc(state, uri, doc), do: %{state | open_docs: Map.put(state.open_docs, uri, doc)}

  defp close_least_used(%{open_docs: docs} = state) when map_size(docs) <= @max_open_docs,
    do: state

  defp close_least_used(state) do
    {uri, _doc} = Enum.min_by(state.open_docs, fn {_uri, doc} -> doc.used end)

    send_json(state.port, %{
      "jsonrpc" => "2.0",
      "method" => "textDocument/didClose",
      "params" => %{"textDocument" => %{"uri" => uri}}
    })

    %{state | open_docs: Map.delete(state.open_docs, uri)}
  end

  # spec 73 T21
  defp uri_to_path(uri), do: SwarmCode.Domain.LSP.Language.uri_to_path(uri)

  # spec 70 B8 — synchronous Content-Length reader during init
  defp await_response(port, expected_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(port, expected_id, deadline, "")
  end

  defp do_await(port, expected_id, deadline, buffer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "initialize timed out"}
    else
      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> data

          if byte_size(buffer) > @max_buffer_size do
            {:error, "buffer overflow during init"}
          else
            process_await_buffer(port, expected_id, deadline, buffer)
          end

        {^port, {:exit_status, code}} ->
          {:error, "server exited during init with status #{code}"}
      after
        remaining -> {:error, "initialize timed out"}
      end
    end
  end

  defp process_await_buffer(port, expected_id, deadline, buffer) do
    case parse_one_message(buffer) do
      {:ok, %{"id" => ^expected_id, "result" => result}, rest} ->
        {:ok, result, rest}

      {:ok, %{"id" => ^expected_id, "error" => error}, _rest} ->
        {:error, error["message"] || "initialize failed"}

      {:ok, _other_msg, rest} ->
        process_await_buffer(port, expected_id, deadline, rest)

      {:skip, rest} ->
        process_await_buffer(port, expected_id, deadline, rest)

      :incomplete ->
        do_await(port, expected_id, deadline, buffer)
    end
  end
end
