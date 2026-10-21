defmodule SwarmCodeCLI.Release.R1019AcpTest do
  @moduledoc """
  pass 77 C-FEAT-13: `ncode acp` speaks Agent Client Protocol v1 over stdio.
  The loop is driven through two in-memory IO devices (a pipe the test writes
  to and a sink it reads from) and a fake `run_prompt` that reports what a
  one-shot reports: the typed events of its `sink` option and the summary
  object on its output.

  Review 1019: RC-1/RC-2 (the answer is the one-shot's own typed events, byte
  for byte) and RC-9 (standard input is read in bounded chunks and one message
  at a time) have their cases here; the real one-shot is in
  `r1019_acp_headless_test.exs`.
  """
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias SwarmCodeCLI.Release.Acp

  alias SwarmCodeCLI.Test.AcpPipe

  defp pipe, do: AcpPipe.pipe()
  defp push(pipe, object), do: AcpPipe.push(pipe, object)
  defp push_raw(pipe, binary), do: AcpPipe.push_raw(pipe, binary)
  defp eof(pipe), do: AcpPipe.eof(pipe)
  defp served(pipe), do: AcpPipe.served(pipe)
  defp sink(test, opts), do: AcpPipe.sink(test, opts)

  defp start_agent(run_prompt, opts \\ []) do
    input = pipe()
    output = sink(self(), Keyword.take(opts, [:block]))

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
  end

  # A fake one-shot: reports the given events to its `sink`, then its summary the way the
  # real one does (the last event, and the object on its output).
  defp events_prompt(events, summary_fields) do
    test = self()

    fn mode, options ->
      send(test, {:prompt, mode, options})
      for event <- events, do: options[:sink].(event)
      summary = summary(summary_fields)
      options[:sink].({:summary, summary})
      IO.write(options[:output], Jason.encode!(summary) <> "\n")
      0
    end
  end

  # A fake one-shot of a session that never started: only the object on its output.
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

  test "a prompt streams the one-shot's events unchanged, then ends the turn", %{cwd: cwd} do
    run_prompt =
      events_prompt(
        [
          {:text, "m-1", "Hello"},
          {:text, "m-1", " world"},
          {:reasoning, "m-1", "thinking"},
          {:text, "m-2", "\n\nsecond"}
        ],
        %{"text" => "Hello world\n\nsecond"}
      )

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 7, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("hi")})

    assert_receive {:prompt, {:prompt, "hi", :json}, options}, 2_000
    assert options[:project_root] == cwd
    assert options[:conversation] == "new"
    assert is_function(options[:sink], 1)

    assert_receive {:acp_out, first}, 2_000
    assert_receive {:acp_out, second}, 2_000
    assert_receive {:acp_out, thought}, 2_000
    assert_receive {:acp_out, third}, 2_000
    assert_receive {:acp_out, done}, 2_000

    # Exactly the bytes the one-shot appended: no record framing, no newline between chunks.
    assert chunk(first) == {"agent_message_chunk", "Hello", session}
    assert chunk(second) == {"agent_message_chunk", " world", session}
    assert chunk(thought) == {"agent_thought_chunk", "thinking", session}
    assert chunk(third) == {"agent_message_chunk", "\n\nsecond", session}
    assert %{"id" => 7, "result" => %{"stopReason" => "end_turn"}} = done
    # The summary's text is what went out: nothing is added after it.
    refute_receive {:acp_out, _}, 50

    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "repeated and equal chunks are all sent", %{cwd: cwd} do
    chunks = ["ab", "ab", "ab", "", "c"]
    events = for chunk <- chunks, chunk != "", do: {:text, "m", chunk}
    agent = start_agent(events_prompt(events, %{"text" => "abababc"}))
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    for expected <- ["ab", "ab", "ab", "c"] do
      assert_receive {:acp_out, update}, 2_000
      assert chunk(update) == {"agent_message_chunk", expected, session}
    end

    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "end_turn"}}}, 2_000
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "an attempt that restarts is separated, and the summary adds nothing", %{cwd: cwd} do
    run_prompt =
      events_prompt(
        [{:text, "m", "first att"}, {:text_restart, "m"}, {:text, "m", "second attempt"}],
        %{"text" => "second attempt"}
      )

    agent = start_agent(run_prompt)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    for expected <- ["first att", "\n\n", "second attempt"] do
      assert_receive {:acp_out, update}, 2_000
      assert chunk(update) == {"agent_message_chunk", expected, session}
    end

    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "end_turn"}}}, 2_000
    refute_receive {:acp_out, _}, 50
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  # A session that could not start writes only its summary object: the turn's answer.
  test "the summary object on the output ends a turn that sent no events", %{cwd: cwd} do
    failed =
      lines_prompt([
        Jason.encode!(summary(%{"exit_code" => 3, "error" => "No model provider is set up yet."}))
      ])

    agent = start_agent(failed)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    assert_receive {:acp_out,
                    %{
                      "id" => 1,
                      "error" => %{
                        "code" => -32_603,
                        "message" => "No model provider is set up yet."
                      }
                    }},
                   2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a later prompt continues the conversation the first one created", %{cwd: cwd} do
    agent = start_agent(events_prompt([], %{"conversation_id" => "conv-42"}))
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

  test "an answer the events missed is sent from the summary", %{cwd: cwd} do
    agent = start_agent(events_prompt([], %{"text" => "All of it"}))
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
          IO.write(
            options[:output],
            Jason.encode!(summary(%{"exit_code" => 143, "state" => "stopped"})) <> "\n"
          )

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
        :finish -> IO.write(options[:output], Jason.encode!(summary(%{})) <> "\n")
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
          IO.write(options[:output], Jason.encode!(summary(%{"exit_code" => 143})) <> "\n")
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

    push_raw(agent.input, "this is not json\n")
    assert_receive {:acp_out, %{"id" => nil, "error" => %{"code" => -32_700}}}, 2_000

    refute_receive {:prompt, _, _}, 50
    eof(agent.input)
    assert Task.await(agent.task) == 0
  end

  test "a turn that hit its turn limit and one that failed are told apart", %{cwd: cwd} do
    limited =
      events_prompt([], %{"exit_code" => 1, "reason" => "max_turns", "error" => "stopped"})

    agent = start_agent(limited)
    session = new_session(agent, cwd)
    request(agent, 1, "session/prompt", %{"sessionId" => session, "prompt" => text_prompt("x")})

    assert_receive {:acp_out, %{"id" => 1, "result" => %{"stopReason" => "max_turn_requests"}}},
                   2_000

    eof(agent.input)
    assert Task.await(agent.task) == 0

    failed =
      events_prompt([], %{
        "exit_code" => 1,
        "reason" => "run_failed",
        "error" => "The model refused."
      })

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

  # -- review 1019 RC-9: standard input is bounded ------------------------------

  describe "the input bound" do
    test "collect/3 holds a line only up to the limit and counts the rest" do
      # Within the limit: the chunks are joined, the newline ends the line, the rest is left.
      assert {:more, {:take, 3, ["abc"]}} = Acp.collect([], "abc", 10)
      assert {:done, {:ok, "abcdef"}, ~c"gh"} = Acp.collect({:take, 3, ["abc"]}, "def\ngh", 10)
      assert {:done, {:ok, "ab"}, :eof} = Acp.collect({:take, 2, ["ab"]}, :eof, 10)
      assert {:done, :eof, :eof} = Acp.collect({:take, 0, []}, :eof, 10)

      # Past the limit: only a count is kept, however many chunks follow.
      assert {:more, {:skip, 12}} = Acp.collect([], String.duplicate("a", 12), 10)
      assert {:more, {:skip, 24}} = Acp.collect({:skip, 12}, String.duplicate("a", 12), 10)
      assert {:done, :too_long, ~c"next"} = Acp.collect({:skip, 24}, "aa\nnext", 10)
      assert {:done, :too_long, :eof} = Acp.collect({:skip, 24}, :eof, 10)

      # A line that reaches its newline just over the limit is too long as well.
      assert {:done, :too_long, ~c"x"} = Acp.collect([], String.duplicate("a", 11) <> "\nx", 10)

      # Multibyte text counts in bytes.
      assert {:more, {:skip, 12}} = Acp.collect([], String.duplicate("é", 6), 10)
    end

    test "a newline-free message of any size is refused and the next one is served", %{cwd: cwd} do
      agent = start_agent(lines_prompt([]))
      session = new_session(agent, cwd)

      # Four chunks of 600 kB and no newline: 2.4 MB against a 1 MiB bound.
      for _ <- 1..4, do: push_raw(agent.input, String.duplicate("a", 600_000))
      push_raw(agent.input, "\n")

      assert_receive {:acp_out,
                      %{
                        "id" => nil,
                        "error" => %{"code" => -32_600, "message" => "that message is too long"}
                      }},
                     5_000

      request(agent, 2, "session/prompt", %{"sessionId" => "nope", "prompt" => text_prompt("x")})
      assert_receive {:acp_out, %{"id" => 2, "error" => %{"code" => -32_602}}}, 2_000

      assert session
      eof(agent.input)
      assert Task.await(agent.task) == 0
    end

    test "a message nested past the JSON depth limit is refused before it is dispatched" do
      agent = start_agent(lines_prompt([]))
      deep = String.duplicate("[", 200) <> String.duplicate("]", 200)

      push_raw(
        agent.input,
        ~s({"jsonrpc":"2.0","id":5,"method":"initialize","params":{"x":#{deep}}}\n)
      )

      assert_receive {:acp_out, %{"id" => nil, "error" => %{"code" => -32_700}}}, 2_000
      refute_receive {:acp_out, %{"id" => 5}}, 50

      request(agent, 6, "initialize", %{})
      assert_receive {:acp_out, %{"id" => 6, "result" => %{"protocolVersion" => 1}}}, 2_000
      eof(agent.input)
      assert Task.await(agent.task) == 0
    end

    test "the reader takes one message at a time: a loop that is busy leaves the rest unread" do
      agent = start_agent(lines_prompt([]), block: true)

      for id <- 1..5, do: request(agent, id, "initialize", %{})

      # The first reply is written to a client that does not read.
      assert_receive {:sink_blocked, blocked}, 2_000
      Process.sleep(100)

      # One message is being handled and the reader waits for credit: exactly one read
      # was asked of the input, whatever was pushed behind it.
      assert served(agent.input) == 1

      send(blocked, :release)

      for id <- 1..5 do
        assert_receive {:acp_out, %{"id" => ^id, "result" => %{"protocolVersion" => 1}}}, 5_000
      end

      eof(agent.input)
      assert Task.await(agent.task) == 0
    end
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
