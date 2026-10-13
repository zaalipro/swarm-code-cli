defmodule SwarmCode.Daemon.Service.LiveBackendTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.LiveBackend
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  @conversation "22222222-2222-4222-8222-222222222222"
  @project "33333333-3333-4333-8333-333333333333"
  @epoch "44444444-4444-4444-8444-444444444444"

  setup do
    root = Path.join(System.tmp_dir!(), "live-backend-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    on_exit(fn -> File.rm_rf!(root) end)
    owner = self()

    server =
      HTTP.start(fn socket, http_request, _turn ->
        send(owner, {:provider_waiting, self()})

        receive do
          :release -> :ok
        after
          5_000 -> :ok
        end

        burst =
          if String.contains?(http_request.body, "burst"),
            do:
              Enum.map(1..500, fn _ ->
                HTTP.sse(%{
                  "choices" => [
                    %{"index" => 0, "delta" => %{"content" => "a"}, "finish_reason" => nil}
                  ]
                })
              end),
            else: []

        HTTP.stream(
          socket,
          burst ++
            [
              HTTP.sse(%{
                "choices" => [
                  %{"index" => 0, "delta" => %{"content" => "live"}, "finish_reason" => "stop"}
                ]
              })
            ]
        )
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Provider.new(
        name: "live",
        base_url: server.url,
        api_key: "secret",
        default_model: "fixture"
      )

    opts = [
      mode: :transient,
      provider: provider,
      project_root: root,
      project_id: @project,
      conversation_id: @conversation,
      source_epoch: @epoch
    ]

    {:ok, backend} = start_supervised({LiveBackend, opts})

    %{
      backend: backend,
      opts: opts,
      scope: %Scope{kind: :conversation, id: @conversation, generation: 0}
    }
  end

  test "buffers real run events until ready and delivers terminal state using actual watch reference",
       %{backend: backend, scope: scope} do
    assert {:watch, 0, 0, "workspace_snapshot", snapshot} = watch(backend, scope, "watch-1")
    assert snapshot["conversation_id"] == @conversation
    assert snapshot["transcript"]["items"] == []

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [run_id]}}} =
             request(backend, "req-1", scope, send_request())

    assert_receive {:provider_waiting, provider}, 5_000
    send(provider, :release)
    wait_done(backend, scope, run_id)
    refute_receive {:service_delta, _, _, _}, 20
    send(backend, {:service_ready, self(), "watch-1"})
    deltas = drain_to_done(backend, "watch-1", run_id)
    assert Enum.any?(deltas, &(&1["kind"] == "node_upsert" and &1["body"]["text"] == "live"))
    assert Enum.all?(deltas, &(&1["conversation_id"] == @conversation))
    assert {:ok, %{"value" => final}} = query(backend, scope, "workspace")
    assert Enum.any?(final["runs"], &(&1["id"] == run_id and &1["state"] == "done"))

    assert Enum.any?(
             final["transcript"]["items"],
             &(&1["role"] == "user" and &1["text"] == "hello")
           )
  end

  # pass70 F: the palette asks every backend for the conversation list; the
  # unsaved session answers the read with a typed error (a command outcome
  # here made the client close the connection and end the session).
  test "the conversation list is a read the unsaved session refuses as one", %{
    backend: backend
  } do
    global = %Scope{kind: :global, id: nil, generation: 0}

    list = %SwarmCode.Protocol.ServiceRequest{
      operation: :conversation_list,
      timeout_ms: 1000,
      params: %{"cursor" => nil, "page_size" => 50, "byte_limit" => 65_536}
    }

    assert {:error, %{"op" => "error", "code" => "not_allowed"}} =
             request(backend, "list-1", global, list)

    assert Process.alive?(backend)
  end

  test "deduplicates command identity and rejects a conflicting command", %{
    backend: backend,
    scope: scope
  } do
    first = request(backend, "same", scope, send_request())
    assert first == request(backend, "same", scope, send_request())

    assert {:ok,
            %{"value" => %{"status" => "rejected", "error" => %{"code" => "request_conflict"}}}} =
             request(backend, "same", scope, send_request("different"))

    assert {:ok, %{"value" => %{"runs" => [_]}}} = query(backend, scope, "workspace")
  end

  test "unsaved runtime refuses web modes without sending disguised prompts", %{
    backend: backend,
    scope: scope
  } do
    for text <- ["/swarm implement", "/goal ship it", "/plan", "/compact", "/workflow review"] do
      assert {:ok, %{"value" => %{"status" => "rejected", "error" => %{"code" => "not_allowed"}}}} =
               request(backend, "slash-" <> text, scope, send_request(text))
    end

    refute_receive {:provider_waiting, _}, 50
    assert {:ok, %{"value" => %{"runs" => []}}} = query(backend, scope, "workspace")
  end

  test "resolves scope membership, rejects unknown actions and gates implicit transient use", %{
    backend: backend,
    scope: scope,
    opts: opts
  } do
    assert {:error, :canonical_persistence_required} =
             LiveBackend.start_link(Keyword.delete(opts, :mode))

    foreign = %{scope | id: "55555555-5555-4555-8555-555555555555"}
    assert {:error, %{"code" => "not_allowed"}} = query(backend, foreign, "workspace")

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             request(backend, "bad", scope, %{send_request() | operation: :invented})
  end

  test "navigation generations preserve membership while invalid scopes are refused", %{
    backend: backend,
    scope: scope
  } do
    assert {:ok, %{"value" => %{"conversation_id" => @conversation}}} =
             query(backend, %{scope | generation: 1}, "workspace")

    assert {:watch, 0, 0, "workspace_snapshot", _} =
             watch(backend, %{scope | generation: 7}, "after-navigation")

    assert {:error, %{"code" => "not_allowed"}} =
             query(backend, %{scope | generation: -1}, "workspace")

    assert {:error, %{"code" => "not_allowed"}} =
             query(
               backend,
               %{scope | generation: 7, id: "55555555-5555-4555-8555-555555555555"},
               "workspace"
             )
  end

  test "credit is cumulative and unregister removes connection watches", %{
    backend: backend,
    scope: scope
  } do
    watch(backend, scope, "credit")
    request(backend, "credit-run", scope, send_request())
    assert_receive {:provider_waiting, provider}, 5_000
    send(provider, :release)
    send(backend, {:service_ready, self(), "credit"})
    assert_receive {:service_delta, ^backend, "credit", first}, 5_000
    refute_receive {:service_delta, _, _, _}, 20
    send(backend, {:service_credit, self(), "credit", first["sequence"]})
    assert_receive {:service_delta, ^backend, "credit", second}, 5_000
    send(backend, {:service_credit, self(), "credit", first["sequence"]})
    refute_receive {:service_delta, _, _, _}, 20
    assert second["sequence"] == first["sequence"] + 1
    send(backend, {:service_unwatch, self(), "credit"})
    send(backend, {:service_credit, self(), "credit", second["sequence"]})
    refute_receive {:service_delta, _, _, _}, 20
  end

  test "terminal children retire while transcript history remains", %{
    backend: backend,
    scope: scope
  } do
    {:ok, %{"value" => %{"identifiers" => [id]}}} =
      request(backend, "retire", scope, send_request())

    assert_receive {:provider_waiting, provider}, 5_000
    send(provider, :release)
    wait_done(backend, scope, id)
    # Query is serialized after the backend's retirement message.
    query(backend, scope, "workspace")
    state = :sys.get_state(backend)
    assert state.runs[id].pid == nil
    assert DynamicSupervisor.count_children(state.supervisor).active == 0
    assert {:ok, %{"value" => %{"items" => items}}} = query(backend, scope, "transcript")
    assert Enum.any?(items, &(&1["text"] == "live"))
  end

  test "detail uses byte offsets and rejects foreign scope", %{backend: backend, scope: scope} do
    text = String.duplicate("界", 1000)
    request(backend, "detail-run", scope, send_request(text))
    {:ok, %{"value" => %{"items" => items}}} = query(backend, scope, "transcript")
    user = Enum.find(items, &(&1["role"] == "user"))
    ref = user["detail_ref"]["id"]
    assert String.valid?(user["text"])

    req = %ServiceRequest{
      operation: :detail,
      params: %{"detail_ref" => ref, "offset" => 2046, "bytes" => 4},
      timeout_ms: 5000
    }

    assert {:ok, %{"value" => %{"text" => "界", "next_offset" => 2049}}} =
             request(backend, "details", scope, req)

    assert {:ok, %{"value" => %{"state" => "error"}}} =
             request(backend, "bad-offset", scope, %{
               req
               | params: Map.put(req.params, "offset", 1)
             })

    foreign = %{scope | id: "55555555-5555-4555-8555-555555555555"}
    assert {:error, %{"code" => "not_allowed"}} = request(backend, "foreign", foreign, req)
  end

  test "live tool detail pages rebuild the projected tool name, newline and output", %{
    opts: opts,
    scope: scope
  } do
    File.write!(Path.join(opts[:project_root], "wide.txt"), String.duplicate("界é😀", 1500))

    server =
      HTTP.start(fn socket, _request, turn ->
        case turn do
          1 ->
            HTTP.stream(socket, [
              HTTP.sse(%{
                "choices" => [
                  %{
                    "delta" => %{
                      "tool_calls" => [
                        %{
                          "index" => 0,
                          "id" => "read-1",
                          "type" => "function",
                          "function" => %{
                            "name" => "read_file",
                            "arguments" => Jason.encode!(%{"path" => "wide.txt"})
                          }
                        }
                      ]
                    },
                    "finish_reason" => "tool_calls"
                  }
                ]
              })
            ])

          _ ->
            HTTP.stream(socket, [
              HTTP.sse(%{
                "choices" => [
                  %{"index" => 0, "delta" => %{"content" => "done"}, "finish_reason" => "stop"}
                ]
              })
            ])
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Provider.new(
        name: "tool",
        base_url: server.url,
        api_key: "secret",
        default_model: "fixture"
      )

    {:ok, tool_backend} =
      start_supervised(
        Supervisor.child_spec(
          {LiveBackend, Keyword.put(opts, :provider, provider) |> Keyword.put(:approval, :auto)},
          id: :tool_backend
        )
      )

    {:ok, %{"value" => %{"identifiers" => [run_id]}}} =
      request(tool_backend, "tool-run", scope, send_request("read it"))

    wait_done(tool_backend, scope, run_id)
    [tool] = :sys.get_state(tool_backend).runs[run_id].tools
    expected = tool.tool <> "\n" <> tool.text
    assert byte_size(tool.text) > 2048

    {:ok, %{"value" => %{"items" => items}}} = query(tool_backend, scope, "transcript")
    item = Enum.find(items, &(&1["id"] == tool.id))
    assert %{"id" => ref, "total_bytes" => total} = item["detail_ref"]
    assert ref == tool.id <> ":text"
    assert total == byte_size(expected)

    pages = fetch_pages(tool_backend, scope, ref, 0, 7, [])
    assert Enum.all?(pages, &(String.valid?(&1) and byte_size(&1) <= 7))
    assert IO.iodata_to_binary(pages) == expected

    assert IO.iodata_to_binary(fetch_pages(tool_backend, scope, ref, 0, 65_536, [])) == expected

    {first_multibyte, _} = :binary.match(expected, "界")
    split = first_multibyte + 1

    assert {:ok, %{"value" => %{"state" => "error", "error" => error}}} =
             request(tool_backend, "split", scope, detail(ref, split, 4))

    assert error == %{"code" => "invalid_request"} or error["code"] == "invalid_request"

    assert {:ok, %{"value" => %{"state" => "error", "error" => ^error}}} =
             request(tool_backend, "unknown", scope, detail(tool.id <> ":other", 0, 4))

    foreign = %{scope | id: "55555555-5555-4555-8555-555555555555"}

    assert {:error, %{"code" => "not_allowed"}} =
             request(tool_backend, "foreign-tool", foreign, detail(ref, 0, 4))
  end

  test "request capacity rejects before a run can start", %{backend: backend, scope: scope} do
    :sys.replace_state(backend, fn state ->
      %{state | requests: Map.new(1..4096, &{Integer.to_string(&1), {:occupied, :occupied}})}
    end)

    assert {:ok,
            %{"value" => %{"status" => "rejected", "error" => %{"code" => "capacity_exceeded"}}}} =
             request(backend, "new", scope, send_request())

    assert {:ok, %{"value" => %{"runs" => []}}} = query(backend, scope, "workspace")
    refute_receive {:provider_waiting, _}, 20
  end

  test "connection death removes watch registrations", %{backend: backend, scope: scope} do
    owner = self()

    reader =
      spawn(fn ->
        result = watch(backend, scope, "owned")
        send(owner, {:registered, result})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, {:watch, _, _, _, _}}
    monitor = Process.monitor(reader)
    send(reader, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}
    query(backend, scope, "workspace")
    assert :sys.get_state(backend).watches == %{}
  end

  test "slow watch coalesces hundreds of real stream events without losing final text", %{
    backend: backend,
    scope: scope
  } do
    watch(backend, scope, "slow")

    {:ok, %{"value" => %{"identifiers" => [id]}}} =
      request(backend, "burst", scope, send_request("burst"))

    assert_receive {:provider_waiting, provider}, 5_000
    send(provider, :release)
    wait_done(backend, scope, id, 500)
    refute_receive {:service_overflow, _, _}
    send(backend, {:service_ready, self(), "slow"})
    deltas = drain_to_done(backend, "slow", id)

    assert Enum.any?(
             deltas,
             &(&1["kind"] == "node_upsert" and
                 &1["body"]["text"] == String.duplicate("a", 500) <> "live")
           )
  end

  test "the unsaved session emits every wire-contract field with defaults", %{
    backend: backend,
    scope: scope
  } do
    {:ok, %{"value" => %{"identifiers" => [id]}}} =
      request(backend, "contract", scope, send_request())

    assert {:ok, %{"value" => live}} = query(backend, scope, "workspace")
    assert [run] = live["runs"]
    assert run["agents_running"] == 1
    assert run["finished_at"] == nil
    assert is_integer(run["started_at"]) and run["started_at"] > 0

    assert_receive {:provider_waiting, provider}, 5_000
    send(provider, :release)
    wait_done(backend, scope, id)

    assert {:ok, %{"value" => workspace}} = query(backend, scope, "workspace")
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot.decode(workspace)
    assert workspace["changes"] == []
    assert workspace["verdicts"] == []
    assert [run] = workspace["runs"]

    assert Map.take(run, ~w(tokens_in tokens_out cost_usd model agents_total agents_running
                            needs changes consensus error)) == %{
             "tokens_in" => 0,
             "tokens_out" => 0,
             "cost_usd" => nil,
             "model" => nil,
             "agents_total" => 1,
             "agents_running" => 0,
             "needs" => 0,
             "changes" => 0,
             "consensus" => false,
             "error" => nil
           }

    assert is_integer(run["finished_at"]) and run["finished_at"] >= run["started_at"]

    node_id = :sys.get_state(backend).runs[id].node_id

    for item <- workspace["transcript"]["items"] do
      assert item["kind"] == "text"
      assert item["tool"] == nil
      assert item["agent_id"] == node_id
      assert item["tokens_in"] == 0 and item["tokens_out"] == 0
      assert item["at"] == run["started_at"]
    end

    assert {:ok, %{"value" => detail}} =
             query(backend, %{scope | kind: :run, id: id}, "inspector")

    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.DTO.RunDetailSnapshot.decode(detail)
    assert [agent] = detail["agents"]
    assert agent["id"] == node_id
    assert agent["run_id"] == id
    assert agent["name"] == "Assistant"
    assert agent["role"] == "assistant"
    assert agent["step"] == "done"
    assert agent["state"] == "done"
    assert agent["progress"] == 0
    assert agent["parent_id"] == nil
    assert agent["depth"] == 0
    assert agent["started_at"] == run["started_at"]
    assert agent["finished_at"] == run["finished_at"]
    assert agent["error"] == nil
  end

  defp detail(ref, offset, bytes),
    do: %ServiceRequest{
      operation: :detail,
      params: %{"detail_ref" => ref, "offset" => offset, "bytes" => bytes},
      timeout_ms: 5_000
    }

  defp fetch_pages(backend, scope, ref, offset, bytes, acc) do
    assert {:ok, %{"value" => %{"state" => "idle", "text" => text, "next_offset" => next}}} =
             request(backend, "page-#{bytes}-#{offset}", scope, detail(ref, offset, bytes))

    acc = acc ++ [text]
    if next, do: fetch_pages(backend, scope, ref, next, bytes, acc), else: acc
  end

  defp request(backend, id, scope, req),
    do: GenServer.call(backend, {:service_request, id, scope, req})

  defp query(backend, scope, slot),
    do:
      request(backend, "query", scope, %ServiceRequest{
        operation: :query,
        params: %{
          "slot" => slot,
          "cursor" => nil,
          "direction" => "after",
          "page_size" => 20,
          "byte_limit" => 65_536
        },
        timeout_ms: 5_000
      })

  defp watch(backend, scope, ref),
    do:
      GenServer.call(
        backend,
        {:service_watch, self(), "watch-req", scope,
         %ServiceRequest{
           operation: :watch,
           params: %{
             "watch_ref" => ref,
             "slot" => "workspace",
             "page_size" => 20,
             "byte_limit" => 65_536
           },
           timeout_ms: 5_000
         }}
      )

  defp send_request(text \\ "hello"),
    do: %ServiceRequest{
      operation: :dispatch_send,
      params: %{
        "action" => "send",
        "text" => text,
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => []
      },
      timeout_ms: 5_000
    }

  defp wait_done(backend, scope, id, tries \\ 100)
  defp wait_done(_backend, _scope, _id, 0), do: flunk("run never completed")

  defp wait_done(backend, scope, id, tries) do
    {:ok, %{"value" => %{"runs" => runs}}} = query(backend, scope, "workspace")

    if Enum.any?(runs, &(&1["id"] == id and &1["state"] == "done")),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_done(backend, scope, id, tries - 1)
        )
  end

  defp drain_to_done(backend, ref, id, acc \\ []) do
    assert_receive {:service_delta, ^backend, ^ref, delta}, 5_000
    send(backend, {:service_credit, self(), ref, delta["sequence"]})
    acc = acc ++ [delta]

    if delta["kind"] == "run_update" and delta["body"]["id"] == id and
         delta["body"]["state"] == "done",
       do: acc,
       else: drain_to_done(backend, ref, id, acc)
  end
end
