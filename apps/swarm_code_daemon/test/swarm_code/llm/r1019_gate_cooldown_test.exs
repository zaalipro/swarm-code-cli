defmodule SwarmCode.LLM.R1019GateCooldownTest do
  @moduledoc """
  Review 1019 RC-12 (C-ARCH-4): the desktop's `llm/pass76_cooldown_test.exs` runs on Bypass,
  a desktop test dependency this repository does not carry, so it cannot be mapped into the
  sync. This is its equivalent on the loopback fixture: one 429 cools its provider down for
  every caller, a rate limit is waited out inside the patience budget, another provider is not
  cooled, and every other failure keeps its 5 attempts.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import SwarmCode.Test.C020Backend, only: [eventually: 1]
  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.LLM.{Gate, Request, Result}
  alias SwarmCode.Domain.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup do
    LLM.ProviderCaps.reset()
    {:ok, log} = Agent.start_link(fn -> [] end)

    # Real waits, unless a test calls `stub_sleep/0`; the suite's own setting goes back after.
    suite = Application.fetch_env(:swarm_code_daemon, :llm_retry_sleep)
    providers = Application.fetch_env(:swarm_code_daemon, :llm_providers)
    Application.put_env(:swarm_code_daemon, :llm_retry_sleep, &Process.sleep/1)
    Application.put_env(:swarm_code_daemon, :llm_providers, %{"openai_compatible" => LLM.OpenAI})

    on_exit(fn ->
      restore(:llm_retry_sleep, suite)
      restore(:llm_providers, providers)
      Application.delete_env(:swarm_code_daemon, :llm_rate_limit_patience_ms)
      LLM.ProviderCaps.reset()
    end)

    %{log: log}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:swarm_code_daemon, key, value)
  defp restore(key, :error), do: Application.delete_env(:swarm_code_daemon, key)

  defp stub_sleep do
    me = self()
    Application.put_env(:swarm_code_daemon, :llm_retry_sleep, fn ms -> send(me, {:slept, ms}) end)
  end

  # A provider on its own server with its own id (a 429 cools the id down for every caller).
  # `answer.(socket, n)` answers the n-th request; every request is logged with its time.
  defp provider(c, answer) do
    server =
      HTTP.start(fn socket, _request, _index ->
        n =
          Agent.get_and_update(c.log, fn l ->
            n = length(l) + 1
            {n, [{n, System.monotonic_time(:millisecond)} | l]}
          end)

        answer.(socket, n)
      end)

    on_exit(fn -> HTTP.stop(server) end)

    %Request{
      provider: %Provider{
        id: "r1019-cooldown-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        name: "fixture",
        base_url: server.url,
        api_key: "fixture-key"
      },
      model: "m",
      messages: [%{role: "user", content: "hello"}],
      tools: []
    }
  end

  defp times(%{log: log}), do: log |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 1))
  defp collect, do: (fn owner -> fn event -> send(owner, event) end end).(self())
  defp key(request), do: request.provider.id

  defp limited(socket, retry_after),
    do: HTTP.respond(socket, 429, "busy", [{"retry-after", retry_after}])

  defp ready(socket) do
    frame = %{
      "choices" => [
        %{"index" => 0, "delta" => %{"content" => "Ready"}, "finish_reason" => "stop"}
      ]
    }

    HTTP.stream(socket, [HTTP.sse(frame), "data: [DONE]\n\n"])
  end

  test "cool_down never shortens a later cooldown" do
    key = {:cooldown_unit, System.unique_integer([:positive])}
    now = System.monotonic_time(:millisecond)

    assert Gate.cooldown_until(key) == nil
    Gate.cool_down(key, now + 5_000)
    Gate.cool_down(key, now + 1_000)
    assert Gate.cooldown_until(key) == now + 5_000
    Gate.cool_down(key, now + 9_000)
    assert Gate.cooldown_until(key) == now + 9_000
  end

  test "a second caller waits for the cooldown one 429 raised", c do
    request =
      provider(c, fn socket, n -> if n == 1, do: limited(socket, "1"), else: ready(socket) end)

    first = Task.async(fn -> LLM.stream(request, collect()) end)
    assert eventually(fn -> Gate.cooldown_until(key(request)) != nil end)
    second = Task.async(fn -> LLM.stream(request, collect()) end)

    assert {:ok, %Result{text: "Ready"}} = Task.await(first, 15_000)
    assert {:ok, %Result{text: "Ready"}} = Task.await(second, 15_000)

    # retry-after: 1 floors the cooldown at one second: neither the retrying caller nor the
    # waiting one may have sent before it ended.
    [t429, a, b] = times(c)
    assert a - t429 >= 900
    assert b - t429 >= 900
  end

  test "another provider is not cooled down", c do
    stub_sleep()
    cooled = provider(c, fn socket, _n -> ready(socket) end)
    other = provider(c, fn socket, _n -> ready(socket) end)
    Gate.cool_down(key(cooled), System.monotonic_time(:millisecond) + 60_000)

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(other, collect())
    refute_received {:slept, _}

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(cooled, collect())
    assert_received {:slept, ms} when ms > 55_000
  end

  test "more than 5 consecutive 429s are waited out inside the patience", c do
    stub_sleep()
    Application.put_env(:swarm_code_daemon, :llm_rate_limit_patience_ms, 600_000)

    request =
      provider(c, fn socket, n -> if n <= 7, do: limited(socket, "0"), else: ready(socket) end)

    assert {:ok, %Result{text: "Ready"}} = LLM.stream(request, collect())
    assert length(times(c)) == 8
    assert_received {:retry, 5, 5, "HTTP 429"}
    assert_received {:retry, 6, 5, past_five}
    assert past_five =~ ~r/^HTTP 429 · \d+m left$/
  end

  test "an exhausted patience fails with a clear rate-limit message", c do
    stub_sleep()
    Application.put_env(:swarm_code_daemon, :llm_rate_limit_patience_ms, 30_000)
    request = provider(c, fn socket, _n -> limited(socket, "0") end)

    assert {:error, :rate_limit, message} = LLM.stream(request, collect())
    assert message =~ "still rate limited after"
    assert message =~ "HTTP 429"
    assert length(times(c)) < 12
  end

  test "a 500 gives up after 5 attempts however large the patience, and cools nothing", c do
    stub_sleep()
    Application.put_env(:swarm_code_daemon, :llm_rate_limit_patience_ms, 600_000)
    request = provider(c, fn socket, _n -> HTTP.respond(socket, 500, "boom") end)

    assert {:error, :overloaded, message} = LLM.stream(request, collect())
    assert message =~ "after 5 attempts: HTTP 500"
    assert length(times(c)) == 5
    refute Gate.cooldown_until(key(request))
  end

  test "a 429 that names a spent quota is not waited out", c do
    stub_sleep()
    Application.put_env(:swarm_code_daemon, :llm_rate_limit_patience_ms, 600_000)

    request =
      provider(c, fn socket, _n ->
        HTTP.respond(socket, 429, ~s({"error":{"code":"insufficient_quota"}}))
      end)

    assert {:error, _kind, message} = LLM.stream(request, collect())
    assert message =~ "after 5 attempts"
    assert length(times(c)) == 5
    refute Gate.cooldown_until(key(request))
  end
end
