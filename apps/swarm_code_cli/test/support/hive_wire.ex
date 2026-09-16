defmodule SwarmCodeCLI.TestSupport.HiveWire do
  @moduledoc """
  v1 wire maps carrying every wave 1 addition (tool calls, agent gauges, run
  gauges, changes, verdicts). Shared by the DTO, delta and codec contract tests;
  a test support module because ExUnit purges test modules after they run.
  """

  @run "33333333-3333-4333-8333-333333333333"
  @conversation "22222222-2222-4222-8222-222222222222"
  @agent "44444444-4444-4444-8444-444444444444"

  def run_id, do: @run
  def conversation_id, do: @conversation
  def agent_id, do: @agent

  def tool_call,
    do: %{
      "name" => "grep",
      "title" => "grep \"Repo\\.\"",
      "detail" => "lib/ test/ · 41 hits",
      "status" => "done",
      "started_at" => 1_788_436_730_000,
      "finished_at" => 1_788_436_730_400,
      "duration_ms" => 400,
      "result_bytes" => 3_812,
      "files" => ["lib/swarm_code/repo.ex"]
    }

  def transcript_item,
    do: %{
      "created_sequence" => 4,
      "attachment_refs" => [],
      "detail_ref" => nil,
      "reasoning_detail_ref" => nil,
      "target_kind" => "main",
      "target_id" => nil,
      "id" => "tool-1",
      "run_id" => @run,
      "conversation_id" => @conversation,
      "node_id" => "node-1",
      "revision" => 2,
      "role" => "tool",
      "state" => "done",
      "text" => "lib/swarm_code/repo.ex:12",
      "reasoning" => "",
      "attempt_id" => "attempt-1",
      "allowed_actions" => ["inspect", "copy"],
      "kind" => "tool",
      "tool" => tool_call(),
      "agent_id" => @agent,
      "tokens_in" => 812,
      "tokens_out" => 64,
      "at" => 1_788_436_730_000
    }

  def legacy_agent_keys, do: ~w(id run_id revision state allowed_actions launched_by_superseded)

  def agent_summary,
    do: %{
      "id" => "agent-4",
      "run_id" => @run,
      "revision" => 3,
      "state" => "running",
      "allowed_actions" => ["stop_agent"],
      "launched_by_superseded" => false,
      "name" => "builder-4",
      "role" => "worker",
      "title" => "Harden refresh",
      "step" => "edit lib/swarm_code/repo.ex",
      "progress" => 40,
      "tokens_in" => 5_340,
      "tokens_out" => 1_320,
      "cost_usd" => 0.058,
      "started_at" => 1_788_436_690_000,
      "finished_at" => nil,
      "parent_id" => @agent,
      "depth" => 1,
      "changes_stat" => "+42 −7",
      "error" => nil
    }

  def legacy_run_keys,
    do:
      ~w(created_sequence parent_run_id seen_revision id conversation_id kind title revision state allowed_actions progress)

  def run_summary,
    do: %{
      "created_sequence" => 1,
      "parent_run_id" => nil,
      "seen_revision" => 0,
      "id" => @run,
      "conversation_id" => @conversation,
      "kind" => "swarm",
      "title" => "Review authentication",
      "revision" => 2,
      "state" => "running",
      "allowed_actions" => ["pause", "stop"],
      "progress" => 42,
      "tokens_in" => 18_640,
      "tokens_out" => 4_210,
      "cost_usd" => 0.184,
      "model" => "kimi-k2-thinking",
      "agents_total" => 5,
      "agents_running" => 3,
      "needs" => 1,
      "changes" => 3,
      "started_at" => 1_788_436_680_000,
      "finished_at" => nil,
      "consensus" => true,
      "error" => nil
    }

  def change,
    do: %{
      "id" => "change-1",
      "run_id" => @run,
      "agent_id" => @agent,
      "path" => "lib/swarm_code/repo.ex",
      "restorable" => true,
      "at" => 1_788_436_760_000,
      "revision" => 2
    }

  def verdict,
    do: %{
      "id" => "judge-1",
      "run_id" => @run,
      "round" => 1,
      "status" => "done",
      "checks" => [
        %{"key" => "tests_pass", "ok" => true, "note" => "142 tests, 0 failures"},
        %{"key" => "no_regressions", "ok" => true, "note" => "auth paths unchanged"},
        %{"key" => "docs_updated", "ok" => false, "note" => "architecture.md still draft"},
        %{"key" => "style", "ok" => nil, "note" => "not evaluated"}
      ],
      "summary" => "Two of three proposals meet the bar; the docs change needs another pass.",
      "revision" => 3
    }

  def page,
    do: %{
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => nil,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => [],
      "through_sequence" => 9
    }

  def workspace,
    do:
      Map.merge(page(), %{
        "allowed_actions" => ["send"],
        "revision" => 7,
        "seen_revision" => 0,
        "runs_page" => page(),
        "interactions_page" => page(),
        "conversation_id" => @conversation,
        "mode" => nil,
        "chat_model" => nil,
        "swarm_model" => nil,
        "effort" => nil,
        "swarm_effort" => nil,
        "runs" => [run_summary()],
        "interactions" => [],
        "transcript" => Map.put(page(), "items", [transcript_item()]),
        "changes" => [change()],
        "verdicts" => [verdict()]
      })
end
