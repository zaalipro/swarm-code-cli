defmodule SwarmCode.LLM.LiveTransportTest do
  use ExUnit.Case, async: false
  alias SwarmCode.LLM
  alias SwarmCode.LLM.{Request, Result}
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  @moduletag :capture_log

  setup do
    if Process.whereis(LLM.ProviderCaps) == nil, do: start_supervised!(LLM.ProviderCaps)
    LLM.ProviderCaps.reset()
    :ok
  end

  defp fixture(handler, kind \\ "openai") do
    server = HTTP.start(handler)
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Provider.new(
        kind: kind,
        name: "fixture",
        base_url: server.url,
        api_key: "fixture-private-key"
      )

    %Request{
      provider: provider,
      model: "fixture-model",
      messages: [%{role: "user", content: "hello"}],
      effort: nil,
      deadline_ms: 10_000
    }
  end

  defp collect do
    owner = self()
    fn event -> send(owner, event) end
  end

  defp frame(delta, finish \\ nil),
    do: HTTP.sse(%{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]})

  test "real chunked HTTP assembles split text, reasoning, tool arguments and cached usage" do
    bytes =
      frame(%{"content" => "Hello ", "reasoning_content" => "Consider"}) <>
        frame(%{
          "content" => "world",
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => "call-1",
              "function" => %{"name" => "read_file", "arguments" => "{\"path\":"}
            }
          ]
        }) <>
        frame(
          %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"hello.ex\"}"}}]},
          "tool_calls"
        ) <>
        HTTP.sse(%{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 10,
            "completion_tokens" => 4,
            "prompt_tokens_details" => %{"cached_tokens" => 7}
          }
        }) <> "data: [DONE]\n\n"

    request =
      fixture(fn socket, _, _ ->
        HTTP.stream(socket, for(<<chunk::binary-size(1) <- bytes>>, do: chunk))
      end)

    assert {:ok, %Result{} = result} = LLM.stream(request, collect())
    assert result.text == "Hello world"
    assert result.reasoning == "Consider"

    assert result.tool_calls == [
             %{id: "call-1", name: "read_file", args: %{"path" => "hello.ex"}}
           ]

    assert result.usage == %{input: 10, output: 4, cache_read: 7}
    assert_received {:text_delta, "Hello "}
    assert_received {:http_request, 1, %{path: "/chat/completions", headers: headers, body: body}}
    assert headers["authorization"] == "Bearer fixture-private-key"
    assert Jason.decode!(body)["model"] == "fixture-model"
  end

  test "truncation retries real requests and resets partial output" do
    request =
      fixture(fn socket, _, n ->
        HTTP.stream(
          socket,
          if(n == 1,
            do: [frame(%{"content" => "Partial"})],
            else: [frame(%{"content" => "Complete"}, "stop")]
          )
        )
      end)

    assert {:ok, %Result{text: "Complete"}} = LLM.stream(request, collect())
    assert_received {:retry, 2, 5, "stream ended early"}
    assert_received {:text_reset}
    assert_received {:reasoning_reset}
    assert_received {:http_request, 2, _}
  end

  test "one-attempt streams cannot report success without a terminal marker" do
    request =
      fixture(fn socket, _, _ -> HTTP.stream(socket, [frame(%{"content" => "Partial"})]) end)

    assert {:error, message} = LLM.stream_once(request, collect())
    assert message =~ "stream ended early"
    refute_received {:retry, _, _, _}
  end

  test "invalid tool JSON remains a model-visible argument error" do
    request =
      fixture(fn socket, _, _ ->
        HTTP.stream(socket, [
          frame(
            %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "bad",
                  "function" => %{"name" => "write_file", "arguments" => "{broken"}
                }
              ]
            },
            "tool_calls"
          )
        ])
      end)

    assert {:ok, %Result{tool_calls: [call]}} = LLM.stream(request, nil)
    assert call.args == %{}
    assert is_binary(call.args_error)
    assert call.args_raw == "{broken"
  end

  test "401 is not retried and error bodies cannot echo credentials" do
    request = fixture(fn socket, _, _ -> HTTP.respond(socket, 401, "fixture-private-key") end)
    assert {:error, message} = LLM.stream(request, collect())
    assert message =~ "Unauthorized (401)"
    refute message =~ "fixture-private-key"
    refute_received {:retry, _, _, _}
  end

  test "rate limiting retries then succeeds" do
    request =
      fixture(fn socket, _, n ->
        if n == 1,
          do: HTTP.respond(socket, 429, "busy", [{"retry-after", "0"}]),
          else: HTTP.stream(socket, [frame(%{"content" => "Ready"}, "stop")])
      end)

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(request, collect())
    assert_received {:retry, 2, 5, "rate limit"}
  end

  test "cross-origin redirects never deliver credentials or prompts to the target" do
    target = HTTP.start(fn socket, _, _ -> HTTP.respond(socket, 200, "unexpected") end)
    on_exit(fn -> HTTP.stop(target) end)

    request =
      fixture(
        fn socket, _, _ ->
          HTTP.respond(socket, 307, "", [{"location", target.url <> "/stolen"}])
        end,
        "anthropic"
      )

    assert {:error, message} = LLM.stream(request, nil)
    assert message =~ "Redirected (307)"
    assert_received {:http_request, 1, %{path: "/v1/messages"}}
    refute_receive {:http_request, _, %{path: "/stolen"}}, 100
  end

  test "model listing uses the real credentialed endpoint" do
    request =
      fixture(fn socket, _, _ ->
        HTTP.respond(socket, 200, Jason.encode!(%{"data" => [%{"id" => "actual-model"}]}), [
          {"content-type", "application/json"}
        ])
      end)

    assert {:ok, ["actual-model"]} = LLM.list_models(request.provider)
    assert_received {:http_request, 1, %{method: "GET", path: "/models"}}
  end

  test "model listing bounds oversized JSON responses" do
    previous = Application.get_env(:swarm_code_daemon, :llm_max_response_bytes)
    Application.put_env(:swarm_code_daemon, :llm_max_response_bytes, 128)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:swarm_code_daemon, :llm_max_response_bytes),
        else: Application.put_env(:swarm_code_daemon, :llm_max_response_bytes, previous)
    end)

    request =
      fixture(fn socket, _, _ ->
        HTTP.respond(
          socket,
          200,
          Jason.encode!(%{"data" => [%{"id" => String.duplicate("m", 256)}]}),
          [{"content-type", "application/json"}]
        )
      end)

    assert {:error, message} = LLM.list_models(request.provider)
    assert message =~ "response exceeded"
  end

  test "model listing redacts an arbitrary echoed credential" do
    request =
      fixture(fn socket, _, _ -> HTTP.respond(socket, 403, "fixture-private-key denied") end)

    assert {:error, message} = LLM.list_models(request.provider)
    assert message =~ "Forbidden"
    refute message =~ "fixture-private-key"
  end

  test "cancellation during retry backoff prevents the next request" do
    request =
      fixture(fn socket, _, _ -> HTTP.respond(socket, 429, "busy", [{"retry-after", "60"}]) end)

    request = %{request | deadline_ms: 120_000}
    owner = self()
    task = Task.async(fn -> LLM.stream(request, fn event -> send(owner, event) end) end)
    assert_receive {:retry, 2, 5, "rate limit"}, 2_000
    Task.shutdown(task, :brutal_kill)
    refute_receive {:http_request, 2, _}, 100
  end

  test "an idle stream observes a short call deadline" do
    request =
      fixture(fn socket, _, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-type: text/event-stream\r\n\r\n"
        )

        :gen_tcp.recv(socket, 0, 3_000)
      end)

    started = System.monotonic_time(:millisecond)
    assert {:error, _} = LLM.stream(%{request | deadline_ms: 50}, nil)
    assert System.monotonic_time(:millisecond) - started < 800
  end

  test "Anthropic streaming preserves signed thinking continuation and prompt cache usage" do
    frames = [
      HTTP.event("message_start", %{
        "message" => %{
          "usage" => %{
            "input_tokens" => 3,
            "cache_creation_input_tokens" => 2,
            "cache_read_input_tokens" => 5
          }
        }
      }),
      HTTP.event("content_block_start", %{
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => ""}
      }),
      HTTP.event("content_block_delta", %{
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Reason"}
      }),
      HTTP.event("content_block_delta", %{
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "signed-proof"}
      }),
      HTTP.event("content_block_stop", %{"index" => 0}),
      HTTP.event("content_block_start", %{
        "index" => 1,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "tool-1",
          "name" => "read_file",
          "input" => %{}
        }
      }),
      HTTP.event("content_block_delta", %{
        "index" => 1,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":\"code.ex\"}"}
      }),
      HTTP.event("content_block_stop", %{"index" => 1}),
      HTTP.event("message_delta", %{
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 4}
      }),
      HTTP.event("message_stop", %{})
    ]

    request = fixture(fn socket, _, _ -> HTTP.stream(socket, frames) end, "anthropic")
    assert {:ok, %Result{} = result} = LLM.stream(request, collect())
    assert result.reasoning == "Reason"
    assert result.usage == %{input: 10, output: 4, cache_read: 5, cache_write: 2}

    assert [%{"thinking" => "Reason", "signature" => "signed-proof"}, %{"type" => "tool_use"}] =
             result.provider_blocks

    assert [%{args: %{"path" => "code.ex"}}] = result.tool_calls

    continuation = %{
      request
      | messages: [
          %{role: "user", content: "hello"},
          %{
            role: "assistant",
            content: result.text,
            tool_calls: result.tool_calls,
            provider_blocks: result.provider_blocks
          },
          %{
            role: "tool",
            tool_call_id: "tool-1",
            name: "read_file",
            content: "code",
            is_error: false
          }
        ]
    }

    assert {:ok, _} = LLM.stream(continuation, nil)
    assert_received {:http_request, 2, %{headers: headers, body: body}}
    assert headers["x-api-key"] == "fixture-private-key"
    wire = Jason.decode!(body)
    assistant = Enum.find(wire["messages"], &(&1["role"] == "assistant"))
    assert hd(assistant["content"])["signature"] == "signed-proof"
    assert List.last(wire["messages"])["content"] |> hd() |> Map.fetch!("tool_use_id") == "tool-1"
  end

  test "malformed event JSON before terminal marker fails instead of silently losing content" do
    request =
      fixture(fn socket, _, _ ->
        HTTP.stream(socket, ["data: {broken\n\n", "data: [DONE]\n\n"])
      end)

    assert {:error, message} = LLM.stream_once(request, nil)
    assert message =~ "invalid JSON"
  end

  test "the streaming response has a byte ceiling, including unterminated SSE" do
    previous = Application.get_env(:swarm_code_daemon, :llm_max_response_bytes)
    Application.put_env(:swarm_code_daemon, :llm_max_response_bytes, 128)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:swarm_code_daemon, :llm_max_response_bytes),
        else: Application.put_env(:swarm_code_daemon, :llm_max_response_bytes, previous)
    end)

    request =
      fixture(fn socket, _, _ ->
        HTTP.stream(socket, ["data: " <> String.duplicate("x", 256)])
      end)

    assert {:error, message} = LLM.stream_once(request, nil)
    assert message =~ "response exceeded"
  end

  test "transport relays callbacks on the caller and closes its socket if a callback raises" do
    owner = self()

    request =
      fixture(fn socket, _, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-type: text/event-stream\r\n\r\n"
        )

        chunk = frame(%{"content" => "hello"})
        :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
        send(owner, {:callback_socket, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    assert_raise RuntimeError, "callback stopped", fn ->
      LLM.stream(request, fn _ ->
        assert self() == owner
        raise "callback stopped"
      end)
    end

    assert_receive {:callback_socket, {:error, :closed}}, 1_000
  end

  test "a late chunk cannot restart the absolute response deadline" do
    owner = self()

    request =
      fixture(fn socket, _, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-type: text/event-stream\r\n\r\n"
        )

        Process.sleep(400)
        :gen_tcp.send(socket, "1\r\nx\r\n")
        send(owner, {:deadline_socket, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    started = System.monotonic_time(:millisecond)
    assert {:error, _} = LLM.stream(%{request | deadline_ms: 500}, nil)
    assert System.monotonic_time(:millisecond) - started < 750
    assert_receive {:deadline_socket, {:error, :closed}}, 500
  end

  test "semantic effort fallback shares the original deadline" do
    request =
      fixture(fn socket, _, n ->
        if n == 1 do
          Process.sleep(350)
          HTTP.respond(socket, 400, "unsupported reasoning_effort")
        else
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-type: text/event-stream\r\n\r\n"
          )

          :gen_tcp.recv(socket, 0, 2_000)
        end
      end)

    started = System.monotonic_time(:millisecond)
    assert {:error, _} = LLM.stream(%{request | deadline_ms: 500, effort: "medium"}, nil)
    assert System.monotonic_time(:millisecond) - started < 750
  end

  test "oversized error bodies cannot expose a credential prefix at the retention boundary" do
    request =
      fixture(fn socket, _, _ ->
        HTTP.respond(socket, 403, String.duplicate(" ", 65_530) <> "fixture-private-key denied")
      end)

    assert {:error, message} = LLM.stream(request, nil)
    assert message =~ "Forbidden (403)"
    refute message =~ ":  fixtur"
    assert message =~ "response body omitted"
  end

  test "error redaction precedes snippet truncation and includes short API keys" do
    for kind <- ["openai", "anthropic"], key <- ["fixture-private-key", "tiny"] do
      request =
        fixture(
          fn socket, _, _ ->
            HTTP.respond(socket, 403, String.duplicate("x", 290) <> key <> " denied")
          end,
          kind
        )

      request = %{request | provider: %{request.provider | api_key: key}}
      assert {:error, message} = LLM.stream(request, nil)
      refute message =~ String.slice(key, 0, 10)
      assert {:error, message} = LLM.list_models(request.provider)
      refute message =~ String.slice(key, 0, 10)
    end
  end

  test "credentialed same-origin redirects never log secret query values" do
    request =
      fixture(fn socket, _, n ->
        if n == 1 do
          HTTP.respond(socket, 307, "", [{"location", "/models?token=fixture-private-key"}])
        else
          HTTP.respond(socket, 200, ~s({"data": []}), [{"content-type", "application/json"}])
        end
      end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:ok, []} = LLM.list_models(request.provider)
      end)

    refute log =~ "fixture-private-key"
  end

  test "cancelling the stream owner closes the socket and prevents retries" do
    owner = self()

    request =
      fixture(fn socket, _, _ ->
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-type: text/event-stream\r\n\r\n"
        )

        send(owner, :stream_open)
        send(owner, {:socket_after_cancel, :gen_tcp.recv(socket, 0, 3_000)})
      end)

    task = Task.async(fn -> LLM.stream(request, collect()) end)
    assert_receive :stream_open, 2_000
    Task.shutdown(task, :brutal_kill)
    assert_receive {:socket_after_cancel, {:error, :closed}}, 3_000
    refute_receive {:http_request, 2, _}, 100
  end
end
