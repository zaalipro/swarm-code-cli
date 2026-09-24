defmodule SwarmCode.Daemon.Service.Pass72PanelFactsTest do
  @moduledoc """
  pass72 S: the side panel's derivations from seeded agent rows and
  operations — the P3 state, the one plain sentence, the rolling lane, the
  finding and its `path:line` refs, the needs-you band and workflow phases.
  None of them may carry an id, a branch or a worktree path.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.PanelFacts, as: Facts

  @t0 ~U[2026-09-24 10:00:00.000000Z]
  @root "/Users/me/dev/app"
  @worktree "/Users/me/dev/app/.swarm_code/worktrees/2404157a/engine-review-bd868c6f"

  defp at(s), do: DateTime.add(@t0, round(s * 1000), :millisecond)
  defp t0_ms, do: DateTime.to_unix(@t0, :millisecond)

  defp agent(attrs \\ %{}),
    do:
      Map.merge(
        %{
          id: "a1",
          status: "running",
          name: "engine-review",
          error: nil,
          tokens_in: 1200,
          tokens_out: 300,
          started_at: @t0,
          finished_at: nil,
          result_head: nil,
          detail: "isolated in swarm/2404157a/engine-review-bd868c6f",
          workspace_path: @worktree
        },
        attrs
      )

  defp op(type, title, from, to, attrs \\ %{}),
    do:
      Map.merge(
        %{
          id: "op-#{type}-#{from}",
          parent_id: "a1",
          op_type: type,
          status: if(to, do: "done", else: "running"),
          title: title,
          detail: "",
          started_at: at(from),
          finished_at: to && at(to)
        },
        attrs
      )

  defp facts(n, ops, opts \\ []),
    do: Facts.agent(n, ops, Keyword.merge([roots: [@root, n[:workspace_path]]], opts))

  describe "state and sentence" do
    test "an open tool is working, and the sentence names what it does" do
      f = facts(agent(), [op("read_file", "read lib/app/engine.ex", 50, nil)])
      assert f["panel_state"] == "working"
      assert f["now"] == "reading lib/app/engine.ex"

      assert facts(agent(), [op("grep", "grep Escape|esc", 50, nil)])["now"] ==
               ~s(searching "Escape|esc")

      assert facts(agent(), [op("run_command", "run: mix test test/app_test.exs", 50, nil)])[
               "now"
             ] == "running mix test test/app_test.exs"

      assert facts(agent(), [op("edit_file", "edit lib/y.ex", 50, nil)])["now"] ==
               "editing lib/y.ex"

      assert facts(agent(), [op("web_fetch", "fetch https://hexdocs.pm/x", 5, nil)])["now"] ==
               "fetching hexdocs.pm"
    end

    test "a worktree path in a title is shown relative to the worktree" do
      f = facts(agent(), [op("read_file", "read #{@worktree}/lib/app/run.ex", 5, nil)])
      assert f["now"] == "reading lib/app/run.ex"

      f = facts(agent(), [op("run_command", "run: mix test (in #{@worktree})", 5, nil)])
      assert f["now"] == "running mix test"
    end

    test "an open think quotes the freshest complete sentence of its reasoning" do
      llm =
        op("llm", "thinking", 40, nil, %{
          detail: "I read the stop path. Now tracing how RunServer stops agents. It then"
        })

      f = facts(agent(), [llm])
      assert f["panel_state"] == "thinking"
      assert f["now"] == "Now tracing how RunServer stops agents."
    end

    test "a finished think gives its opening sentence; no reasoning at all says thinking" do
      llm = op("llm", "thinking", 10, 20, %{detail: "Weighing flush safety first. Then more."})
      open = op("llm", "thinking", 21, nil, %{detail: ""})
      # An open think with no sentence yet: the one before it.
      assert facts(agent(), [open, llm])["now"] == "Weighing flush safety first."
      assert facts(agent(), [open])["now"] == "thinking"
      # With only the finished one, the state is working between steps.
      assert facts(agent(), [llm])["now"] == "working"
    end

    test "a lead blocked on spawned agents waits, and counts them" do
      spawns =
        for {n, i} <- Enum.with_index(~w(data llm web)),
            do: op("spawn_agent", "agent #{n}", i, nil, %{id: "s#{i}"})

      f = facts(agent(%{name: "Lead"}), spawns)
      assert f["panel_state"] == "waiting"
      assert f["now"] == "waiting on 3 agents"

      one = facts(agent(), [op("spawn_agent", "agent data-review", 1, nil)])
      assert one["now"] == "waiting on data-review"
    end

    test "needs you: the state and a short sentence; the band carries the text" do
      waiting = op("run_command", "run: mix test", 50, nil, %{status: "awaiting_approval"})
      f = facts(agent(), [waiting])
      assert f["panel_state"] == "needs_you"
      assert f["now"] == "wants to run a command"
      assert f["lane_now"] == "wait_you"

      approval = %{
        "kind" => "approval",
        "node_id" => "op1",
        "approval" => %{"tool" => "edit_file", "arguments_preview" => ~s({"path":"lib/y.ex"})}
      }

      assert facts(agent(), [], interactions: [approval])["now"] == "wants to edit lib/y.ex"

      question = %{"kind" => "question", "node_id" => "op2"}
      assert facts(agent(), [], interactions: [question])["now"] == "has a question for you"
    end

    test "done states the finding; failed states the error; nothing leaks the branch" do
      done =
        agent(%{
          status: "done",
          finished_at: at(97),
          result_head:
            "## Findings\n\n1. **Stream retries may repeat a tool call** in `lib/llm/stream.ex:118`. More.\n" <>
              "2. See lib/llm/parser.ex:42 and #{@worktree}/lib/tools/run.ex:7, again lib/llm/stream.ex:118."
        })

      f = facts(done, [])
      assert f["panel_state"] == "done"
      assert f["finding"] == "Stream retries may repeat a tool call in lib/llm/stream.ex:118."
      assert f["now"] == f["finding"]

      assert f["finding_refs"] == [
               "lib/llm/stream.ex:118",
               "lib/llm/parser.ex:42",
               "lib/tools/run.ex:7"
             ]

      assert f["elapsed_ms"] == 97_000
      assert f["lane"] == [] and f["lane_at"] == nil

      failed = agent(%{status: "failed", error: "rate limited by the provider. Retrying later."})
      assert facts(failed, [])["now"] == "failed: rate limited by the provider."

      for f <- [facts(agent(), []), f, facts(failed, [])],
          value <- Map.values(f),
          is_binary(value) do
        refute value =~ "swarm/"
        refute value =~ "worktrees"
        refute value =~ "isolated"
      end
    end

    test "a finding drops a leading severity label" do
      done =
        agent(%{
          status: "done",
          result_head: "1. medium lib/a.ex:51 — casts :role from attrs. Then."
        })

      # pass72 G4 (QA Q4): the leading path:line moves to the refs (D2's
      # `» sentence · fake.ex:88`).
      assert facts(done, [])["finding"] == "casts :role from attrs."
      assert facts(done, [])["finding_refs"] == ["lib/a.ex:51"]
    end

    test "regression (QA Q4): a leading path with line ranges is not the sentence" do
      done =
        agent(%{
          status: "done",
          result_head:
            "lib/ailogic_web/plugs/body_size_limit.ex :20-22 + :31,37: security plug is broken. More."
        })

      assert facts(done, [])["finding"] == "security plug is broken."
      assert facts(done, [])["finding_refs"] == []
    end

    test "regression (QA Q4): a workflow step's structured findings read as a finding" do
      json =
        Jason.encode!(%{
          "findings" => [
            %{
              "detail" =>
                "The section asserts that a React SPA lives at web/. But every file is deleted.",
              "file" => "docs/angular-migration-plan.md",
              "line" => 7,
              "severity" => "high",
              "title" => "The plan describes a tree the change deletes"
            },
            %{"detail" => "Second thing is off. More.", "file" => "lib/b.ex", "line" => 3}
          ]
        })

      done = agent(%{status: "done", result_head: json})
      facts = facts(done, [])
      assert facts["finding"] == "The plan describes a tree the change deletes"
      assert facts["finding_refs"] == ["docs/angular-migration-plan.md:7", "lib/b.ex:3"]

      empty = agent(%{status: "done", result_head: ~s({"findings":[]})})
      assert facts(empty, [])["finding"] == "No findings."

      # The 4 KB head cut inside the second item keeps the first.
      cut = agent(%{status: "done", result_head: binary_part(json, 0, byte_size(json) - 30)})
      assert facts(cut, [])["finding"] == "The plan describes a tree the change deletes"
      refute facts(cut, [])["finding"] =~ "{"

      alias SwarmCode.Daemon.Service.AgentDetail

      assert [
               %{"n" => 1, "severity" => "high", "ref" => "docs/angular-migration-plan.md:7"},
               %{"n" => 2, "text" => "Second thing is off.", "ref" => "lib/b.ex:3"}
             ] = AgentDetail.findings(json, [])
    end

    # pass72 F (P's request 2): the engine's notes on a worker's report are
    # not its finding.
    test "a finding skips the engine's branch and patch notes" do
      done =
        agent(%{
          status: "done",
          result_head:
            "Done.\n\n[Changes on branch swarm/2404157a/web-review (2 files changed). " <>
              "Integrate them with the integrate_agent tool when they are good.]\n" <>
              "Delta patch captured: 812 bytes, 2 files changed"
        })

      assert facts(done, [])["finding"] == nil
      refute facts(done, [])["now"] =~ "swarm/"

      found =
        agent(%{
          status: "done",
          result_head: "[No file changes.]\nThe flush can race the stop in lib/a.ex:9."
        })

      assert facts(found, [])["finding"] == "The flush can race the stop in lib/a.ex:9."
    end

    # pass72 F (live): the real reports opened with narration; the panel said
    # "I've reviewed the core business logic modules." for every reviewer.
    test "a narrated opening gives way to the first numbered finding" do
      done =
        agent(%{
          status: "done",
          result_head:
            "I've reviewed the core business logic modules.\n\n## Findings\n\n" <>
              "1. **High:** the runner retries forever on a 500 (lib/ailogic/automations/runner.ex:127).\n" <>
              "2. Low: a TODO in lib/ailogic/audit.ex:12.\n"
        })

      assert facts(done, [])["finding"] == "the runner retries forever on a 500."
      assert "lib/ailogic/automations/runner.ex:127" in facts(done, [])["finding_refs"]

      cited =
        agent(%{
          status: "done",
          result_head: "The flush races the stop in lib/a.ex:9.\n\n1. Other."
        })

      assert facts(cited, [])["finding"] == "The flush races the stop in lib/a.ex:9."
    end

    test "queued, paused and stopped say so; tokens add up" do
      assert facts(agent(%{status: "queued"}), [])["now"] == "queued"
      assert facts(agent(%{status: "paused"}), [])["panel_state"] == "paused"
      assert facts(agent(%{status: "stopped"}), [])["panel_state"] == "stopped"
      assert facts(agent(), [])["tokens"] == 1500
    end

    test "every sentence fits 80 bytes and a finding 160, cut on a character" do
      long = String.duplicate("ü", 200)
      f = facts(agent(), [op("read_file", "read " <> long, 1, nil)])
      assert byte_size(f["now"]) <= 80 and String.valid?(f["now"]) and f["now"] =~ "…"

      done = agent(%{status: "done", result_head: String.duplicate("word ", 100) <> "."})
      assert byte_size(facts(done, [])["finding"]) <= 160
    end

    test "ids never reach a sentence" do
      id = "3f2a9c1e-1b2c-4d5e-8f90-123456789abc"
      f = facts(agent(), [op("read_file", "read notes/#{id}.md", 1, nil)])
      refute f["now"] =~ id
    end
  end

  describe "lane" do
    test "12 five-second cells anchored at the last event, the dominant kind per cell" do
      ops = [
        op("llm", "thinking", 0, 4),
        op("read_file", "read a", 5, 6),
        op("llm", "thinking", 6, 9.5),
        op("edit_file", "edit b", 10, 14),
        op("run_command", "run: mix test", 15, 30)
      ]

      f = facts(agent(), ops)
      # The last event is at 30 s: the window is [-30 s, 30 s).
      assert f["lane_at"] == t0_ms() + 30_000
      assert length(f["lane"]) == 12

      assert f["lane"] ==
               ~w(idle idle idle idle idle idle think think write tools tools tools)

      assert f["lane_now"] == "idle"
    end

    test "an open op runs to the anchor and is the kind still going on" do
      ops = [op("run_command", "run: mix test", 2, nil), op("read_file", "read a", 0, 1)]
      f = facts(agent(), ops)
      assert f["lane_at"] == t0_ms() + 5_000
      assert List.last(f["lane"]) == "tools"
      assert f["lane_now"] == "tools"
    end

    test "waiting on other agents is idle in the lane; waiting on you is ▒" do
      assert Facts.kind(%{op_type: "spawn_agent", status: "running"}) == :idle
      assert Facts.kind(%{op_type: "run_command", status: "awaiting_approval"}) == :wait_you
      assert Facts.kind(%{op_type: "write_file", status: "done"}) == :write
      assert Facts.kind(%{op_type: "llm", status: "done"}) == :think
    end

    test "ties go to the kind that matters most" do
      ops = [op("llm", "thinking", 0, 2.5), op("edit_file", "edit b", 2.5, 5)]
      assert List.last(Facts.lane(ops, t0_ms() + 5_000, 12, 5_000)) == :write
    end

    test "no ops: no lane" do
      f = facts(agent(), [])
      assert f["lane"] == [] and f["lane_at"] == nil
    end
  end

  describe "run facts" do
    test "the needs-you band is oldest first with the literal request and its agent" do
      agents = %{
        "a1" => %{"id" => "a1", "name" => "web-review"},
        "a2" => %{"id" => "a2", "name" => "data"}
      }

      interactions = [
        %{
          "kind" => "approval",
          "node_id" => "op2",
          "created_at" => 9,
          "approval" => %{
            "tool" => "edit_file",
            "command" => nil,
            "arguments_preview" => ~s({"path":"#{@root}/lib/y.ex"}),
            "reason" => "auto mode asks before edits",
            "agent_id" => nil,
            "requested_at" => 200
          }
        },
        %{
          "kind" => "approval",
          "node_id" => "op1",
          "approval" => %{
            "tool" => "run_command",
            "command" => "mix test test/swarm_code_web --only ui",
            "reason" => "read-only run, so commands ask",
            "agent_id" => "a1",
            "agent_name" => "web-review",
            "requested_at" => 100
          }
        },
        %{
          "kind" => "question",
          "node_id" => "op3",
          "created_at" => 300,
          "question" => %{"prompt" => "Which branch?"}
        }
      ]

      band = Facts.needs_you(interactions, agents, %{"op2" => "a2", "op3" => "a2"}, [@root])

      assert [
               %{
                 "kind" => "approval",
                 "agent_id" => "a1",
                 "agent_name" => "web-review",
                 "text" => "mix test test/swarm_code_web --only ui",
                 "reason" => "read-only run, so commands ask",
                 "requested_at" => 100,
                 "node_id" => "op1"
               },
               %{
                 "kind" => "approval",
                 "agent_id" => "a2",
                 "agent_name" => "data",
                 "text" => "edit lib/y.ex"
               },
               %{
                 "kind" => "question",
                 "agent_id" => "a2",
                 "text" => "Which branch?",
                 "reason" => ""
               }
             ] = band
    end

    test "workflow phases come from the declared list and the current phase" do
      wf = %{phases: ~w(scan plan implement verify report), phase: "implement"}

      agents = [
        %{phase: "scan", status: "done"},
        %{phase: "implement", status: "running"},
        %{phase: "implement", status: "done"}
      ]

      assert [
               %{"name" => "scan", "state" => "done", "agent_count" => 1, "done" => 1},
               %{"name" => "plan", "state" => "done", "agent_count" => 0},
               %{
                 "name" => "implement",
                 "state" => "running",
                 "agent_count" => 2,
                 "live" => 1,
                 "done" => 1
               },
               %{"name" => "verify", "state" => "queued"},
               %{"name" => "report", "state" => "queued"}
             ] = Facts.phases(wf, agents, "running")

      assert [_, _, %{"state" => "waiting"} | _] = Facts.phases(wf, agents, "waiting_user")
      assert Facts.phases(%{phases: [], phase: nil}, agents, "running") == []
    end
  end

  describe "detail findings" do
    alias SwarmCode.Daemon.Service.AgentDetail

    test "numbered items with a leading severity label; bullets are not findings" do
      result = """
      ## Findings

      1. medium lib/ailogic/accounts/user.ex:51 — registration_changeset casts :role. More text.
      2. **High:** the vault falls back to a fixed salt (lib/ailogic/vault.ex:8).
      3. The cache is never warmed on a high traffic path.

      ## Open issues

      - Finding 2 needs a second look.
      """

      assert [
               %{"n" => 1, "severity" => "medium", "ref" => "lib/ailogic/accounts/user.ex:51"} =
                 a,
               %{"n" => 2, "severity" => "high", "ref" => "lib/ailogic/vault.ex:8"} = b,
               %{"n" => 3, "severity" => nil, "ref" => nil}
             ] = AgentDetail.findings(result, [])

      assert a["text"] == "lib/ailogic/accounts/user.ex:51 — registration_changeset casts :role."
      assert b["text"] == "the vault falls back to a fixed salt (lib/ailogic/vault.ex:8)."
    end

    test "a findings table: the number, the severity cell, the last cell and the ref" do
      result = """
      | # | Severity | Location | Finding |
      |---|---|---|---|
      | 1 | critical | lib/web/registration_controller.ex:39 | Public POST /register passes raw params. |
      | 2 | medium | test/tickets_test.exs:352 | The empty-list test never runs empty. |
      """

      assert [
               %{
                 "n" => 1,
                 "severity" => "high",
                 "text" => "Public POST /register passes raw params.",
                 "ref" => "lib/web/registration_controller.ex:39"
               },
               %{"n" => 2, "severity" => "medium", "ref" => "test/tickets_test.exs:352"}
             ] = AgentDetail.findings(result, [])
    end
  end
end
