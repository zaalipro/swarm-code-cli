defmodule SwarmCode.Daemon.Runtime.RunSinkTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias SwarmCode.Daemon.Runtime.Run
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  defmodule Sink do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts),
      do:
        {:ok,
         %{
           owner: opts[:owner],
           hold: opts[:hold],
           reject: opts[:reject],
           invalid_ack: opts[:invalid_ack],
           records: [],
           pending: nil
         }}

    def handle_call({:append_run_event, record}, from, state) do
      send(state.owner, {:canonical, record})
      state = %{state | records: state.records ++ [record]}

      cond do
        record.event.type == state.invalid_ack ->
          {:reply, {:ok, record.sequence + 1}, state}

        record.event.type == state.reject ->
          {:reply, {:error, "secret must not escape"}, state}

        record.event.type == state.hold or
            {record.event.type, Map.get(record.event, :kind)} == state.hold ->
          {:noreply, %{state | pending: {from, record.sequence}}}

        true ->
          {:reply, {:ok, record.sequence}, state}
      end
    end

    def handle_call(:release, _, %{pending: {from, sequence}} = state) do
      GenServer.reply(from, {:ok, sequence})
      {:reply, :ok, %{state | pending: nil, hold: nil}}
    end

    def handle_call(:records, _, state), do: {:reply, state.records, state}
  end

  setup do
    unless Process.whereis(SwarmCode.LLM.ProviderCaps),
      do: start_supervised!(SwarmCode.LLM.ProviderCaps)

    SwarmCode.LLM.ProviderCaps.reset()

    root =
      Path.join(System.tmp_dir!(), "swarm-sink-" <> Base.encode16(:crypto.strong_rand_bytes(12)))

    File.mkdir!(root)
    File.write!(Path.join(root, "answer.txt"), "original")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "tool admission must commit before launch and full results have real causal identities", %{
    root: root
  } do
    sink = start_supervised!({Sink, owner: self(), hold: :tool_admitted})

    server =
      fixture(fn socket, _, turn ->
        if turn == 1,
          do:
            tool(socket, "same-call", "write_file", %{
              "path" => "answer.txt",
              "content" => "changed"
            }),
          else: answer(socket, "done")
      end)

    id = "11111111-1111-4111-8111-111111111111"
    agent = "22222222-2222-4222-8222-222222222222"
    run = run!(server, root, sink, id: id, agent_id: agent)
    assert_receive {:canonical, %{event: %{type: :tool_admitted}} = admitted}, 5_000
    assert File.read!(Path.join(root, "answer.txt")) == "original"
    refute_receive {:run_event, _, _, %{type: :tool_started}}
    assert Run.snapshot(run).durability == :acknowledged_sink
    assert Run.snapshot(run).agent_id == agent
    assert :ok = GenServer.call(sink, :release)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    assert File.read!(Path.join(root, "answer.txt")) == "changed"
    records = GenServer.call(sink, :records)
    assert Enum.map(records, & &1.sequence) == Enum.to_list(1..length(records))
    assert Enum.all?(records, &(&1.run_id == id and &1.agent_id == agent))
    assert Enum.all?(records, &(Map.get(&1, :writer) == run))
    model = Enum.find(records, &(&1.event.type == :model_completed))
    tool_result = Enum.find(records, &(&1.event.type == :tool_completed))
    assert admitted.event.parent_model_operation_id == model.operation_id
    assert tool_result.operation_id == admitted.operation_id
    assert tool_result.event.parent_model_operation_id == model.operation_id
    assert model.event.result.tool_calls != []
    assert Map.has_key?(model.event.result, :provider_blocks)
    assert Map.has_key?(model.event.result, :usage)
    assert Enum.find(records, &(&1.event.type == :started)).event.prompt == "do work"
  end

  test "rejected effect admission fences with a fixed reason and changes no file", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), reject: :tool_admitted})

    server =
      fixture(fn socket, _, _ ->
        tool(socket, "write", "write_file", %{"path" => "answer.txt", "content" => "changed"})
      end)

    run = run!(server, root, sink)
    monitor = Process.monitor(run)
    assert_receive {:DOWN, ^monitor, :process, ^run, :canonical_sink_failed}, 5_000
    assert File.read!(Path.join(root, "answer.txt")) == "original"
    refute_receive {:run_event, _, _, %{type: :finished}}
    refute_receive {:http_request, 2, _}
  end

  test "terminal commit gates await and final publication", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), hold: :finished})
    server = fixture(fn socket, _, _ -> answer(socket, "done") end)
    run = run!(server, root, sink)
    assert_receive {:canonical, %{event: %{type: :finished}}}, 5_000
    owner = self()

    {waiter, waiter_monitor} =
      spawn_monitor(fn -> send(owner, {:awaited, Run.await(run, 5_000)}) end)

    refute_receive {:awaited, _}
    refute_receive {:run_event, _, _, %{type: :finished}}
    refute Run.snapshot(run).status == :completed
    assert :ok = GenServer.call(sink, :release)
    assert_receive {:awaited, {:ok, %{status: :completed}}}, 5_000
    assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, :normal}, 5_000
  end

  test "held progress append permits immediate command cancellation and cleanup", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), hold: :tool_progress})

    server =
      fixture(fn socket, _, _ ->
        tool(socket, "cmd", "run_command", %{
          "command" => "printf started; sleep 2; printf leaked > leaked.txt"
        })
      end)

    run = run!(server, root, sink, canonical_timeout_ms: 5_000)
    assert_receive {:canonical, %{event: %{type: :tool_progress}}}, 5_000
    assert :ok = Run.stop(run)
    # The sink stays held beyond the shell's side effect deadline. Stop must
    # settle the native command even though its progress caller cannot return.
    receive do
    after
      2_200 -> :ok
    end

    refute File.exists?(Path.join(root, "leaked.txt"))
    assert :ok = GenServer.call(sink, :release)
    assert {:ok, %{status: :cancelled}} = Run.await(run, 5_000)
    records = GenServer.call(sink, :records)
    assert Enum.any?(records, &(&1.event.type == :operation_settled and &1.event.kind == :tool))
  end

  test "sink timeout fences without launching admitted work", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), hold: :tool_admitted})

    server =
      fixture(fn socket, _, _ ->
        tool(socket, "write", "write_file", %{"path" => "answer.txt", "content" => "changed"})
      end)

    run = run!(server, root, sink, canonical_timeout_ms: 100)
    monitor = Process.monitor(run)
    assert_receive {:DOWN, ^monitor, :process, ^run, :canonical_sink_failed}, 5_000
    assert File.read!(Path.join(root, "answer.txt")) == "original"
  end

  test "canonical sink retains all stream records despite presentation overflow", %{root: root} do
    sink = start_supervised!({Sink, owner: self()})

    server =
      fixture(fn socket, _, _ ->
        chunks =
          for _ <- 1..70,
              do:
                HTTP.sse(%{
                  "choices" => [%{"delta" => %{"content" => "x"}, "finish_reason" => nil}]
                })

        HTTP.stream(
          socket,
          chunks ++ [HTTP.sse(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})]
        )
      end)

    run = run!(server, root, sink)
    assert {:ok, %{status: :completed, text: text}} = Run.await(run, 5_000)
    assert text == String.duplicate("x", 70)
    assert_receive {:run_snapshot_required, _, _}
    records = GenServer.call(sink, :records)
    assert Enum.count(records, &(&1.event.type == :text_delta)) == 70
    assert List.last(records).event.type == :finished
  end

  test "invalid canonical options refuse before network work", %{root: root} do
    {:ok, provider} =
      Provider.new(name: "fixture", base_url: "http://127.0.0.1:1", api_key: "fixture")

    for extra <- [
          [id: "bad"],
          [agent_id: "BAD"],
          [canonical_sink: :bad],
          [canonical_timeout_ms: 0]
        ] do
      assert {:error, :invalid_run_configuration} =
               Run.start_link(
                 [provider: provider, model: "fixture", prompt: "work", project_root: root] ++
                   extra
               )
    end
  end

  test "pause queued during tool admission prevents execution until continue", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), hold: :tool_admitted})

    server =
      fixture(fn socket, _, turn ->
        if turn == 1,
          do:
            tool(socket, "write", "write_file", %{"path" => "answer.txt", "content" => "changed"}),
          else: answer(socket, "done")
      end)

    run = run!(server, root, sink)
    assert_receive {:canonical, %{event: %{type: :tool_admitted}}}, 5_000
    owner = self()
    spawn(fn -> send(owner, {:paused_reply, Run.pause(run)}) end)
    wait_until(fn -> :sys.get_state(run).controls != [] end)
    assert :ok = GenServer.call(sink, :release)
    assert_receive {:paused_reply, :ok}, 5_000
    assert_receive {:run_event, _, _, %{type: :paused}}, 5_000
    refute_receive {:run_event, _, _, %{type: :tool_started}}
    assert File.read!(Path.join(root, "answer.txt")) == "original"
    assert :ok = Run.continue(run)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    assert File.read!(Path.join(root, "answer.txt")) == "changed"
  end

  test "invalid acknowledgement fences before network work", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), invalid_ack: :model_admitted})
    server = fixture(fn socket, _, _ -> answer(socket, "must not run") end)
    run = run!(server, root, sink)
    monitor = Process.monitor(run)
    assert_receive {:DOWN, ^monitor, :process, ^run, :canonical_sink_failed}, 5_000
    refute_receive {:http_request, _, _}
  end

  test "sink death fences and closes an executing provider request", %{root: root} do
    owner = self()
    sink = start_supervised!({Sink, owner: self()})

    server =
      fixture(fn socket, _, _ ->
        send(owner, :provider_open)
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        send(owner, :provider_closed)
      end)

    run = run!(server, root, sink)
    monitor = Process.monitor(run)
    assert_receive :provider_open, 5_000
    GenServer.stop(sink, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^run, :canonical_sink_failed}, 5_000
    assert_receive :provider_closed, 5_000
  end

  test "full read results and repeated provider call IDs retain different model parents", %{
    root: root
  } do
    full = String.duplicate("é", 35_000)
    File.write!(Path.join(root, "large.txt"), full)
    sink = start_supervised!({Sink, owner: self()})

    server =
      fixture(fn socket, _, turn ->
        if turn < 3,
          do: tool(socket, "reused", "read_file", %{"path" => "large.txt"}),
          else: answer(socket, "done")
      end)

    run = run!(server, root, sink)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    records = GenServer.call(sink, :records)
    results = Enum.filter(records, &(&1.event.type == :tool_completed))
    assert length(results) == 2
    assert length(Enum.uniq_by(results, & &1.operation_id)) == 2
    assert length(Enum.uniq_by(results, & &1.event.parent_model_operation_id)) == 2
    assert Enum.all?(results, &String.contains?(&1.event.text, full))
  end

  test "cancelled partial model records its settled operation and terminal channel owner", %{
    root: root
  } do
    sink = start_supervised!({Sink, owner: self()})

    server =
      fixture(fn socket, _, _ ->
        chunk =
          HTTP.sse(%{
            "choices" => [%{"delta" => %{"content" => "partial"}, "finish_reason" => nil}]
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
      end)

    run = run!(server, root, sink)
    assert_receive {:run_event, _, _, %{type: :text_delta, text: "partial"}}, 5_000
    assert :ok = Run.stop(run)
    assert {:ok, %{status: :cancelled, text: "partial"}} = Run.await(run, 5_000)
    records = GenServer.call(sink, :records)
    admitted = Enum.find(records, &(&1.event.type == :model_admitted))
    settled = Enum.find(records, &(&1.event.type == :operation_settled))
    assert settled.operation_id == admitted.operation_id
    assert settled.event.disposition == :cancelled
    assert List.last(records).event.model_operation_id == admitted.operation_id
    assert List.last(records).event.result.text == "partial"
    assert Enum.any?(records, &(&1.event.type == :model_failed))
  end

  test "stop after a real edit result retains the successful tool outcome", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), hold: {:operation_settled, :tool}})

    server =
      fixture(fn socket, _, turn ->
        if turn == 1,
          do:
            tool(socket, "write", "write_file", %{"path" => "answer.txt", "content" => "changed"}),
          else: answer(socket, "done")
      end)

    run = run!(server, root, sink)

    assert_receive {:canonical,
                    %{event: %{type: :operation_settled, kind: :tool, result: {:ok, _}}}},
                   5_000

    assert File.read!(Path.join(root, "answer.txt")) == "changed"
    assert :ok = Run.stop(run)
    assert :ok = GenServer.call(sink, :release)
    assert {:ok, %{status: :cancelled}} = Run.await(run, 5_000)
    records = GenServer.call(sink, :records)
    result = Enum.find(records, &(&1.event.type == :tool_completed))
    assert {:ok, _} = result.event.result
    assert result.event.error? == false
    refute_receive {:http_request, 2, _}
  end

  test "terminal rejection never publishes successful completion", %{root: root} do
    sink = start_supervised!({Sink, owner: self(), reject: :finished})
    server = fixture(fn socket, _, _ -> answer(socket, "done") end)
    run = run!(server, root, sink)
    monitor = Process.monitor(run)
    assert_receive {:DOWN, ^monitor, :process, ^run, :canonical_sink_failed}, 5_000
    refute_receive {:run_event, _, _, %{type: :finished}}
  end

  test "steering admitted behind a model admission is consumed by the following turn", %{
    root: root
  } do
    sink = start_supervised!({Sink, owner: self(), hold: :model_admitted})

    server =
      fixture(fn socket, request, turn ->
        messages = Jason.decode!(request.body)["messages"]

        if turn == 1 do
          assert List.last(messages)["content"] == "do work"
          answer(socket, "first")
        else
          assert List.last(messages)["content"] == "also explain"
          answer(socket, "explained")
        end
      end)

    run = run!(server, root, sink)
    assert_receive {:canonical, %{event: %{type: :model_admitted}}}, 5_000
    owner = self()
    spawn(fn -> send(owner, {:steer_reply, Run.steer(run, "also explain")}) end)
    wait_until(fn -> :sys.get_state(run).controls != [] end)
    assert :ok = GenServer.call(sink, :release)
    assert_receive {:steer_reply, :ok}, 5_000
    assert {:ok, %{status: :completed, text: "explained"}} = Run.await(run, 5_000)
    records = GenServer.call(sink, :records)
    steering = Enum.find(records, &(&1.event.type == :steer_admitted))
    assert is_binary(steering.event.id)
    admissions = Enum.filter(records, &(&1.event.type == :model_admitted))
    assert Enum.map(admissions, & &1.event.steer_ids) == [[], [steering.event.id]]
  end

  test "denied approvals preserve full arguments and the parent model without a tool task", %{
    root: root
  } do
    content = String.duplicate("é", 35_000)
    sink = start_supervised!({Sink, owner: self()})

    server =
      fixture(fn socket, _, turn ->
        if turn == 1,
          do:
            tool(socket, "write", "write_file", %{"path" => "answer.txt", "content" => content}),
          else: answer(socket, "denied")
      end)

    run = run!(server, root, sink, approval: :ask)
    assert_receive {:canonical, %{event: %{type: :approval_required}} = approval}, 5_000
    assert approval.event.arguments["content"] == content
    wait_until(fn -> Run.snapshot(run).pending_approval != nil end)
    assert :ok = Run.resolve_approval(run, approval.event.id, :deny)
    assert {:ok, %{status: :completed}} = Run.await(run, 5_000)
    assert File.read!(Path.join(root, "answer.txt")) == "original"
    records = GenServer.call(sink, :records)
    refute Enum.any?(records, &(&1.event.type == :tool_admitted))
    denied = Enum.find(records, &(&1.event.type == :tool_completed))
    assert denied.operation_id == nil
    assert denied.event.error?
    assert denied.event.parent_model_operation_id == approval.event.parent_model_operation_id
  end

  test "Anthropic refusal seals full signed continuation usage and the operation", %{root: root} do
    sink = start_supervised!({Sink, owner: self()})

    server =
      fixture(fn socket, _, _ ->
        HTTP.stream(socket, [
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
          HTTP.event("message_delta", %{
            "delta" => %{"stop_reason" => "refusal"},
            "usage" => %{"output_tokens" => 4}
          }),
          HTTP.event("message_stop", %{})
        ])
      end)

    {:ok, provider} =
      Provider.new(
        name: "fixture",
        kind: "anthropic",
        base_url: server.url,
        api_key: "fixture-secret"
      )

    run =
      start_supervised!(
        {Run,
         [
           provider: provider,
           model: "fixture",
           prompt: "do work",
           project_root: root,
           canonical_sink: sink
         ]}
      )

    assert {:ok, %{status: :failed, error: :provider_refusal}} = Run.await(run, 5_000)
    records = GenServer.call(sink, :records)
    completed = Enum.find(records, &(&1.event.type == :model_completed))
    assert completed.event.result.stop_reason == "refusal"
    assert completed.event.result.usage == %{input: 10, output: 4, cache_read: 5, cache_write: 2}
    assert Enum.any?(completed.event.result.provider_blocks, &(&1["signature"] == "signed-proof"))
    assert List.last(records).event.reasoning == "Reason"

    assert Enum.any?(
             records,
             &(&1.event.type == :operation_settled and &1.operation_id == completed.operation_id)
           )
  end

  test "provider failure and request deadline each close the admitted model operation", %{
    root: root
  } do
    for mode <- [:error, :deadline] do
      sink = start_supervised!({Sink, owner: self()}, id: {:sink, mode})

      server =
        fixture(fn socket, _, _ ->
          if mode == :error do
            HTTP.respond(
              socket,
              400,
              Jason.encode!(%{"error" => %{"message" => "bad request"}}),
              [{"content-type", "application/json"}]
            )
          else
            assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
          end
        end)

      {:ok, provider} =
        Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-secret")

      run =
        start_supervised!(
          {Run,
           [
             provider: provider,
             model: "fixture",
             prompt: "do work",
             project_root: root,
             canonical_sink: sink,
             request_timeout_ms: 100
           ]},
          id: {:run, mode}
        )

      assert {:ok, %{status: :failed}} = Run.await(run, 5_000)
      records = GenServer.call(sink, :records)
      admission = Enum.find(records, &(&1.event.type == :model_admitted))
      failure = Enum.find(records, &(&1.event.type == :model_failed))
      assert failure.operation_id == admission.operation_id

      assert Enum.any?(
               records,
               &(&1.event.type == :operation_settled and &1.operation_id == admission.operation_id)
             )

      refute Enum.any?(records, &(&1.event.type == :tool_admitted))
    end
  end

  for failure_mode <- [:provider_error, :token_limit, :refusal] do
    @failure_mode failure_mode
    test "queued controls cannot reopen a committed #{@failure_mode} terminal", %{root: root} do
      assert_terminal_controls(@failure_mode, root)
    end
  end

  defp assert_terminal_controls(mode, root) do
    held = if mode == :provider_error, do: :model_failed, else: :model_completed
    sink = start_supervised!({Sink, owner: self(), hold: held})

    server =
      fixture(fn socket, _, _ ->
        case mode do
          :provider_error ->
            HTTP.respond(
              socket,
              400,
              Jason.encode!(%{"error" => %{"message" => "bad request"}}),
              [{"content-type", "application/json"}]
            )

          :token_limit ->
            HTTP.stream(socket, [
              HTTP.sse(%{
                "choices" => [
                  %{"delta" => %{"content" => "partial"}, "finish_reason" => "length"}
                ]
              })
            ])

          :refusal ->
            HTTP.stream(socket, [
              HTTP.event("message_start", %{"message" => %{}}),
              HTTP.event("message_delta", %{"delta" => %{"stop_reason" => "refusal"}}),
              HTTP.event("message_stop", %{})
            ])
        end
      end)

    {:ok, provider} =
      Provider.new(
        name: "fixture",
        kind: if(mode == :refusal, do: "anthropic", else: "openai"),
        base_url: server.url,
        api_key: "fixture-secret"
      )

    run =
      start_supervised!(
        {Run,
         [
           provider: provider,
           model: "fixture",
           prompt: "do work",
           project_root: root,
           canonical_sink: sink,
           subscriber: self()
         ]}
      )

    assert_receive {:canonical, %{event: %{type: ^held}}}, 5_000
    owner = self()
    spawn(fn -> send(owner, {:continue_reply, Run.continue(run)}) end)
    wait_until(fn -> length(:sys.get_state(run).controls) == 1 end)
    spawn(fn -> send(owner, {:pause_reply, Run.pause(run)}) end)
    wait_until(fn -> length(:sys.get_state(run).controls) == 2 end)
    spawn(fn -> send(owner, {:steer_reply, Run.steer(run, "too late")}) end)
    wait_until(fn -> length(:sys.get_state(run).controls) == 3 end)
    assert :ok = GenServer.call(sink, :release)
    assert_receive {:continue_reply, {:error, :terminal}}, 5_000
    assert_receive {:pause_reply, {:error, :terminal}}, 5_000
    assert_receive {:steer_reply, {:error, :invalid_steer}}, 5_000
    assert {:ok, %{status: :failed}} = Run.await(run, 1_000)
    assert Run.snapshot(run).status == :failed
    assert {:ok, %{status: :failed}} = Run.await(run, 1_000)
    records = GenServer.call(sink, :records)
    assert List.last(records).event.type == :finished
    assert Enum.count(records, &(&1.event.type == :finished)) == 1

    refute Enum.any?(
             records,
             &(&1.event.type in [:continued, :pause_requested, :steer_admitted])
           )

    refute_receive {:run_event, _, _, %{type: :continued}}
    refute_receive {:http_request, 2, _}
  end

  test "append relay failure logs omit private sink exit reasons and canonical content", %{
    root: root
  } do
    owner = self()

    sink =
      spawn(fn ->
        receive do
          {:"$gen_call", {relay, _}, {:append_run_event, _record}} ->
            send(owner, {:private_append_received, relay})

            receive do
              :fail -> exit({:private_sink_failure, "SINK-PRIVATE-SENTINEL"})
            end
        end
      end)

    on_exit(fn -> if Process.alive?(sink), do: Process.exit(sink, :kill) end)
    server = fixture(fn socket, _, _ -> answer(socket, "must not run") end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        run = run!(server, root, sink, prompt: "CANONICAL-PRIVATE-SENTINEL")
        monitor = Process.monitor(run)
        assert_receive {:private_append_received, relay}, 5_000
        relay_monitor = Process.monitor(relay)
        # Delay the owner so its sink monitor cannot mask a crashing relay's log.
        :sys.suspend(run)

        try do
          send(sink, :fail)
          assert_receive {:DOWN, ^relay_monitor, :process, ^relay, _}, 5_000
        after
          :sys.resume(run)
        end

        assert_receive {:DOWN, ^monitor, :process, ^run, :canonical_sink_failed}, 5_000
      end)

    refute log =~ "SINK-PRIVATE-SENTINEL"
    refute log =~ "CANONICAL-PRIVATE-SENTINEL"
    refute_receive {:http_request, _, _}
  end

  defp wait_until(check), do: wait_until(check, System.monotonic_time(:millisecond) + 4_000)

  defp wait_until(check, deadline) do
    if check.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "condition did not become true"

      receive do
      after
        1 -> :ok
      end

      wait_until(check, deadline)
    end
  end

  defp fixture(handler) do
    server = HTTP.start(handler)
    on_exit(fn -> HTTP.stop(server) end)
    server
  end

  defp run!(server, root, sink, opts \\ []) do
    {:ok, provider} =
      Provider.new(name: "fixture", base_url: server.url, api_key: "fixture-secret")

    start_supervised!(
      {Run,
       Keyword.merge(
         [
           provider: provider,
           model: "fixture",
           prompt: "do work",
           project_root: root,
           approval: :auto,
           subscriber: self(),
           canonical_sink: sink
         ],
         opts
       )}
    )
  end

  defp answer(socket, text),
    do:
      HTTP.stream(socket, [
        HTTP.sse(%{"choices" => [%{"delta" => %{"content" => text}, "finish_reason" => "stop"}]})
      ])

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
end
