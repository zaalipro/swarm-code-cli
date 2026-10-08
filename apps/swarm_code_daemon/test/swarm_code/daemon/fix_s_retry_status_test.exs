defmodule SwarmCode.Daemon.FixSRetryStatusTest do
  @moduledoc """
  cli020 fix S2: the retry status line (`retrying 2/5 · <reason>`) names the
  HTTP status when the provider answered with one (`HTTP 500`, `HTTP 429`),
  and the reason word when it did not (an in-band error, a stream that ended
  early). The final failure text already said `HTTP 500` and is unchanged.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.LLM.{Request, Result}
  alias SwarmCode.Domain.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @moduletag :capture_log

  setup do
    old_providers = Application.get_env(:swarm_code_daemon, :llm_providers)
    old_sleep = Application.get_env(:swarm_code_daemon, :llm_retry_sleep)
    Application.put_env(:swarm_code_daemon, :llm_providers, %{"openai_compatible" => LLM.OpenAI})
    Application.put_env(:swarm_code_daemon, :llm_retry_sleep, fn _ms -> :ok end)

    on_exit(fn ->
      restore(:llm_providers, old_providers)
      restore(:llm_retry_sleep, old_sleep)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:swarm_code_daemon, key)
  defp restore(key, value), do: Application.put_env(:swarm_code_daemon, key, value)

  defp request(handler) do
    server = HTTP.start(handler)
    on_exit(fn -> HTTP.stop(server) end)

    %Request{
      provider: %Provider{
        kind: "openai_compatible",
        name: "fixture",
        base_url: server.url <> "/v1",
        api_key: "fixture-key",
        models: ["m"],
        default_model: "m"
      },
      model: "m",
      messages: [%{role: "user", content: "hello"}],
      effort: nil,
      deadline_ms: 10_000
    }
  end

  defp collect do
    owner = self()
    fn event -> send(owner, event) end
  end

  defp ok_frame,
    do:
      HTTP.sse(%{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => "Ready"}, "finish_reason" => "stop"}
        ]
      })

  test "a 500 is retried as HTTP 500, not as 'server'" do
    request =
      request(fn socket, _, n ->
        if n == 1,
          do: HTTP.respond(socket, 500, "boom"),
          else: HTTP.stream(socket, [ok_frame()])
      end)

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(request, collect())
    assert_received {:retry, 2, 5, "HTTP 500"}
  end

  test "a 429 is retried as HTTP 429" do
    request =
      request(fn socket, _, n ->
        if n == 1,
          do: HTTP.respond(socket, 429, "busy", [{"retry-after", "0"}]),
          else: HTTP.stream(socket, [ok_frame()])
      end)

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(request, collect())
    assert_received {:retry, 2, 5, "HTTP 429"}
  end

  test "a stream that ends early has no status: the reason word stays" do
    request =
      request(fn socket, _, n ->
        if n == 1,
          do:
            HTTP.stream(socket, [
              HTTP.sse(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "Re"}}]})
            ]),
          else: HTTP.stream(socket, [ok_frame()])
      end)

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(request, collect())
    assert_received {:retry, 2, 5, "stream ended early"}
  end

  test "giving up after the last attempt still says HTTP 500" do
    request = request(fn socket, _, _ -> HTTP.respond(socket, 500, "boom") end)

    assert {:error, _kind, message} = LLM.stream(request, collect())
    assert message =~ "HTTP 500"
    assert_received {:retry, 2, _of, "HTTP 500"}
    assert_received {:retry, 3, _of, "HTTP 500"}
    refute_received {:retry, _, _, "server"}
  end
end
