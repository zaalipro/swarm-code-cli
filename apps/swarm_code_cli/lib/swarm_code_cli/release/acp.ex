defmodule SwarmCodeCLI.Release.Acp do
  @moduledoc """
  pass 77 C-FEAT-13: `ncode acp`, an Agent Client Protocol (v1) agent over
  stdio, for editors such as Zed. Newline-delimited JSON-RPC 2.0: one object
  per line on stdin and stdout, requests carry an `id`, notifications do not.
  Logs go to cli.log, never to stdout.

  The smallest useful agent: `initialize`, `session/new`, `session/prompt`
  (text blocks only), `session/cancel`. A session is a working folder plus the
  conversation its first prompt creates; each later prompt continues that
  conversation. `mcpServers` and `loadSession` are not supported.

  A prompt is one `ncode -p --json` turn (`Release.Headless.run/2`) run in a
  worker process whose standard output is an in-memory IO server, so what the
  one-shot writes never reaches the real stdout. The turn's assistant text and
  reasoning reach this loop as typed events from the one-shot itself
  (`Plain.OneShot`'s `sink`, review 1019 RC-1/RC-2): the bytes it appends to the
  current turn's answer, never the transcript's older items or the user's own
  message, and never the presenter's record framing. They become
  `agent_message_chunk` and `agent_thought_chunk` updates unchanged. The
  turn's summary ends it (the object the one-shot also writes to its output: a
  session that never started writes only that). The reply is sent when the
  worker has finished closing, because the next turn reopens the same storage.
  One prompt runs at a time, whatever the session, for the same reason.

  Standard input is read in bounded chunks (`collect/3`): a line past
  `@max_line` bytes is skipped as it arrives, never held, and answered with an
  error. The reader hands the loop one message at a time and reads the next
  only when the loop has handled it, so a slow loop leaves the rest in the
  pipe. A message passes `SwarmCode.Protocol.JsonLimits` (size, depth, count)
  before it is dispatched.

  Approvals follow the project's approval mode like `-p` does: a prompt that
  needs one is denied and reported in the turn's text.
  """

  require Logger

  @protocol_version 1
  @max_line 1_048_576
  @max_prompt 262_144
  @capture_max 65_536
  # EOF on stdin: how long the running prompt gets to stop before it is killed.
  @close_ms 90_000

  # JSON-RPC 2.0 errors, and ACP's "a prompt is already running".
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603
  @busy -32_002

  @doc "The `ncode acp` entry: serves stdin and stdout, then halts the VM."
  @spec main([binary()]) :: no_return()
  def main(_args) do
    SwarmCodeCLI.Release.configure_io()
    # Nothing but the protocol may reach stdout: the logs go to cli.log.
    _ = SwarmCodeCLI.Release.PersistedSession.route_logs()
    code = loop(:stdio, [])
    SwarmCodeCLI.Release.flush_logs()
    System.halt(code)
  end

  @doc false
  # Serves the lines of `input` (an IO device) until its end. Options: `:output`
  # (an IO device, default stdout) and `:run_prompt`, a function of the
  # one-shot mode and options (default `Headless.run/2`). Returns the exit code.
  @spec loop(IO.device(), keyword()) :: 0
  def loop(input, opts \\ []) do
    ref = make_ref()
    owner = self()
    reader = spawn_link(fn -> read_lines(input, owner, ref) end)

    state = %{
      ref: ref,
      reader: reader,
      output: Keyword.get(opts, :output, :stdio),
      run_prompt: Keyword.get(opts, :run_prompt, &SwarmCodeCLI.Release.Headless.run/2),
      close_ms: Keyword.get(opts, :close_ms, @close_ms),
      sessions: %{},
      worker: nil
    }

    serve(state)
  end

  # One message at a time: the reader waits for the loop's credit after each one.
  defp read_lines(input, owner, ref) do
    device = if input == :stdio, do: Process.group_leader(), else: input
    read_loop(device, owner, ref)
  end

  defp read_loop(device, owner, ref) do
    case read_line(device) do
      {:ok, line} ->
        send(owner, {:acp_in, ref, line})
        await_credit(ref)
        read_loop(device, owner, ref)

      :too_long ->
        send(owner, {:acp_too_long, ref})
        await_credit(ref)
        read_loop(device, owner, ref)

      :eof ->
        send(owner, {:acp_eof, ref})
    end
  end

  defp await_credit(ref) do
    receive do
      {:acp_credit, ^ref} -> :ok
    end
  end

  defp read_line(device) do
    case :io.request(device, {:get_until, :unicode, ~c"", __MODULE__, :collect, [@max_line]}) do
      {:ok, line} when is_binary(line) -> {:ok, line}
      :too_long -> :too_long
      _eof_or_error -> :eof
    end
  rescue
    _ -> :eof
  catch
    :exit, _ -> :eof
  end

  @doc false
  # The `get_until` callback of the IO protocol (it runs inside the IO server, so it
  # must not raise): called with each chunk the device has, `[]` first and `:eof` at the
  # end. A line is collected up to `limit` bytes; past that its bytes are only counted
  # (`{:skip, n}`) until its newline, and the result is `:too_long`.
  def collect([], data, limit), do: collect({:take, 0, []}, data, limit)

  def collect({:take, 0, _acc}, :eof, _limit), do: {:done, :eof, :eof}

  def collect({:take, _n, acc}, :eof, _limit),
    do: {:done, {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}, :eof}

  def collect({:skip, _n}, :eof, _limit), do: {:done, :too_long, :eof}

  def collect({:take, n, acc}, data, limit) do
    text = IO.chardata_to_string(data)

    case :binary.split(text, "\n") do
      [line, rest] ->
        total = n + byte_size(line)

        if total > limit,
          do: {:done, :too_long, String.to_charlist(rest)},
          else:
            {:done, {:ok, IO.iodata_to_binary(Enum.reverse([line | acc]))},
             String.to_charlist(rest)}

      [_no_newline] ->
        total = n + byte_size(text)
        if total > limit, do: {:more, {:skip, total}}, else: {:more, {:take, total, [text | acc]}}
    end
  rescue
    _ -> {:done, :eof, :eof}
  end

  def collect({:skip, n}, data, _limit) do
    text = IO.chardata_to_string(data)

    case :binary.split(text, "\n") do
      [_line, rest] -> {:done, :too_long, String.to_charlist(rest)}
      [_no_newline] -> {:more, {:skip, n + byte_size(text)}}
    end
  rescue
    _ -> {:done, :eof, :eof}
  end

  defp serve(%{ref: ref} = state) do
    receive do
      {:acp_in, ^ref, line} ->
        state |> handle_line(line) |> credit() |> serve()

      {:acp_too_long, ^ref} ->
        state
        |> reply_error(nil, @invalid_request, "that message is too long")
        |> credit()
        |> serve()

      {:acp_eof, ^ref} ->
        close(state)

      message ->
        state |> handle_worker(message) |> serve()
    end
  end

  # The message is handled: the reader may deliver the next one.
  defp credit(%{reader: reader, ref: ref} = state) do
    send(reader, {:acp_credit, ref})
    state
  end

  ## Requests

  defp handle_line(state, line) do
    case String.trim(line) do
      "" ->
        state

      text ->
        text
        |> SwarmCode.Protocol.JsonLimits.decode(max_bytes: @max_line)
        |> handle_message(state)
    end
  end

  defp handle_message({:ok, %{"method" => method} = message}, state) when is_binary(method) do
    params = if is_map(message["params"]), do: message["params"], else: %{}

    case Map.fetch(message, "id") do
      {:ok, id} -> request(state, id, method, params)
      :error -> notification(state, method, params)
    end
  end

  # A response to a request this agent never sent, or something else: ignored.
  defp handle_message({:ok, _other}, state), do: state

  defp handle_message({:error, %{code: :json_too_large}}, state),
    do: reply_error(state, nil, @invalid_request, "that message is too long")

  defp handle_message({:error, _}, state),
    do: reply_error(state, nil, @parse_error, "that is not JSON")

  defp request(state, id, "initialize", _params) do
    reply(state, id, %{
      "protocolVersion" => @protocol_version,
      "agentCapabilities" => %{
        "loadSession" => false,
        "promptCapabilities" => %{"image" => false, "audio" => false, "embeddedContext" => false}
      },
      "authMethods" => [],
      "agentInfo" => %{"name" => "ncode", "version" => version()}
    })
  end

  defp request(state, id, "session/new", %{"cwd" => cwd})
       when is_binary(cwd) do
    if Path.type(cwd) == :absolute and File.dir?(cwd) do
      session = uuid()
      sessions = Map.put(state.sessions, session, %{cwd: cwd, conversation: "new"})
      reply(%{state | sessions: sessions}, id, %{"sessionId" => session})
    else
      reply_error(state, id, @invalid_params, "cwd must be an absolute path to a folder")
    end
  end

  defp request(state, id, "session/new", _params),
    do: reply_error(state, id, @invalid_params, "session/new needs a cwd")

  defp request(state, id, "session/prompt", %{"sessionId" => session, "prompt" => blocks}) do
    with {:ok, info} <- fetch_session(state, session),
         {:ok, text} <- prompt_text(blocks),
         :ok <- idle(state) do
      start_prompt(state, id, session, info, text)
    else
      {:error, code, words} -> reply_error(state, id, code, words)
    end
  end

  defp request(state, id, "session/prompt", _params),
    do: reply_error(state, id, @invalid_params, "session/prompt needs a sessionId and a prompt")

  defp request(state, id, method, _params),
    do: reply_error(state, id, @method_not_found, "ncode does not support #{inspect(method)}")

  defp notification(%{worker: %{session: session} = worker} = state, "session/cancel", %{
         "sessionId" => session
       }) do
    # `OneShot.run/1` forwards the signal to its run, stops it and finishes.
    send(worker.pid, {:shutdown_signal, :sigterm})
    %{state | worker: %{worker | cancelled?: true}}
  end

  defp notification(state, _method, _params), do: state

  defp fetch_session(state, session) when is_binary(session) do
    case Map.fetch(state.sessions, session) do
      {:ok, info} -> {:ok, info}
      :error -> {:error, @invalid_params, "unknown session"}
    end
  end

  defp fetch_session(_state, _session), do: {:error, @invalid_params, "unknown session"}

  defp prompt_text(blocks) when is_list(blocks) and blocks != [] do
    if Enum.all?(blocks, &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)) do
      text = Enum.map_join(blocks, "\n", & &1["text"])

      cond do
        String.trim(text) == "" -> {:error, @invalid_params, "the prompt is empty"}
        byte_size(text) > @max_prompt -> {:error, @invalid_params, "the prompt is too long"}
        not String.valid?(text) -> {:error, @invalid_params, "the prompt is not valid text"}
        true -> {:ok, text}
      end
    else
      {:error, @invalid_params, "ncode accepts text prompts only"}
    end
  end

  defp prompt_text(_blocks), do: {:error, @invalid_params, "the prompt needs text blocks"}

  defp idle(%{worker: nil}), do: :ok
  defp idle(_state), do: {:error, @busy, "a prompt is already running"}

  ## One prompt = one worker

  defp start_prompt(state, id, session, info, text) do
    ref = make_ref()
    owner = self()
    io = spawn(fn -> capture(owner, ref, "") end)
    run_prompt = state.run_prompt

    # The one-shot sends its typed events here itself, in order (one sender), so the
    # summary event comes after every text event.
    sink = fn event -> send(owner, {:acp_sink, ref, event}) end

    options = [
      project_root: info.cwd,
      conversation: info.conversation,
      output: io,
      sink: sink
    ]

    {pid, monitor} =
      spawn_monitor(fn ->
        # The one-shot and everything it starts write to the group leader.
        Process.group_leader(self(), io)
        run_prompt.({:prompt, text, :json}, options)
      end)

    worker = %{
      ref: ref,
      pid: pid,
      monitor: monitor,
      io: io,
      request: id,
      session: session,
      cancelled?: false,
      summary: nil,
      # What went out as the answer, newest first, and whether an attempt restarted.
      sent: [],
      restarted?: false
    }

    %{state | worker: worker}
  end

  # The IO server a worker writes to: it answers the IO protocol and sends
  # every complete line to the loop.
  defp capture(owner, ref, buffer) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, buffer} = io_request(request, owner, ref, buffer)
        send(from, {:io_reply, reply_as, reply})
        capture(owner, ref, buffer)

      :acp_stop ->
        if buffer != "", do: send(owner, {:acp_line, ref, buffer})
    end
  end

  defp io_request({:put_chars, chars}, owner, ref, buffer),
    do: {:ok, put(chars, owner, ref, buffer)}

  defp io_request({:put_chars, _encoding, chars}, owner, ref, buffer),
    do: {:ok, put(chars, owner, ref, buffer)}

  defp io_request({:put_chars, _encoding, module, function, args}, owner, ref, buffer) do
    put(apply(module, function, args), owner, ref, buffer)
    |> then(&{:ok, &1})
  rescue
    _ -> {{:error, :request}, buffer}
  end

  defp io_request({:requests, requests}, owner, ref, buffer) do
    Enum.reduce(requests, {:ok, buffer}, fn request, {_reply, buffer} ->
      io_request(request, owner, ref, buffer)
    end)
  end

  defp io_request({:setopts, _options}, _owner, _ref, buffer), do: {:ok, buffer}
  defp io_request(:getopts, _owner, _ref, buffer), do: {[], buffer}
  defp io_request(_other, _owner, _ref, buffer), do: {{:error, :enotsup}, buffer}

  defp put(chars, owner, ref, buffer) do
    text = buffer <> IO.chardata_to_string(chars)
    {lines, rest} = split_lines(text)
    Enum.each(lines, &send_line(owner, ref, &1))
    # A line is only worth keeping while it can still be a small object.
    if byte_size(rest) > @capture_max, do: "", else: rest
  end

  # The only thing taken from the output is the summary object of a session that never
  # started (a small one); a turn's own summary arrives as an event, so a longer line is
  # not kept.
  defp send_line(owner, ref, line) when byte_size(line) <= @capture_max,
    do: send(owner, {:acp_line, ref, line})

  defp send_line(_owner, _ref, _line), do: :ok

  defp split_lines(text) do
    parts = String.split(text, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  ## What the worker says

  defp handle_worker(%{worker: %{ref: ref} = worker} = state, {:acp_sink, ref, event}) do
    %{state | worker: sink_event(state, worker, event)}
  end

  defp handle_worker(%{worker: %{ref: ref} = worker} = state, {:acp_line, ref, line}) do
    %{state | worker: worker_line(worker, line)}
  end

  defp handle_worker(
         %{worker: %{monitor: monitor} = worker} = state,
         {:DOWN, monitor, :process, _pid, reason}
       ) do
    send(worker.io, :acp_stop)
    finish_prompt(state, worker, reason)
  end

  # Anything else (a late line of a finished prompt, a stray message).
  defp handle_worker(state, _message), do: state

  # The one-shot's typed events (`Plain.OneShot`): the bytes of the turn's answer and
  # reasoning as they were appended. Nothing is inferred from text.
  defp sink_event(state, worker, {:text, _message, chunk}) when is_binary(chunk) do
    update(state, worker.session, :message, chunk)
    %{worker | sent: [chunk | worker.sent]}
  end

  # An attempt cannot be taken back from the client: the new one follows the old, and the
  # summary's text no longer extends what went out.
  defp sink_event(state, worker, {:text_restart, _message}) do
    update(state, worker.session, :message, "\n\n")
    %{worker | restarted?: true}
  end

  defp sink_event(state, worker, {:reasoning, _message, chunk}) when is_binary(chunk) do
    update(state, worker.session, :thought, chunk)
    worker
  end

  defp sink_event(state, worker, {:reasoning_restart, _message}) do
    update(state, worker.session, :thought, "\n\n")
    worker
  end

  defp sink_event(_state, worker, {:summary, %{} = summary}), do: %{worker | summary: summary}
  defp sink_event(_state, worker, _event), do: worker

  # What a one-shot that never reached its own summary printed: the object of a session
  # that could not start (`Headless.json_failure/4`). The event's summary wins.
  defp worker_line(%{summary: nil} = worker, line) do
    case Jason.decode(line) do
      {:ok, %{"exit_code" => code} = summary} when is_integer(code) ->
        %{worker | summary: summary}

      _other ->
        worker
    end
  end

  defp worker_line(worker, _line), do: worker

  defp update(state, session, kind, text) do
    name = if kind == :message, do: "agent_message_chunk", else: "agent_thought_chunk"

    emit(state, %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session,
        "update" => %{
          "sessionUpdate" => name,
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  # The worker is gone: the turn's answer, then the reply to the prompt.
  defp finish_prompt(state, worker, reason) do
    summary = worker.summary

    if summary, do: catch_up(state, worker, summary)

    state = %{state | worker: nil}

    state =
      case summary && summary["conversation_id"] do
        id when is_binary(id) -> remember_conversation(state, worker.session, id)
        _ -> state
      end

    case stop_reason(worker, summary, reason) do
      {:ok, stop} -> reply(state, worker.request, %{"stopReason" => stop})
      {:error, words} -> reply_error(state, worker.request, @internal_error, words)
    end
  end

  # The summary carries the whole answer, which is exactly what the events appended: if it
  # is longer (a path that did not report), send the rest. After a restart the client has
  # both attempts and nothing is added.
  defp catch_up(_state, %{restarted?: true}, _summary), do: :ok

  defp catch_up(state, worker, %{"text" => text}) when is_binary(text) do
    sent = worker.sent |> Enum.reverse() |> IO.iodata_to_binary()

    if byte_size(text) > byte_size(sent) and String.starts_with?(text, sent),
      do:
        update(
          state,
          worker.session,
          :message,
          binary_part(text, byte_size(sent), byte_size(text) - byte_size(sent))
        )
  end

  defp catch_up(_state, _worker, _summary), do: :ok

  defp remember_conversation(state, session, id) do
    sessions =
      case state.sessions do
        %{^session => info} -> Map.put(state.sessions, session, %{info | conversation: id})
        sessions -> sessions
      end

    %{state | sessions: sessions}
  end

  defp stop_reason(%{cancelled?: true}, _summary, _reason), do: {:ok, "cancelled"}
  defp stop_reason(_worker, %{"exit_code" => 0}, _reason), do: {:ok, "end_turn"}

  defp stop_reason(_worker, %{"reason" => "max_turns"}, _reason), do: {:ok, "max_turn_requests"}

  defp stop_reason(_worker, %{"error" => error}, _reason) when is_binary(error) and error != "",
    do: {:error, error}

  defp stop_reason(_worker, %{"exit_code" => code}, _reason),
    do: {:error, "ncode stopped the turn (exit #{code})."}

  defp stop_reason(_worker, nil, reason) do
    Logger.error("acp: the prompt worker ended without a summary: #{inspect(reason)}")
    {:error, "ncode stopped before the turn finished."}
  end

  ## Closing

  # EOF on stdin: stop the running prompt, wait for it, leave.
  defp close(%{worker: nil}), do: 0

  defp close(%{worker: worker} = state) do
    send(worker.pid, {:shutdown_signal, :sigterm})
    state = %{state | worker: %{worker | cancelled?: true}}
    deadline = System.monotonic_time(:millisecond) + state.close_ms
    drain(state, deadline)
  end

  defp drain(%{worker: nil}, _deadline), do: 0

  defp drain(%{worker: worker} = state, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message -> state |> handle_worker(message) |> drain(deadline)
    after
      wait ->
        Logger.warning("acp: the prompt did not stop at the end of the input; killing it")
        Process.exit(worker.pid, :kill)
        Process.exit(worker.io, :kill)
        0
    end
  end

  ## Output

  defp reply(state, id, result) do
    emit(state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    state
  end

  defp reply_error(state, id, code, message) do
    emit(state, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })

    state
  end

  defp emit(state, object) do
    IO.write(state.output, [Jason.encode!(object), "\n"])
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp version do
    Application.load(:swarm_code_cli)

    case Application.spec(:swarm_code_cli, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    [<<a::32>>, <<b::16>>, <<4::4, c::12>>, <<2::2, d::14>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
