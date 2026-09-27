defmodule SwarmCode.Daemon.Service.C75PanelFactsTest do
  @moduledoc """
  pass75: the daemon's panel rules for turns, a turn-limit stop (a stop, not a
  report: a rule sentence, no finding, its last words) and the headline, which
  skips narration and falls back to the report's conclusion.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.PanelFacts, as: Facts

  @t0 ~U[2026-09-24 10:00:00.000000Z]
  @root "/Users/me/dev/app"
  @worktree "/Users/me/dev/app/.swarm_code/worktrees/2404157a/engine-review-bd868c6f"

  defp at(s), do: DateTime.add(@t0, round(s * 1000), :millisecond)

  defp agent(attrs),
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

  describe "a turn-limit stop" do
    test "a turn-limit node: now, no finding, last_words, not reported" do
      n =
        agent(%{
          status: "done",
          error_kind: "turn_budget",
          turn: 30,
          max_turns: 30,
          finished_at: at(90),
          result_head:
            "Deps are all ok; two \"build is outdated\" findings remain.\n\n_(Stopped after 30 turns; partial result above.)_"
        })

      facts = facts(n, [op("read_file", "read mix.exs", 10, 12)])

      assert facts["now"] == "no answer after 30 turns"
      assert facts["finding"] == nil
      assert facts["finding_refs"] == []
      assert Facts.turn_limit?(n)
      refute Facts.reported?(n)
      assert Facts.last_words(n) == "Deps are all ok; two \"build is outdated\" findings remain."
    end

    test "without a budget the rule sentence still says why" do
      n = agent(%{status: "done", error_kind: "turn_budget", max_turns: nil})
      assert Facts.turn_limit_now(n) == "no answer: turn limit"
      assert facts(n, [])["now"] == "no answer: turn limit"
    end

    test "only the engine's notice is no last words" do
      n =
        agent(%{
          status: "done",
          error_kind: "turn_budget",
          max_turns: 30,
          result_head: "_(Stopped after 30 turns; partial result above.)_"
        })

      assert Facts.last_words(n) == nil
    end

    test "a done node with a result is reported" do
      assert Facts.reported?(agent(%{status: "done", error_kind: "done"}))
      assert Facts.reported?(agent(%{status: "done"}))
      refute Facts.reported?(agent(%{status: "stopped"}))
      refute Facts.turn_limit?(agent(%{status: "failed", error_kind: "turn_budget"}))
    end
  end

  describe "the headline" do
    test "a conclusion with its refs is the finding" do
      result =
        "Deleting ailogic_typescript/ is safe: nothing in lib/ or assets/ imports it.\n\nRefs: mix.exs:12, README.md:21"

      assert Facts.finding(result, nil, []) ==
               "Deleting ailogic_typescript/ is safe: nothing in lib/ or assets/ imports it."

      assert Facts.finding_refs(result) == ["mix.exs:12", "README.md:21"]
    end

    test "an opener that narrates gives way to the conclusion below it" do
      result =
        "I'll start by inspecting lib/ for TypeScript imports.\n\nConclusion: nothing imports it; deleting the directory is safe."

      assert Facts.finding(result, nil, []) ==
               "Conclusion: nothing imports it; deleting the directory is safe."
    end

    test "narration is found after markdown marks and with a curly apostrophe" do
      assert Facts.narration?("**I'll check it")
      assert Facts.narration?("I’ll check it")
      assert Facts.narration?("> Let me look at the router")
      refute Facts.narration?("The router drops the header.")
    end

    test "all narration and no tail is no finding" do
      head = "I'll start by inspecting lib/.\n\nLet me check the imports next."
      assert Facts.finding(head, nil, []) == nil
    end

    test "all narration, and the tail has the conclusion" do
      head = "I'll start by inspecting lib/.\n\nLet me check the imports next."
      tail = "…more narration. The directory is unused and safe to delete."

      assert Facts.finding(head, tail, []) == "The directory is unused and safe to delete."
    end

    test "a done agent's row reads the tail's conclusion when its head narrates" do
      n =
        agent(%{
          status: "done",
          finished_at: at(40),
          result_head: "I'll start by inspecting lib/ for TypeScript imports.",
          result_tail: "…more narration. The directory is unused and safe to delete."
        })

      assert facts(n, [])["finding"] == "The directory is unused and safe to delete."
    end
  end
end
