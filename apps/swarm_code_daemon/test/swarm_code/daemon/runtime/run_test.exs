defmodule SwarmCode.Daemon.Runtime.RunTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Runtime.Run
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup do
    start_supervised!(SwarmCode.LLM.ProviderCaps)

    root =
      Path.join(
        System.tmp_dir!(),
        "swarm-live-run-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    File.write!(Path.join(root, "answer.txt"), "wrong\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "real HTTP model and coding tools inspect edit test and return a final answer", %{
    root: root
  } do
    server =
      HTTP.start(fn socket, request, turn ->
        body = Jason.decode!(request.body)

        case turn do
          1 ->
            assert List.last(body["messages"])["content"] == "Fix answer.txt and verify it"
            tool(socket, "read-1", "read_file", %{"path" => "answer.txt"})

          2 ->
            assert List.last(body["messages"])["content"] =~ "wrong"

            tool(socket, "edit-1", "edit_file", %{
              "path" => "answer.txt",
              "old_string" => "wrong",
              "new_string" => "correct"
            })

          3 ->
            assert List.last(body["messages"])["role"] == "tool"

            tool(socket, "test-1", "run_command", %{
              "command" => "test \"$(cat answer.txt)\" = correct && printf verified"
            })

          4 ->
            assert List.last(body["messages"])["content"] =~ "exit code 0"
            assert List.last(body["messages"])["content"] =~ "verified"
            answer(socket, "Fixed and verified.")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Provider.new(name: "fixture", kind: "openai", base_url: server.url, api_key: "fixture-key")

    run = start_run!(provider, root, approval: :auto)
    assert {:ok, result} = Run.await(run, 10_000)
    assert result.status == :completed
    assert result.text == "Fixed and verified."
    assert result.steps == 4
    assert File.read!(Path.join(root, "answer.txt")) == "correct\n"
    assert_receive {:run_event, _, _, %{type: :text_delta, text: "Fixed and verified."}}
    assert %{status: :completed, pending_approval: nil} = Run.snapshot(run)
  end

  test "write requests wait for explicit approval and denial changes no file", %{root: root} do
    server =
      HTTP.start(fn socket, request, turn ->
        case turn do
          1 ->
            tool(socket, "write-1", "write_file", %{
              "path" => "answer.txt",
              "content" => "changed"
            })

          2 ->
            assert List.last(Jason.decode!(request.body)["messages"])["content"] =~ "denied"
            answer(socket, "The change was denied.")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :ask)
    assert_receive {:run_event, _, _, %{type: :approval_required, id: approval}}, 5_000
    assert File.read!(Path.join(root, "answer.txt")) == "wrong\n"
    assert {:error, :stale_approval} = Run.resolve_approval(run, "wrong-id", :allow)
    assert :ok = Run.resolve_approval(run, approval, :deny)
    assert {:error, :stale_approval} = Run.resolve_approval(run, approval, :allow)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    assert File.read!(Path.join(root, "answer.txt")) == "wrong\n"
  end

  test "stop cancels a live provider request and settles the run", %{root: root} do
    test = self()

    server =
      HTTP.start(fn socket, _request, _turn ->
        send(test, :provider_started)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        send(test, :provider_closed)
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)
    assert_receive :provider_started, 5_000
    assert :ok = Run.stop(run)
    assert {:ok, %{status: :cancelled}} = Run.await(run, 5_000)
    assert_receive :provider_closed, 5_000
  end

  test "step budget prevents another model call after a tool turn", %{root: root} do
    server =
      HTTP.start(fn socket, _, 1 ->
        tool(socket, "read-1", "read_file", %{"path" => "answer.txt"})
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto, max_steps: 1)
    assert {:ok, %{status: :failed, error: :step_limit}} = Run.await(run, 5_000)
    refute_receive {:http_request, 2, _}
  end

  test "pause holds between operations and steer reaches the next real model request", %{
    root: root
  } do
    owner = self()

    server =
      HTTP.start(fn socket, request, turn ->
        case turn do
          1 ->
            send(owner, :first_model_waiting)

            receive do
              :finish_first -> :ok
            end

            tool(socket, "read-1", "read_file", %{"path" => "answer.txt"})

          2 ->
            assert List.last(Jason.decode!(request.body)["messages"])["content"] ==
                     "Also explain why"

            answer(socket, "Explanation included.")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)
    assert_receive :first_model_waiting, 5_000
    assert :ok = Run.pause(run)
    assert :ok = Run.steer(run, "Also explain why")
    send(server.pid, :finish_first)
    assert_receive {:run_event, _, _, %{type: :paused}}, 5_000
    refute_receive {:run_event, _, _, %{type: :tool_started}}
    assert :ok = Run.continue(run)
    assert {:ok, %{text: "Explanation included.", status: :completed}} = Run.await(run, 5_000)
  end

  test "stop cooperatively settles an executing command before reporting cancellation", %{
    root: root
  } do
    server =
      HTTP.start(fn socket, _, 1 ->
        tool(socket, "command-1", "run_command", %{
          "command" => "printf started; sleep 10; printf leaked > leaked.txt"
        })
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)
    assert_receive {:run_event, _, _, %{type: :tool_progress, text: "running"}}, 5_000
    assert :ok = Run.stop(run)
    assert {:ok, %{status: :cancelled}} = Run.await(run, 5_000)
    refute File.exists?(Path.join(root, "leaked.txt"))
  end

  test "approving while paused does not execute a write before continue", %{root: root} do
    server =
      HTTP.start(fn socket, _, turn ->
        case turn do
          1 ->
            tool(socket, "write-1", "write_file", %{
              "path" => "answer.txt",
              "content" => "changed"
            })

          2 ->
            answer(socket, "Done.")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :ask)
    assert_receive {:run_event, _, _, %{type: :approval_required, id: approval}}, 5_000
    assert :ok = Run.pause(run)
    assert :ok = Run.resolve_approval(run, approval, :allow)
    refute_receive {:run_event, _, _, %{type: :tool_started}}
    assert File.read!(Path.join(root, "answer.txt")) == "wrong\n"
    assert :ok = Run.continue(run)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    assert File.read!(Path.join(root, "answer.txt")) == "changed"
  end

  test "snapshots retain streamed partial text when a run is cancelled", %{root: root} do
    owner = self()

    server =
      HTTP.start(fn socket, _, _ ->
        chunk =
          HTTP.sse(%{
            "choices" => [%{"delta" => %{"content" => "Partial answer"}, "finish_reason" => nil}]
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
            Integer.to_string(byte_size(chunk), 16),
            "\r\n",
            chunk,
            "\r\n"
          ])

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        send(owner, :partial_socket_closed)
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)
    assert_receive {:run_event, _, _, %{type: :text_delta, text: "Partial answer"}}, 5_000
    assert Run.snapshot(run).text == "Partial answer"
    assert :ok = Run.stop(run)
    assert {:ok, %{status: :cancelled, text: "Partial answer"}} = Run.await(run, 5_000)
    assert_receive :partial_socket_closed, 5_000
  end

  test "continuing a paused approval restores waiting status without executing", %{root: root} do
    server =
      HTTP.start(fn socket, _, _ ->
        tool(socket, "write-1", "write_file", %{"path" => "answer.txt", "content" => "changed"})
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :ask)
    assert_receive {:run_event, _, _, %{type: :approval_required}}, 5_000
    assert :ok = Run.pause(run)
    assert Run.snapshot(run).status == :paused
    assert :ok = Run.continue(run)
    assert Run.snapshot(run).status == :waiting_approval
    assert_receive {:run_event, _, _, %{type: :continued, status: :waiting_approval}}
    refute_receive {:run_event, _, _, %{type: :tool_started}}
    assert :ok = Run.stop(run)
    assert {:ok, %{status: :cancelled}} = Run.await(run)
  end

  test "model output stopped by its token limit is incomplete even when text is nonempty", %{
    root: root
  } do
    server =
      HTTP.start(fn socket, _, _ ->
        HTTP.stream(socket, [
          HTTP.sse(%{
            "choices" => [
              %{"delta" => %{"content" => "Incomplete answer"}, "finish_reason" => "length"}
            ]
          })
        ])
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)

    assert {:ok, %{status: :failed, error: :response_limit, text: "Incomplete answer"}} =
             Run.await(run, 5_000)
  end

  test "invalid run settings and prompt configuration refuse before starting work", %{root: root} do
    {:ok, provider} =
      Provider.new(name: "fixture", base_url: "http://127.0.0.1:1", api_key: "fixture-key")

    base = [provider: provider, project_root: root, model: "fixture-model", prompt: "hello"]

    for extra <- [
          [settings: :bad],
          [settings: %{command_timeout_ms: 1.5}],
          [settings: %{command_timeout_ms: 0}],
          [system: %{}],
          [effort: %{}],
          [unexpected: true]
        ] do
      assert {:error, :invalid_run_configuration} = Run.start_link(base ++ extra)
    end
  end

  test "a slow subscriber receives bounded events and can recover the complete snapshot", %{
    root: root
  } do
    server =
      HTTP.start(fn socket, _, _ ->
        chunks =
          for _ <- 1..200,
              do:
                HTTP.sse(%{
                  "choices" => [%{"delta" => %{"content" => "x"}, "finish_reason" => nil}]
                })

        terminal = HTTP.sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})
        HTTP.stream(socket, chunks ++ [terminal])
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    events = drain_run_events([])
    assert length(events) <= 33
    assert Enum.any?(events, &match?({:run_snapshot_required, _, _}, &1))
    assert Run.snapshot(run).text == String.duplicate("x", 200)
  end

  defp drain_run_events(acc) do
    receive do
      {:run_event, _, _, _} = event -> drain_run_events([event | acc])
      {:run_snapshot_required, _, _} = event -> drain_run_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "an oversized streamed chunk is recoverable in full before cancellation", %{root: root} do
    text = String.duplicate("x", 70_000)

    server =
      HTTP.start(fn socket, _, _ ->
        chunk =
          HTTP.sse(%{"choices" => [%{"delta" => %{"content" => text}, "finish_reason" => nil}]})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
            Integer.to_string(byte_size(chunk), 16),
            "\r\n",
            chunk,
            "\r\n"
          ])

        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)

    notification =
      receive do
        {:run_snapshot_required, _, _} -> :snapshot_required
        {:run_event, _, _, %{type: :text_delta}} -> :delta
      after
        4_000 -> flunk("stream notification did not arrive")
      end

    assert byte_size(Run.snapshot(run).text) == byte_size(text)
    assert notification == :snapshot_required
    assert :ok = Run.stop(run)
    assert {:ok, %{status: :cancelled, text: ^text}} = Run.await(run, 5_000)
  end

  test "a live subscriber can resnapshot an overflow and acknowledge later streamed events", %{
    root: root
  } do
    owner = self()
    prefix = String.duplicate("x", 70_000)

    server =
      HTTP.start(fn socket, _, _ ->
        chunks =
          for _ <- 1..100,
              do:
                HTTP.sse(%{
                  "choices" => [
                    %{
                      "delta" => %{"content" => String.duplicate("x", 700)},
                      "finish_reason" => nil
                    }
                  ]
                })

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
          )

        Enum.each(chunks, fn chunk ->
          :ok =
            :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
        end)

        send(owner, :prefix_sent)

        receive do
          :finish_stream -> :ok
        end

        tail =
          HTTP.sse(%{
            "choices" => [%{"delta" => %{"content" => "tail"}, "finish_reason" => "stop"}]
          })

        :ok =
          :gen_tcp.send(socket, [
            Integer.to_string(byte_size(tail), 16),
            "\r\n",
            tail,
            "\r\n0\r\n\r\n"
          ])
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, provider} = Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-key")
    run = start_run!(provider, root, approval: :auto)
    assert_receive :prefix_sent, 5_000
    assert_receive {:run_snapshot_required, _, _}, 5_000
    snapshot = wait_for_sequence(run, 102, System.monotonic_time(:millisecond) + 5_000)
    assert byte_size(snapshot.text) == byte_size(prefix)
    assert :crypto.hash(:sha256, snapshot.text) == :crypto.hash(:sha256, prefix)
    drain_run_events([])
    send(server.pid, :finish_stream)
    assert_receive {:run_event, _, sequence, %{type: :text_delta, text: "tail"}}, 5_000
    assert :ok = Run.acknowledge(run, sequence)
    assert {:ok, %{status: :completed, text: full}} = Run.await(run, 5_000)
    assert full == prefix <> "tail"
  end

  defp wait_for_sequence(run, sequence, deadline) do
    snapshot = Run.snapshot(run)

    cond do
      snapshot.sequence >= sequence -> snapshot
      System.monotonic_time(:millisecond) >= deadline -> flunk("streamed prefix did not arrive")
      true -> wait_for_sequence(run, sequence, deadline)
    end
  end

  defp start_run!(provider, root, opts) do
    assert Code.ensure_loaded?(Run), "real agent runtime is missing"

    start_supervised!(
      {Run,
       [
         provider: provider,
         model: "fixture-model",
         project_root: root,
         prompt: "Fix answer.txt and verify it",
         subscriber: self()
       ] ++ opts}
    )
  end

  defp tool(socket, id, name, args) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ]
      })
    ])
  end

  defp answer(socket, text) do
    HTTP.stream(socket, [
      HTTP.sse(%{"choices" => [%{"delta" => %{"content" => text}, "finish_reason" => "stop"}]})
    ])
  end
end
