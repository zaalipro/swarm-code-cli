defmodule SwarmCodeCLI.Release.R1019AcpTest do
  @moduledoc """
  pass 77 C-FEAT-13: `ncode acp` speaks Agent Client Protocol v1 over stdio.
  The loop is driven through two in-memory IO devices (a pipe the test writes
  to and a sink it reads from) and a fake `run_prompt` that writes the records
  a `--output-format stream-json` turn writes.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias SwarmCodeCLI.Release.Acp

  # -- two in-memory IO devices ------------------------------------------------

  # A pipe: `push/2` queues a line, `eof/1` ends it; `get_line` waits.
  defp pipe do
    spawn_link(fn -> pipe_loop([], nil, false) end)
  end

  defp push(pipe, object), do: send(pipe, {:push, Jason.encode!(object) <> "\n"})
  defp eof(pipe), do: send(pipe, :eof)

  defp pipe_loop(lines, waiting, eof?) do
    case {lines, waiting, eof?} do
      {[line | rest], {from, ref}, _} ->
        send(from, {:io_reply, ref, line})
        pipe_loop(rest, nil, eof?)

      {[], {from, ref}, true} ->
        send(from, {:io_reply, ref, :eof})
        pipe_loop([], nil, true)

      _ ->
        receive do
          {:push, line} ->
            pipe_loop(lines ++ [line], waiting, eof?)

          :eof ->
            pipe_loop(lines, waiting, true)

          {:io_request, from, ref, {:get_line, _encoding, _prompt}} ->
            pipe_loop(lines, {from, ref}, eof?)

          {:io_request, from, ref, _other} ->
            send(from, {:io_reply, ref, {:error, :enotsup}})
            pipe_loop(lines, waiting, eof?)
        end
    end
  end

  # A sink: every complete JSON line written arrives in `test` as {:acp_out, map}.
  defp sink(test), do: spawn_link(fn -> sink_loop(test, "") end)

  defp sink_loop(test, buffer) do
    receive do
      {:io_request, from, ref, {:put_chars, _encoding, chars}} ->
        text = buffer <> IO.chardata_to_string(chars)
        parts = String.split(text, "\n")

        for line <- Enum.drop(parts, -1),
            line != "",
            do: send(test, {:acp_out, Jason.decode!(line)})

        send(from, {:io_reply, ref, :ok})
        sink_loop(test, List.last(parts))

      {:io_request, from, ref, _other} ->
        send(from, {:io_reply, ref, {:error, :enotsup}})
        sink_loop(test, buffer)
    end
  end

  defp start_agent(run_prompt) do
    input = pipe()
    output = sink(self())

    task =
      Task.async(fn ->
        Acp.loop(input, output: output, run_prompt: run_prompt, close_ms: 5_000)
      end)

    %{input: input, task: task}
  end

  defp request(agent, id, method, params),
    do:
      push(agent.input, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp notify(agent, method, params),
    do: push(agent.input, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp new_session(agent, cwd) do
    request(agent, 100, "session/new", %{"cwd" => cwd, "mcpServers" => []})
    assert_receive {:acp_out, %{"id" => 100, "result" => %{"sessionId" => session}}}, 2_000
    session
  end

  defp text_prompt(text), do: [%{"type" => "text", "text" => text}]

  defp stream(text), do: Jason.encode!(%{"stream" => "stdout", "text" => text})

  defp summary(fields) do
    Map.merge(
      %{
        "type" => "summary",
        "state" => "done",
        "reason" => nil,
        "conversation_id" => "conv-1",
        "run_id" => "run-1",
        "text" => "",
        "error" => nil,
        "exit_code" => 0
      },
      fields
    )
    |> Jason.encode!()
  end

  # A fake one-shot: writes the given lines to the output it was given.
  defp lines_prompt(lines, test \\ self()) do
    fn mode, options ->
      send(test, {:prompt, mode, options})
      for line <- lines, do: IO.write(options[:output], line <> "\n")
      0
    end
  end

  setup do
    cwd = Path.join(System.tmp_dir!(), "acp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  test "initialize answers the protocol version and what ncode can do" do
    agent = start_agent(lines_prompt([]))
    request(agent, 1, "initialize", %{"protocolVersion" => 1, "clientCapabilities" => %{}})

    assert_receive {:acp_out,
                    %{
                      "jsonrpc" => "2.0",
                      "id" => 1,
                      "result" => %{
                        "protocolVersion" => 1,
                        "agentCapabilities" => %{
                          "loadSession" => false,
                          "promptCapabilities" => %{
                            "image" => false,
                            "audio" => false,
                            "embeddedContext" => false
                          }
                        },
                        "authMethods" => [],
                        "agentInfo" => %{"name" => "ncode", "version" => version}
                      }
                    }},
                   2_000

    assert is_binary(version)
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "session/new needs an absolute folder that exists", %{cwd: cwd} do
    agent = start_agent(lines_prompt([]))
    session = new_session(agent, cwd)
    assert session =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/

    for {id, cwd} <- [{2, "relative/dir"}, {3, Path.join(cwd, "missing")}] do
      request(agent, id, "session/new", %{"cwd" => cwd})
      assert_receive {:acp_out, %{"id" => ^id, "error" => %{"code" => -32_602}}}, 2_000
    end

    request(agent, 4, "session/new", %{})
    assert_receive {:acp_out, %{"id" => 4, "error" => %{"code" => -32_602}}}, 2_000
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a prompt streams the answer in order, then ends the turn", %{cwd: cwd} do
    run_prompt =
      lines_prompt([
        stream("TEXT run-1/node-1 Hello"),
        stream("TEXT run-1/node-1 Hello world"),
        stream("APPROVAL run-1/node-1 a"),
        stream("TEXT run-1/node-2 from a worker"),
        stream("REASONING run-1/node-1 thinking"),
        summary(%{"text" => "Hello world"})
      ])

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 7, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("hi")})

    assert_receive {:prompt, {:prompt, "hi", :stream_json}, options}, 2_000
    assert options[:project_root] == cwd
    assert options[:conversation] == "new"

    assert_receive {:acp_out, first}, 2_000
    assert_receive {:acp_out, second}, 2_000
    assert_receive {:acp_out, thought}, 2_000
    assert_receive {:acp_out, done}, 2_000

    assert chunk(first) == {"agent_message_chunk", "Hello", session}
    assert chunk(second) == {"agent_message_chunk", " world", session}
    assert chunk(thought) == {"agent_thought_chunk", "thinking", session}
    assert %{"id" => 7, "result" => %{"stopReason" => "end_turn"}} = done
    refute_receive {:acp_out, _}, 50

    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  # The real one-shot knows nothing of `output:`: it writes to its standard
  # output, which the worker's group leader catches.
  test "what the worker writes to its standard output is what the turn says", %{cwd: cwd} do
    run_prompt = fn _mode, _options ->
      IO.puts(stream("TEXT run-1/node-1 caf\u00e9 \u2713"))
      IO.write(summary(%{"text" => "caf\u00e9 \u2713"}) <> "\n")
      0
    end

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    assert_receive {:acp_out, update}, 2_000
    assert chunk(update) == {"agent_message_chunk", "caf\u00e9 \u2713", session}
    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "end_turn"}}}, 2_000
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a later prompt continues the conversation the first one created", %{cwd: cwd} do
    agent = start_agent(lines_prompt([summary(%{"conversation_id" => "conv-42"})]))
    session = new_session(agent, cwd)

    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("one")})
    assert_receive {:prompt, {:prompt, "one", _}, first}, 2_000
    assert first[:conversation] == "new"
    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "end_turn"}}}, 2_000

    request(agent, 2, "session/prompt", %{
      "sessionId" => session,
      "prompt" => [%{"type" => "text", "text" => "two"}, %{"type" => "text", "text" => "more"}]
    })

    assert_receive {:prompt, {:prompt, "two\nmore", _}, second}, 2_000
    assert second[:conversation] == "conv-42"
    assert_receive {:acp_out, %{"id" => 2, "result" => %{"stopReason" => "end_turn"}}}, 2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "an answer the stream missed is sent from the summary", %{cwd: cwd} do
    agent = start_agent(lines_prompt([summary(%{"text" => "All of it"})]))
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    assert_receive {:acp_out, update}, 2_000
    assert chunk(update) == {"agent_message_chunk", "All of it", session}
    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "end_turn"}}}, 2_000
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "session/cancel stops the running turn and the prompt answers cancelled", %{cwd: cwd} do
    test = self()

    run_prompt = fn _mode, options ->
      send(test, {:started, self()})

      receive do
        {:shutdown_signal, :sigterm} ->
          IO.write(options[:output], summary(%{"exit_code" => 143, "state" => "stopped"}) <> "\n")
          143
      end
    end

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 9, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("go")})
    assert_receive {:started, _worker}, 2_000

    notify(agent, "session/cancel", %{"sessionId" => session})
    assert_receive {:acp_out, %{"id" => 9, "result" => %{"stopReason" => "cancelled"}}}, 2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a second prompt while one runs is refused", %{cwd: cwd} do
    test = self()

    run_prompt = fn _mode, options ->
      send(test, {:started, self()})

      receive do
        :finish -> IO.write(options[:output], summary(%{}) <> "\n")
      end

      0
    end

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("a")})
    assert_receive {:started, worker}, 2_000

    request(agent, 2, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("b")})

    assert_receive {:acp_out, %{"id" => 2, "error" => %{"code" => -32_002, "message" => words}}},
                   2_000

    assert words =~ "already running"

    send(worker, :finish)
    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "end_turn"}}}, 2_000
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "the end of the input cancels the running turn and waits for it", %{cwd: cwd} do
    test = self()

    run_prompt = fn _mode, options ->
      send(test, :started)

      receive do
        {:shutdown_signal, :sigterm} ->
          IO.write(options[:output], summary(%{"exit_code" => 143}) <> "\n")
          send(test, :stopped)
          143
      end
    end

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("go")})
    assert_receive :started, 2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0
    assert_received :stopped
  end

  test "an image block, an unknown session and an unknown method are refused", %{cwd: cwd} do
    agent = start_agent(lines_prompt([]))
    session = new_session(agent, cwd)

    request(agent, 1, "session/prompt", %{
      "sessionId" => session,
      "prompt" => [%{"type" => "image", "data" => "AAAA", "mimeType" => "image/png"}]
    })

    assert_receive {:acp_out,
                    %{
                      "id" => 1,
                      "error" => %{
                        "code" => -32_602,
                        "message" => "ncode accepts text prompts only"
                      }
                    }},
                   2_000

    request(agent, 2, "session/prompt", %{"sessionId" => "nope", "prompt" => text_prompt("x")})
    assert_receive {:acp_out, %{"id" => 2, "error" => %{"code" => -32_602}}}, 2_000

    request(agent, 3, "session/load", %{"sessionId" => session})
    assert_receive {:acp_out, %{"id" => 3, "error" => %{"code" => -32_601}}}, 2_000

    send(agent.input, {:push, "this is not json\n"})
    assert_receive {:acp_out, %{"id" => nil, "error" => %{"code" => -32_700}}}, 2_000

    refute_receive {:prompt, _, _}, 50
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a turn that hit its turn limit and one that failed are told apart", %{cwd: cwd} do
    limited =
      lines_prompt([summary(%{"exit_code" => 1, "reason" => "max_turns", "error" => "stopped"})])

    agent = start_agent(limited)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "max_turn_requests"}}},
                   2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0

    failed =
      lines_prompt([
        summary(%{"exit_code" => 1, "reason" => "run_failed", "error" => "The model refused."})
      ])

    agent = start_agent(failed)
    session = new_session(agent, cwd)
    request(agent, 2, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    assert_receive {:acp_out,
                    %{
                      "id" => 2,
                      "error" => %{"code" => -32_603, "message" => "The model refused."}
                    }},
                   2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a worker that dies without a summary is an internal error, not a hang", %{cwd: cwd} do
    agent = start_agent(fn _mode, _options -> exit(:boom) end)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})
    assert_receive {:acp_out, %{"id" => 1, "error" => %{"code" => -32_603}}}, 2_000
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  defp chunk(%{
         "method" => "session/update",
         "params" => %{
           "sessionId" => session,
           "update" => %{
             "sessionUpdate" => kind,
             "content" => %{"type" => "text", "text" => text}
           }
         }
       }),
       do: {kind, text, session}
end
