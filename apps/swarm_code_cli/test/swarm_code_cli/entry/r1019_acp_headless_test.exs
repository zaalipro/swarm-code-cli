defmodule SwarmCodeCLI.Release.R1019AcpHeadlessTest do
  @moduledoc """
  Review 1019 RC-1 / RC-2: `ncode acp` on the real one-shot (`Release.Headless`),
  a loopback provider and a conversation that already has a transcript.

  The answer a client sees is the current turn's assistant text, byte for byte:
  not the user's prompt, not an older item of the conversation, no record
  framing between chunks, and a second prompt on the same session streams its
  own answer, not the first one's.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @moduletag :capture_log

  alias SwarmCode.Domain.{Conversations, Engine, Projects}
  alias SwarmCode.Test.C020Backend, as: Fixture
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.Release.{Acp, Headless}
  alias SwarmCodeCLI.Test.AcpPipe

  setup do
    world = Fixture.setup_world("acp-headless")
    {:ok, project} = Projects.trust(world.project)
    {:ok, conversation} = Conversations.create(project.id)
    on_exit(fn -> Engine.stop_all(conversation.id) end)

    # A transcript before the session: a user message and an assistant answer.
    for {role, content} <- [{"user", "OLD-USER-PROMPT"}, {"assistant", "OLD-ASSISTANT-ANSWER"}] do
      {:ok, _} =
        Conversations.create_message(%{
          conversation_id: conversation.id,
          role: role,
          content: content
        })
    end

    %{world: %{world | project: project}, conversation: conversation}
  end

  # The provider answers the n-th turn with the chunks of `answers[n]`, each one a delta
  # sent on its own. With `hold:` the stream waits for `:release` (sent to the pid the test
  # gets as `{:held, pid}`) after the first chunk of that turn.
  defp provider(c, answers, opts \\ []) do
    {:ok, turn} = Agent.start_link(fn -> 0 end)
    test = self()

    server =
      HTTP.start(fn socket, _request, _index ->
        n = Agent.get_and_update(turn, &{&1 + 1, &1 + 1})
        chunks = Map.get(answers, n, ["(no answer scripted)"])
        last = length(chunks) - 1

        chunks
        |> Enum.with_index()
        |> Enum.each(fn {text, index} ->
          if index == 1 and opts[:hold] == n do
            send(test, {:held, self()})
            receive do: (:release -> :ok)
          end

          frame = %{
            "choices" => [
              %{
                "index" => 0,
                "delta" => %{"content" => text},
                "finish_reason" => if(index == last, do: "stop")
              }
            ]
          }

          chunk = HTTP.sse(frame)
          head = if index == 0, do: stream_head(), else: ""
          :gen_tcp.send(socket, [head, chunk_frame(chunk)])
        end)

        :gen_tcp.send(socket, "0\r\n\r\n")
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      SwarmCode.Domain.Providers.create(%{
        name: "acp-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, conversation} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    %{c | conversation: conversation}
  end

  defp stream_head do
    "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-type: text/event-stream\r\n" <>
      "transfer-encoding: chunked\r\n\r\n"
  end

  defp chunk_frame(chunk), do: [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]

  # The real one-shot, on the fixture's project and conversation.
  defp headless(c) do
    open = fn _selection, fun ->
      {:ok, fun.(%{project: c.world.project, conversation: c.conversation})}
    end

    fn mode, options -> Headless.run(mode, [with_saved_session: open] ++ options) end
  end

  defp start_agent(c) do
    input = AcpPipe.pipe()
    output = AcpPipe.sink(self())
    task = Task.async(fn -> Acp.loop(input, output: output, run_prompt: headless(c)) end)
    %{input: input, task: task}
  end

  defp request(agent, id, method, params) do
    AcpPipe.push(agent.input, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  # The updates of one prompt, up to its reply: {message text, thought text, reply}.
  defp turn(id) do
    collect(id, [], [])
  end

  defp collect(id, messages, thoughts) do
    assert_receive {:acp_out, out}, 60_000

    case out do
      %{"id" => ^id} = reply ->
        {messages |> Enum.reverse() |> Enum.join(), thoughts |> Enum.reverse() |> Enum.join(),
         reply}

      %{"method" => "session/update", "params" => %{"update" => update}} ->
        text = update["content"]["text"]

        case update["sessionUpdate"] do
          "agent_message_chunk" -> collect(id, [text | messages], thoughts)
          "agent_thought_chunk" -> collect(id, messages, [text | thoughts])
        end
    end
  end

  test "two prompts stream their own answers, byte for byte", c do
    c = provider(c, %{1 => ["Hello", " world"], 2 => ["Second", " ", "answer"]})
    agent = start_agent(c)

    request(agent, 1, "session/new", %{"cwd" => c.world.root, "mcpServers" => []})
    assert_receive {:acp_out, %{"id" => 1, "result" => %{"sessionId" => session}}}, 5_000

    request(agent, 2, "session/prompt", %{
      "sessionId" => session,
      "prompt" => [%{"type" => "text", "text" => "FIRST-USER-PROMPT"}]
    })

    {first, _thoughts, reply} = turn(2)
    assert %{"result" => %{"stopReason" => "end_turn"}} = reply
    assert first == "Hello world"

    request(agent, 3, "session/prompt", %{
      "sessionId" => session,
      "prompt" => [%{"type" => "text", "text" => "SECOND-USER-PROMPT"}]
    })

    {second, _thoughts, reply} = turn(3)
    assert %{"result" => %{"stopReason" => "end_turn"}} = reply
    assert second == "Second answer"

    # Neither the history nor the user's own words reached the client.
    for text <- [first, second] do
      refute text =~ "OLD-"
      refute text =~ "USER-PROMPT"
    end

    AcpPipe.eof(agent.input)
    assert Task.await(agent.task, 30_000) == 0

    # Both prompts ran in the one conversation.
    users =
      c.conversation.id
      |> Conversations.list_messages()
      |> Enum.filter(&(&1.role == "user"))
      |> Enum.map(& &1.content)

    assert users == ["OLD-USER-PROMPT", "FIRST-USER-PROMPT", "SECOND-USER-PROMPT"]
  end

  test "the answer streams while the model is still writing", c do
    c = provider(c, %{1 => ["First half", " and the rest"]}, hold: 1)
    agent = start_agent(c)

    request(agent, 1, "session/new", %{"cwd" => c.world.root, "mcpServers" => []})
    assert_receive {:acp_out, %{"id" => 1, "result" => %{"sessionId" => session}}}, 5_000

    request(agent, 2, "session/prompt", %{
      "sessionId" => session,
      "prompt" => [%{"type" => "text", "text" => "stream it"}]
    })

    # The first half reaches the client while the provider is still holding the second.
    assert_receive {:held, provider_stream}, 30_000

    assert_receive {:acp_out,
                    %{
                      "method" => "session/update",
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => %{"text" => "First half"}
                        }
                      }
                    }},
                   30_000

    send(provider_stream, :release)

    assert_receive {:acp_out,
                    %{
                      "method" => "session/update",
                      "params" => %{"update" => %{"content" => %{"text" => " and the rest"}}}
                    }},
                   30_000

    assert_receive {:acp_out, %{"id" => 2, "result" => %{"stopReason" => "end_turn"}}}, 30_000

    AcpPipe.eof(agent.input)
    assert Task.await(agent.task, 30_000) == 0
  end
end
