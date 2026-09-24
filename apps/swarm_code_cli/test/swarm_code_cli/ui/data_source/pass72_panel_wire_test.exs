defmodule SwarmCodeCLI.UI.DataSource.Pass72PanelWireTest do
  @moduledoc """
  pass72 S: the side panel's agent and run facts cross real JSON through the
  daemon codec (snapshot and delta), an older daemon that omits them still
  decodes, their byte bounds hold, the client rolls the lane forward, and the
  fake data source carries the same facts (parity).
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Lane, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.UI.DataSource.Fake.{Script, Source}
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire

  @conversation "22222222-2222-4222-8222-222222222222"
  @node "44444444-4444-4444-8444-444444444444"
  @wire "11111111-1111-4111-8111-111111111111"
  @run "33333333-3333-4333-8333-333333333333"
  @nonce String.duplicate("A", 43)
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}

  @panel_agent %{
    "panel_state" => "needs_you",
    "now" => "wants to run a command",
    "lane" =>
      ~w(tools tools think write write write tools wait_you wait_you wait_you wait_you wait_you),
    "lane_at" => 1_788_436_800_000,
    "lane_now" => "wait_you",
    "finding" => nil,
    "finding_refs" => [],
    "files_changed" => 2,
    "elapsed_ms" => nil,
    "tokens" => 6_660
  }

  @panel_run %{
    "needs_you" => [
      %{
        "agent_id" => @node,
        "node_id" => @node,
        "agent_name" => "web-ui-desktop",
        "kind" => "approval",
        "text" => "mix test test/swarm_code_web --only ui",
        "reason" => "read-only run, so commands ask",
        "requested_at" => 1_788_436_790_000
      }
    ],
    "reported" => 1,
    "total" => 4,
    "phases" => [
      %{"name" => "scan", "state" => "done", "agent_count" => 2, "live" => 0, "done" => 2},
      %{"name" => "implement", "state" => "running", "agent_count" => 3, "live" => 2, "done" => 1}
    ],
    "phase" => "implement",
    "goal_iteration" => 2,
    "goal_iterations" => 2,
    "goal_status" => "active",
    "round" => 1,
    "rounds" => 2,
    "verdict" => "Two of three proposals meet the bar."
  }

  defp fixture,
    do: File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))

  defp through_json(message) do
    {:ok, bytes} = Envelope.encode(message)
    {:ok, decoded} = Envelope.decode(IO.iodata_to_binary(bytes))
    decoded
  end

  defp watch(slot),
    do: %Watch{
      watch_ref: "watch-1",
      slot: slot,
      scope: @scope,
      generation: 2,
      page_size: 20,
      byte_limit: 262_144
    }

  defp event(sequence, body),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: sequence,
      occurred_at: "2026-09-24T00:00:00Z",
      body: body
    }

  defp snapshot(agent, run) do
    value =
      Wire.workspace()
      |> Map.put("runs", [run])
      |> Map.put("agents", [agent])

    message =
      event(9, %{
        "op" => "watch_ready",
        "watch_ref" => "watch-1",
        "revision" => 7,
        "body_kind" => "workspace_snapshot",
        "value" => value
      })

    Codec.event(through_json(message), watch(:workspace), @nonce)
  end

  describe "wire round trip" do
    test "a workspace snapshot carries the agent and run panel facts" do
      agent = Map.merge(Wire.agent_summary(), @panel_agent)
      run = Map.merge(Wire.run_summary(), @panel_run)

      assert {:ok, %Delivery{kind: :watch_ready, body: page}} = snapshot(agent, run)
      assert [%DTO.AgentSummary{} = a] = page.agents

      assert {a.panel_state, a.now, a.lane_now, a.files_changed, a.tokens} ==
               {:needs_you, "wants to run a command", :wait_you, 2, 6_660}

      assert length(a.lane) == 12 and List.last(a.lane) == :wait_you

      assert [%DTO.RunSummary{} = r] = page.runs

      assert [%DTO.NeedsYou{kind: :approval, agent_name: "web-ui-desktop"} = need] = r.needs_you
      assert need.text == "mix test test/swarm_code_web --only ui"
      assert {r.reported, r.total, r.phase} == {1, 4, "implement"}

      assert [%DTO.Phase{name: "scan", state: :done}, %DTO.Phase{state: :running, live: 2}] =
               r.phases

      assert {r.goal_iteration, r.round, r.rounds} == {2, 1, 2}
    end

    test "an agent_update delta carries the facts" do
      agent =
        Map.merge(Wire.agent_summary(), %{
          @panel_agent
          | "panel_state" => "done",
            "finding" => "Parser drops a chunk.",
            "finding_refs" => ["lib/p.ex:9"],
            "lane" => [],
            "lane_at" => nil,
            "lane_now" => "idle",
            "elapsed_ms" => 58_000
        })

      delta = %{
        "kind" => "agent_update",
        "entity_id" => agent["id"],
        "run_id" => Wire.run_id(),
        "conversation_id" => @conversation,
        "channel" => nil,
        "attempt_id" => nil,
        "text" => nil,
        "body" => agent,
        "sequence" => 4,
        "revision" => 3
      }

      message = event(4, %{"op" => "delta", "watch_ref" => "watch-1", "value" => delta})

      assert {:ok, %Delivery{kind: :delta, body: %Delta{body: %DTO.AgentSummary{} = a}}} =
               Codec.event(through_json(message), watch(:workspace), @nonce)

      assert {a.panel_state, a.finding, a.finding_refs, a.elapsed_ms} ==
               {:done, "Parser drops a chunk.", ["lib/p.ex:9"], 58_000}
    end

    test "an older daemon that omits every pass72 key still decodes, with empty facts" do
      assert {:ok, %Delivery{body: page}} = snapshot(Wire.agent_summary(), Wire.run_summary())

      assert [%DTO.AgentSummary{panel_state: :working, now: "", lane: [], finding: nil}] =
               page.agents

      assert [%DTO.RunSummary{needs_you: [], phases: [], total: 0, round: nil}] = page.runs
    end

    test "the byte bounds and closed enums hold" do
      too_long =
        Map.merge(Wire.agent_summary(), %{@panel_agent | "now" => String.duplicate("x", 81)})

      assert {:error, _} = snapshot(too_long, Wire.run_summary())

      bad_kind = Map.merge(Wire.agent_summary(), %{@panel_agent | "lane" => ["sleep"]})
      assert {:error, _} = snapshot(bad_kind, Wire.run_summary())

      long_finding =
        Map.merge(Wire.agent_summary(), %{@panel_agent | "finding" => String.duplicate("f", 161)})

      assert {:error, _} = snapshot(long_finding, Wire.run_summary())

      [need] = @panel_run["needs_you"]
      long_need = %{@panel_run | "needs_you" => [%{need | "text" => String.duplicate("t", 1025)}]}

      assert {:error, _} =
               snapshot(Wire.agent_summary(), Map.merge(Wire.run_summary(), long_need))
    end
  end

  describe "lane" do
    @at 1_788_436_800_000
    defp agent(lane, now_kind), do: %{lane: lane, lane_at: @at, lane_now: now_kind}

    test "the window rolls forward with the kind still going on" do
      lane = List.duplicate(:think, 11) ++ [:tools]
      assert Lane.window(agent(lane, :tools), @at, 12) == lane
      assert Lane.window(agent(lane, :tools), @at + 4_999, 12) == lane

      assert Lane.window(agent(lane, :tools), @at + 10_000, 12) ==
               List.duplicate(:think, 9) ++ [:tools, :tools, :tools]

      assert Lane.window(agent(lane, :idle), @at + 10_000, 8) ==
               List.duplicate(:think, 5) ++ [:tools, :idle, :idle]

      assert Lane.window(agent(lane, :idle), @at + 3_600_000, 12) == List.duplicate(:idle, 12)
    end

    test "no lane stays empty; compact takes the newest cells" do
      assert Lane.window(%{lane: [], lane_at: nil, lane_now: :idle}, @at, 12) == []

      lane = [
        :idle,
        :idle,
        :idle,
        :idle,
        :think,
        :think,
        :think,
        :think,
        :write,
        :write,
        :tools,
        :tools
      ]

      assert Lane.window(agent(lane, :tools), nil, 8) == Enum.drop(lane, 4)
    end

    test "elapsed is recorded once finished, else the client's clock" do
      assert Lane.elapsed_ms(%{elapsed_ms: 58_000}, @at) == 58_000
      assert Lane.elapsed_ms(%{started_at: @at - 72_000, finished_at: nil}, @at) == 72_000
      assert Lane.elapsed_ms(%{started_at: nil}, @at) == nil
    end
  end

  describe "agent detail" do
    defp detail_request(scope \\ @scope, run \\ @run, node \\ @node),
      do: %Request{
        request_id: "local-1",
        kind: {:agent_detail, run, node},
        scope: scope,
        generation: scope.generation,
        origin: {:query, :agent_detail},
        deadline: 5_000,
        expected_response: :agent_detail
      }

    defp detail_wire(extra \\ %{}),
      do:
        Map.merge(
          %{
            "state" => "idle",
            "request_id" => @wire,
            "error" => nil,
            "run_id" => @run,
            "agent_id" => @node,
            "name" => "web-ui-desktop",
            "role" => "sub",
            "model" => "deepseek-v4-pro",
            "panel_state" => "needs_you",
            "now" => "wants to run a command",
            "parent_name" => "Lead",
            "brief" => "Review the web UI for desktop regressions.",
            "brief_bytes" => 42,
            "needs_you" => @panel_run["needs_you"],
            "findings" => [
              %{
                "n" => 1,
                "severity" => "high",
                "text" => "Esc closes two layers.",
                "ref" => "assets/js/hooks.js:88"
              }
            ],
            "result" => "",
            "result_bytes" => 0,
            "agent_error" => nil,
            "activity" => [
              %{
                "kind" => "read",
                "title" => "read 3 files",
                "items" => ["a.ex", "b.ex", "c.ex"],
                "count" => 3,
                "started_at" => 1_788_436_700_000,
                "duration_ms" => 900,
                "quote" => nil,
                "state" => "done"
              },
              %{
                "kind" => "think",
                "title" => "thought ×2",
                "items" => [],
                "count" => 2,
                "started_at" => 1_788_436_701_000,
                "duration_ms" => 41_000,
                "quote" => "Esc handling lives in two hooks.",
                "state" => "done"
              }
            ],
            "operations" => [
              %{
                "id" => @node,
                "op_type" => "read_file",
                "title" => "read a.ex",
                "status" => "done",
                "started_at" => 1_788_436_700_000,
                "duration_ms" => 300
              }
            ],
            "life" => ~w(think tools tools wait_you),
            "life_started_at" => 1_788_436_700_000,
            "life_bucket_ms" => 1_000,
            "think_ms" => 41_000,
            "files_read" => ["a.ex", "b.ex", "c.ex"],
            "files_searched" => [~s("Escape")],
            "files_changed" => [],
            "changes_stat" => nil,
            "tokens_in" => 18_000,
            "tokens_out" => 3_000,
            "cost_usd" => 0.05,
            "context_used" => 18_000,
            "context_window" => 98_304,
            "turn" => nil,
            "max_turns" => nil,
            "started_at" => 1_788_436_700_000,
            "finished_at" => nil
          },
          extra
        )

    defp detail_result(value),
      do: %Message{
        version: 1,
        sequence: nil,
        occurred_at: nil,
        type: :response,
        request_id: @wire,
        nonce: @nonce,
        scope: @scope,
        body: %{"op" => "result", "response_kind" => "agent_detail", "value" => value}
      }

    test "the request is a closed agent.detail body" do
      assert {:ok, message} = Codec.request(detail_request(), @wire, @nonce, 0)

      assert Map.drop(message.body, ["timeout_ms"]) ==
               %{"op" => "agent.detail", "run_id" => @run, "node_id" => @node}

      assert {:error, :invalid_request} =
               Request.validate(%{detail_request() | kind: {:agent_detail, "run", @node}})

      assert {:error, :invalid_request} =
               Request.validate(%{detail_request() | expected_response: :outcome})
    end

    test "the response crosses JSON and decodes with its groups, findings and band" do
      assert {:ok, %Delivery{kind: :response, body: %DTO.AgentDetail{} = d}} =
               Codec.response(
                 through_json(detail_result(detail_wire())),
                 detail_request(),
                 @wire,
                 @nonce
               )

      assert d.request_id == "local-1"
      assert {d.name, d.panel_state, d.parent_name} == {"web-ui-desktop", :needs_you, "Lead"}
      assert [%DTO.Finding{severity: :high, ref: "assets/js/hooks.js:88"}] = d.findings

      assert [%DTO.ActivityGroup{kind: :read, count: 3}, %DTO.ActivityGroup{kind: :think} = t] =
               d.activity

      assert t.quote == "Esc handling lives in two hooks."
      assert [%DTO.OpLine{op_type: "read_file"}] = d.operations
      assert d.life == [:think, :tools, :tools, :wait_you]
      assert [%DTO.NeedsYou{text: "mix test test/swarm_code_web --only ui"}] = d.needs_you
    end

    test "a detail for another agent than asked is refused" do
      other = "55555555-5555-4555-8555-555555555555"

      assert {:error, _} =
               Codec.response(
                 through_json(detail_result(detail_wire(%{"agent_id" => other}))),
                 detail_request(),
                 @wire,
                 @nonce
               )
    end

    test "the overlay composer steers only its agent: run.steer names the node" do
      request = %Request{
        request_id: "local-3",
        kind: {:steer, @run, @node, "check the Esc path only", []},
        scope: @scope,
        generation: 2,
        origin: {:draft, {@conversation, {:thread, @node}}},
        deadline: 5_000,
        expected_response: :outcome
      }

      assert {:ok, message} = Codec.request(request, @wire, @nonce, 0)

      assert Map.drop(message.body, ["timeout_ms"]) == %{
               "op" => "run.steer",
               "run_id" => @run,
               "node_id" => @node,
               "text" => "check the Esc path only",
               "attachment_refs" => []
             }
    end

    test "the fake answers with the agent's synthetic detail, and refuses a stranger" do
      {:ok, script} = Script.decode(fixture())
      pid = start_supervised!({Source, script: script, source_epoch: "epoch-1"})
      Source.attach(pid, "client", self())
      scope = %Scope{kind: :conversation, id: Script.id(:a), generation: 0}

      request = %{
        detail_request(scope, Script.id(:a2), Script.id(:scout_1))
        | deadline: Script.clock_ms() + 5_000
      }

      assert :ok = Source.request(pid, "client", request)
      assert_receive {:fake_source, "client", %Delivery{body: %DTO.AgentDetail{} = d}}
      assert {d.name, d.state, d.parent_name} == {"scout-1", :idle, "lead"}
      assert [%DTO.Finding{n: 1, severity: :high} | _] = d.findings
      assert {:ok, _} = DTO.AgentDetail.validate(d)

      stranger = %{request | request_id: "local-2", kind: {:agent_detail, Script.id(:a2), @node}}
      assert {:error, _} = Source.request(pid, "client", stranger)
    end
  end

  describe "fake parity" do
    test "the fake's agents and consensus run carry the panel facts the daemon sends" do
      {:ok, script} = Script.decode(fixture())
      agents = Map.new(script.agents, fn {_, a} -> {a.name, a} end)

      assert {agents["lead"].panel_state, agents["lead"].now} == {:waiting, "waiting on 3 agents"}
      assert agents["scout-2"].panel_state == :thinking
      assert agents["judge"].panel_state == :queued

      for {_, a} <- script.agents do
        assert a.tokens == a.tokens_in + a.tokens_out
        assert a.lane == [] or length(a.lane) == 12
        assert byte_size(a.now) in 1..80
        refute a.now =~ "swarm/"
      end

      a2 = script.runs[Script.id(:a2)]
      assert {a2.reported, a2.total, a2.round, a2.rounds} == {0, 4, 1, 2}
      assert a2.verdict =~ "Two of three"
    end

    test "a pending approval is on its run's band with the literal command, and leaves with it" do
      {:ok, script} = Script.decode(fixture())
      pid = start_supervised!({Source, script: script, source_epoch: "epoch-1"})
      Source.attach(pid, "client", self())
      assert :ok = Source.advance(pid, "catalogue-activity")
      assert_receive {:fake_source, "client", deltas}
      assert Enum.all?(deltas, &match?({:ok, _}, Delta.validate(&1)))

      a1 = Source.snapshot(pid).runs[Script.id(:a1)]

      assert [%DTO.NeedsYou{kind: :approval} = need | _] =
               Enum.filter(a1.needs_you, &(&1.kind == :approval))

      assert need.text == "mix test test/swarm_code/repo_test.exs"
      assert need.reason == "Run the repository tests after the refresh change."

      assert Enum.any?(deltas, fn
               %Delta{kind: :run_update, body: %DTO.RunSummary{id: id, needs_you: [_ | _]}} ->
                 id == Script.id(:a1)

               _ ->
                 false
             end)
    end
  end
end
