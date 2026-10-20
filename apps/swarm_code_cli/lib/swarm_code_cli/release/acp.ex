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

  A prompt is one `ncode -p --output-format stream-json` turn
  (`Release.Headless.run/2`) run in a worker process whose standard output is
  an in-memory IO server, so the records the one-shot writes come back here as
  lines, never on the real stdout. `TEXT <run>/<node> <text>` records of the
  first node (the run's lead) become `agent_message_chunk` updates and
  `REASONING` records `agent_thought_chunk` ones; a node record is either a
  delta or a snapshot of the text so far, so only the part not yet sent goes
  out. The `{"type": "summary"}` record ends the turn. The reply is sent when
  the worker has finished closing, because the next turn reopens the same
  storage. One prompt runs at a time, whatever the session, for the same
  reason.

  Approvals follow the project's approval mode like `-p` does: a prompt that
  needs one is denied and reported in the turn's text.
  """

  require Logger

  @protocol_version 1
  @max_line 1_048_576
  @max_prompt 262_144
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

  defp read_lines(input, owner, ref) do
    case read_line(input) do
      line when is_binary(line) ->
        send(owner, {:acp_in, ref, line})
        read_lines(input, owner, ref)

      _eof ->
        send(owner, {:acp_eof, ref})
    end
  end

  defp read_line(input) do
    case IO.read(input, :line) do
      line when is_binary(line) -> line
      _eof_or_error -> :eof
    end
  rescue
    _ -> :eof
  catch
    :exit, _ -> :eof
  end

  defp serve(%{ref: ref} = state) do
    receive do
      {:acp_in, ^ref, line} ->
        state |> handle_line(line) |> serve()

      {:acp_eof, ^ref} ->
        close(state)

      message ->
        state |> handle_worker(message) |> serve()
    end
  end

  ## Requests

  defp handle_line(state, line) when byte_size(line) > @max_line do
    reply_error(state, nil, @invalid_request, "that message is too long")
  end

  defp handle_line(state, line) do
    case String.trim(line) do
      "" -> state
      text -> text |> Jason.decode() |> handle_message(state)
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

    options = [project_root: info.cwd, conversation: info.conversation, output: io]

    {pid, monitor} =
      spawn_monitor(fn ->
        # The one-shot and everything it starts write to the group leader.
        Process.group_leader(self(), io)
        run_prompt.({:prompt, text, :stream_json}, options)
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
      lead: nil,
      sent: %{message: "", thought: ""}
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
    Enum.each(lines, &send(owner, {:acp_line, ref, &1}))
    rest
  end

  defp split_lines(text) do
    parts = String.split(text, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  ## What the worker says

  defp handle_worker(%{worker: %{ref: ref} = worker} = state, {:acp_line, ref, line}) do
    %{state | worker: worker_line(state, worker, line)}
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

  defp worker_line(state, worker, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "summary"} = summary} ->
        %{worker | summary: summary}

      {:ok, %{"stream" => "stdout", "text" => text}} when is_binary(text) ->
        stream_record(state, worker, text)

      _other ->
        worker
    end
  end

  defp stream_record(state, worker, "TEXT " <> record),
    do: stream_text(state, worker, :message, record)

  defp stream_record(state, worker, "REASONING " <> record),
    do: stream_text(state, worker, :thought, record)

  defp stream_record(_state, worker, _record), do: worker

  # `<run>/<node> [(preview; detail …) ]<text>`. Only the first node seen (the
  # run's lead) is streamed.
  defp stream_text(state, worker, kind, record) do
    case String.split(record, " ", parts: 2) do
      [key, rest] ->
        if worker.lead in [nil, key] do
          text = String.replace(rest, ~r/^\(preview; detail [^)]*\) /, "")
          {fresh, sent} = advance(worker.sent[kind], text)
          if fresh != "", do: update(state, worker.session, kind, fresh)
          %{worker | lead: key, sent: Map.put(worker.sent, kind, sent)}
        else
          worker
        end

      _ ->
        worker
    end
  end

  # A node record is a delta or a snapshot of the text so far: only what has
  # not gone out yet is new.
  defp advance(sent, text) do
    cond do
      text == "" or text == sent -> {"", sent}
      String.starts_with?(text, sent) -> {String.replace_prefix(text, sent, ""), text}
      true -> {text, sent <> text}
    end
  end

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

  # The summary carries the whole answer: send what the stream missed.
  defp catch_up(state, worker, %{"text" => text}) when is_binary(text) do
    sent = worker.sent.message

    if byte_size(text) > byte_size(sent) and String.starts_with?(text, sent),
      do: update(state, worker.session, :message, String.replace_prefix(text, sent, ""))
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
