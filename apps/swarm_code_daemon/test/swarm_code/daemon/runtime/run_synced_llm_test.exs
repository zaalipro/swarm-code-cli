defmodule SwarmCode.Daemon.Runtime.RunSyncedLLMTest do
  @moduledoc """
  cli020 L1/L3 (A5): the live runtime (`Daemon.Runtime.Run`, the unsaved
  session) streams through the synced `SwarmCode.Domain.LLM` stack, so the
  spec 74 LLM fixes reach it: BUGS-28, 29, 49, 50, 51, 52 and 77. Every
  provider here is a loopback server; nothing leaves 127.0.0.1.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Runtime.Run
  alias SwarmCode.Domain.LLM.ProviderCaps
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @moduletag :capture_log

  setup do
    ProviderCaps.reset()

    root =
      Path.join(
        System.tmp_dir!(),
        "swarm-live-llm-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.write!(Path.join(root, "answer.txt"), "wrong\n")

    # Transport retries sleep 1 s, 4 s, …; the retry decisions are what is
    # under test here, not the backoff.
    put_env(:llm_retry_sleep, fn _ms -> :ok end)

    on_exit(fn ->
      File.rm_rf!(root)
      ProviderCaps.reset()
    end)

    %{root: root}
  end

  test "BUGS-28: a request retried after a 500 resends exactly the body it sent", %{root: root} do
    server =
      serve(fn socket, _request, n ->
        if n == 1, do: HTTP.respond(socket, 500, "busy"), else: answer(socket, "Done.")
      end)

    run = start_run!(server, root)
    assert {:ok, %{status: :completed, text: "Done."}} = Run.await(run, 10_000)
    assert_received {:http_request, 1, first}
    assert_received {:http_request, 2, second}
    assert second.body == first.body
    # cli020 fix S2: the retry names the HTTP status the provider answered with.
    assert_received {:run_event, _, _, %{type: :retry, attempt: 2, count: 5, reason: "HTTP 500"}}
  end

  test "BUGS-28: a rejection a sibling already learned still gets this request's one retry", %{
    root: root
  } do
    server =
      serve(fn socket, request, n ->
        body = Jason.decode!(request.body)

        if n == 1 do
          assert body["reasoning_effort"] == "medium"
          # A concurrent sibling on the same provider got its 400 first and
          # remembered it while this request was still in flight.
          ProviderCaps.remember_no_effort(%{id: "fixture-provider"})

          HTTP.respond(
            socket,
            400,
            error_body("Unknown parameter: 'reasoning_effort'.")
          )
        else
          refute Map.has_key?(body, "reasoning_effort")
          answer(socket, "Done.")
        end
      end)

    run = start_run!(server, root)
    assert {:ok, %{status: :completed, text: "Done."}} = Run.await(run, 10_000)
    assert_received {:http_request, 1, first}
    assert_received {:http_request, 2, second}

    assert Map.delete(Jason.decode!(first.body), "reasoning_effort") ==
             Jason.decode!(second.body)
  end

  test "BUGS-29: a tool call cut off at the output limit is reported to the model, not run", %{
    root: root
  } do
    server =
      serve(fn socket, request, n ->
        case n do
          1 ->
            # The answer hit max_tokens inside the call's arguments.
            HTTP.stream(socket, [
              tool_frame("write-1", "write_file", ~s({"path":"out.txt","content":"abc), "length")
            ])

          2 ->
            last = List.last(Jason.decode!(request.body)["messages"])
            assert last["role"] == "tool"
            assert last["tool_call_id"] == "write-1"
            assert last["content"] =~ "cut off at the output limit"
            assert last["content"] =~ "split the content"
            answer(socket, "Split it.")
        end
      end)

    run = start_run!(server, root, approval: :auto)
    assert {:ok, %{status: :completed, text: "Split it."}} = Run.await(run, 10_000)
    refute File.exists?(Path.join(root, "out.txt"))

    assert_received {:run_event, _, _,
                     %{type: :tool_completed, id: "write-1", error?: true, text: text}}

    assert text =~ "cut off at the output limit"
  end

  test "BUGS-49: a stalled stream ends at the no-progress deadline and closes its socket", %{
    root: root
  } do
    owner = self()

    server =
      serve(fn socket, _request, _n ->
        open_stream(socket)
        # A keep-alive is not progress: the deadline still counts from the start.
        Process.sleep(100)
        chunk(socket, ": ping\n\n")
        send(owner, {:socket, :gen_tcp.recv(socket, 0, 5_000)})
      end)

    started = System.monotonic_time(:millisecond)
    run = start_run!(server, root, request_timeout_ms: 400)
    assert {:ok, %{status: :failed, error: {:provider_failed, reason}}} = Run.await(run, 10_000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert reason =~ "gave up after"
    assert elapsed >= 400
    # Exactly at the deadline: not one Finch `receive_timeout` (>= 1 s) later.
    assert elapsed < 900, "ended after #{elapsed} ms"
    assert_receive {:socket, {:error, :closed}}, 2_000
  end

  test "BUGS-49: a stream that keeps producing outlives its idle deadline", %{root: root} do
    words = for i <- 1..20, do: "w#{i} "

    server =
      serve(fn socket, _request, _n ->
        open_stream(socket)

        for word <- words do
          Process.sleep(100)

          chunk(
            socket,
            HTTP.sse(%{"choices" => [%{"index" => 0, "delta" => %{"content" => word}}]})
          )
        end

        chunk(
          socket,
          HTTP.sse(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]})
        )

        :gen_tcp.send(socket, "0\r\n\r\n")
      end)

    # 2 s of steady progress against a 500 ms no-progress bound (and past the
    # old `request_timeout_ms + 1 s` operation timer).
    run = start_run!(server, root, request_timeout_ms: 500)
    assert {:ok, %{status: :completed, text: text}} = Run.await(run, 10_000)
    assert text == Enum.join(words)
  end

  test "BUGS-50: a connection-pool checkout that times out is retried, not a crash", %{
    root: root
  } do
    pool = Module.concat(__MODULE__, Pool)
    start_supervised!({Finch, name: pool, pools: %{default: [size: 1, count: 1]}})
    put_env(:llm_finch, name: pool)
    put_env(:llm_pool_timeout, 50)
    put_env(:llm_retry_sleep, fn _ms -> Process.sleep(100) end)
    owner = self()

    server =
      serve(fn socket, _request, n ->
        if n == 1 do
          # The first run holds the pool's only connection until released.
          send(owner, {:holding, self()})

          receive do
            :release -> answer(socket, "First.")
          end
        else
          answer(socket, "Second.")
        end
      end)

    first = start_run!(server, root, id: uuid())
    assert_receive {:holding, handler}, 5_000
    second_id = uuid()
    second = start_run!(server, root, id: second_id)

    assert_receive {:run_event, ^second_id, _, %{type: :retry, reason: "network"}}, 5_000
    send(handler, :release)
    assert {:ok, %{status: :completed, text: "First."}} = Run.await(first, 10_000)
    assert {:ok, %{status: :completed, text: "Second."}} = Run.await(second, 10_000)
  end

  test "BUGS-51: one model's refused effort value falls back for that model only", %{root: root} do
    owner = self()

    server =
      serve(fn socket, request, _n ->
        body = Jason.decode!(request.body)
        send(owner, {:effort, body["model"], body["reasoning_effort"]})

        if body["model"] == "m-one" and body["reasoning_effort"] == "high" do
          HTTP.respond(
            socket,
            400,
            error_body(
              "Unsupported value: 'reasoning_effort' does not support 'high' with this model."
            )
          )
        else
          answer(socket, "Done.")
        end
      end)

    run = start_run!(server, root, model: "m-one", effort: "high")
    assert {:ok, %{status: :completed}} = Run.await(run, 10_000)
    assert_received {:effort, "m-one", "high"}
    assert_received {:effort, "m-one", "medium"}

    assert_received {:run_event, _, _,
                     %{
                       type: :retry,
                       reason: "effort high not supported by m-one; used default (medium)"
                     }}

    # The model is remembered: its next request goes out with the default.
    run = start_run!(server, root, model: "m-one", effort: "high", id: uuid())
    assert {:ok, %{status: :completed}} = Run.await(run, 10_000)
    assert_received {:effort, "m-one", "medium"}
    refute_received {:effort, "m-one", "high"}

    # Another model on the same provider keeps its level.
    run = start_run!(server, root, model: "m-two", effort: "high", id: uuid())
    assert {:ok, %{status: :completed}} = Run.await(run, 10_000)
    assert_received {:effort, "m-two", "high"}
  end

  test "BUGS-52: max_completion_tokens and the default temperature are learned per model", %{
    root: root
  } do
    owner = self()

    server =
      serve(fn socket, request, _n ->
        body = Jason.decode!(request.body)

        send(
          owner,
          {:body, Map.take(body, ["max_tokens", "max_completion_tokens", "temperature"])}
        )

        cond do
          Map.has_key?(body, "max_tokens") ->
            HTTP.respond(
              socket,
              400,
              error_body(
                "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
              )
            )

          Map.has_key?(body, "temperature") ->
            HTTP.respond(
              socket,
              400,
              error_body(
                "Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported."
              )
            )

          true ->
            answer(socket, "Done.")
        end
      end)

    run = start_run!(server, root, model: "o-fixture", effort: nil)
    assert {:ok, %{status: :completed, text: "Done."}} = Run.await(run, 10_000)
    assert_received {:body, %{"max_tokens" => n, "temperature" => 0.2}}
    assert_received {:body, %{"max_completion_tokens" => ^n, "temperature" => 0.2}}
    assert_received {:body, %{"max_completion_tokens" => ^n} = third}
    refute Map.has_key?(third, "temperature")

    run = start_run!(server, root, model: "o-fixture", effort: nil, id: uuid())
    assert {:ok, %{status: :completed, text: "Done."}} = Run.await(run, 10_000)
    assert_received {:body, %{"max_completion_tokens" => ^n} = next}
    assert map_size(next) == 1
  end

  test "BUGS-77: a thinking model's reasoning goes back inside its tool loop", %{root: root} do
    owner = self()

    server =
      serve(fn socket, request, _n ->
        body = Jason.decode!(request.body)
        assistant = Enum.find(body["messages"], &(&1["role"] == "assistant"))
        send(owner, {:assistant, body["model"], assistant})

        cond do
          is_nil(assistant) ->
            HTTP.stream(socket, [
              HTTP.sse(%{
                "choices" => [%{"index" => 0, "delta" => %{"reasoning_content" => "Consider"}}]
              }),
              tool_frame("read-1", "read_file", ~s({"path":"answer.txt"}), "tool_calls")
            ])

          body["model"] == "m-strict" and Map.has_key?(assistant, "reasoning_content") ->
            HTTP.respond(
              socket,
              400,
              error_body("The reasoning_content field is not supported in input messages.")
            )

          true ->
            answer(socket, "Read it.")
        end
      end)

    run = start_run!(server, root, model: "m-echo", approval: :auto)
    assert {:ok, %{status: :completed, text: "Read it."}} = Run.await(run, 10_000)
    assert_received {:assistant, "m-echo", nil}
    assert_received {:assistant, "m-echo", %{"reasoning_content" => "Consider"}}

    # A server that will not take it back is asked once without it, and the
    # model is remembered.
    run = start_run!(server, root, model: "m-strict", approval: :auto, id: uuid())
    assert {:ok, %{status: :completed, text: "Read it."}} = Run.await(run, 10_000)
    assert_received {:assistant, "m-strict", nil}
    assert_received {:assistant, "m-strict", %{"reasoning_content" => "Consider"}}
    assert_received {:assistant, "m-strict", without}
    refute Map.has_key?(without, "reasoning_content")
    refute ProviderCaps.continuation?(%{id: "fixture-provider"}, "m-strict")
    assert ProviderCaps.continuation?(%{id: "fixture-provider"}, "m-echo")
  end

  # ------------------------------------------------------------------ helpers

  defp serve(handler) do
    server = HTTP.start(handler)
    on_exit(fn -> HTTP.stop(server) end)
    server
  end

  defp start_run!(server, root, opts \\ []) do
    {:ok, provider} =
      Provider.new(
        id: "fixture-provider",
        name: "fixture",
        kind: "openai",
        base_url: server.url,
        api_key: "fixture-key"
      )

    {id, opts} = Keyword.pop(opts, :id, uuid())

    start_supervised!(
      {Run,
       Keyword.merge(
         [
           id: id,
           provider: provider,
           model: "fixture-model",
           project_root: root,
           prompt: "Fix answer.txt",
           subscriber: self()
         ],
         opts
       )},
      id: id
    )
  end

  defp error_body(message), do: Jason.encode!(%{"error" => %{"message" => message}})

  defp put_env(key, value) do
    previous = Application.fetch_env(:swarm_code_daemon, key)
    Application.put_env(:swarm_code_daemon, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:swarm_code_daemon, key, old)
        :error -> Application.delete_env(:swarm_code_daemon, key)
      end
    end)
  end

  defp open_stream(socket) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
    )
  end

  defp chunk(socket, data),
    do: :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])

  defp tool_frame(id, name, arguments, finish) do
    HTTP.sse(%{
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => id,
                "type" => "function",
                "function" => %{"name" => name, "arguments" => arguments}
              }
            ]
          },
          "finish_reason" => finish
        }
      ]
    })
  end

  defp answer(socket, text) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => "stop"}]
      })
    ])
  end

  defp uuid do
    <<a::32, b::16, c::12, d::14, e::48, _::6>> = :crypto.strong_rand_bytes(16)

    [hex(a, 8), hex(b, 4), "4" <> hex(c, 3), hex(Bitwise.bor(d, 0x8000), 4), hex(e, 12)]
    |> Enum.join("-")
  end

  defp hex(value, length),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(length, "0")
end
