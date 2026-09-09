defmodule SwarmCode.Domain.Engine.ConsensusTest do
  @moduledoc "Spec 37 §2: the check catalogue, the prompts and the verdict text."
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.Consensus
  alias SwarmCode.Domain.Workflows.Schema

  defp config(attrs \\ %{}),
    do: Map.merge(%{checks: Consensus.default_keys(), rounds: 2, mode: "build"}, attrs)

  describe "the catalogue" do
    test "a fresh conversation ticks the seven defaults (§2)" do
      assert Consensus.default_keys() ==
               ~w(over_engineering judge_plan minimal codebase scope edge_cases gate)
    end

    test "checks_for/1 falls back to the defaults and filters unknown keys" do
      assert Consensus.checks_for(%{consensus_checks: nil}) == Consensus.default_keys()
      assert Consensus.checks_for(%{}) == Consensus.default_keys()

      # catalogue order, not the order the caller passed
      assert Consensus.checks_for(%{consensus_checks: ["gate", "minimal", "nonsense"]}) ==
               ["minimal", "gate"]
    end

    test "toggle/2 adds, removes and ignores unknown keys" do
      assert Consensus.toggle(["minimal"], "risk") == ["minimal", "risk"]
      assert Consensus.toggle(["minimal", "risk"], "minimal") == ["risk"]
      assert Consensus.toggle(["minimal"], "nonsense") == ["minimal"]
      # added keys land in catalogue order
      assert Consensus.toggle(["gate"], "minimal") == ["minimal", "gate"]
    end
  end

  describe "judge_system/2" do
    test "only the ticked fragments reach the judge (§2)" do
      system = Consensus.judge_system(["minimal"], "plan")

      assert system =~ "You are the judge in a two-model consensus"
      assert system =~ "Prefer the existing architecture"
      refute system =~ "Open every file the plan names"
    end

    test "the changes stage swaps the preamble" do
      system = Consensus.judge_system(Consensus.keys(), "changes")

      assert String.starts_with?(system, "You are the judge in a two-model consensus.")

      assert system =~ "the planner implemented the plan below" or
               system =~ "The planner implemented the plan below"

      assert system =~ "Call git_diff first"
      refute system =~ "you decide whether it is ready"
    end

    test "a check with no judge fragment adds nothing" do
      assert Consensus.judge_system(["gate", "judge_plan"], "plan") ==
               Consensus.judge_system([], "plan")
    end
  end

  describe "judge_user/4" do
    test "carries the request, the plan and the previous disposition" do
      text = Consensus.judge_user("fix the lexer", "1. touch lexer.ex", "accepted #1", "plan")

      assert text =~ "USER REQUEST:\nfix the lexer"
      assert text =~ "THE PLAN:\n1. touch lexer.ex"
      assert text =~ "THE PLANNER'S DISPOSITION OF YOUR PREVIOUS FINDINGS:\naccepted #1"

      # Spec 51 §5.6: from round 2 on the judge reads its own previous
      # findings, last — and the parser cuts them off before the split, so
      # the plan and the disposition read exactly as without them.
      previous = %{
        "round" => 1,
        "verdict" => "revise",
        "findings" => [
          %{
            "severity" => "high",
            "concern" => "rewrites the parser",
            "requested_change" => "less"
          }
        ]
      }

      with_previous =
        Consensus.judge_user(
          "fix the lexer",
          "1. touch lexer.ex",
          "accepted #1",
          "plan",
          previous
        )

      assert with_previous =~
               "YOUR PREVIOUS FINDINGS (round 1):\n1. [high] rewrites the parser Requested change: less"

      assert String.ends_with?(with_previous, "Requested change: less")

      assert Consensus.parse_judge_prompt(with_previous) == Consensus.parse_judge_prompt(text)
      assert Consensus.parse_judge_prompt(with_previous).disposition == "accepted #1"

      assert Consensus.finding_lines(previous["findings"]) == [
               "1. [high] rewrites the parser Requested change: less"
             ]
    end

    test "round one has no disposition and changes renames the plan block" do
      text = Consensus.judge_user("fix it", "I edited lexer.ex", nil, "changes")

      assert text =~ "WHAT THE PLANNER CHANGED:"
      refute text =~ "DISPOSITION"
    end
  end

  describe "planner_block/1" do
    test "plan mode never implements" do
      block = Consensus.planner_block(config(%{mode: "plan"}))

      assert block =~ "CONSENSUS MODE"
      assert block =~ "Do not implement anything."
      assert block =~ "call submit_plan"
    end

    test "build mode implements the approved plan" do
      block = Consensus.planner_block(config(%{mode: "build"}))

      assert block =~ "implement the plan"
      refute block =~ "Do not implement anything."
    end

    test "judging the changes adds the last step" do
      block =
        Consensus.planner_block(config(%{checks: ["judge_plan", "judge_changes"], mode: "build"}))

      assert block =~ ~s(4. After implementing, call submit_plan with stage "changes")
    end

    test "without judge_plan the planner just works" do
      block = Consensus.planner_block(config(%{checks: ["minimal"], mode: "build"}))

      assert block =~ "1. Do the work as usual; there is no plan review."
      refute block =~ "Before changing anything"
      assert block =~ "Keep the change minimal"
    end
  end

  describe "format_verdict/6" do
    defp verdict(attrs \\ %{}) do
      Map.merge(
        %{
          "verdict" => "revise",
          "summary" => "too broad",
          "findings" => [
            %{
              "severity" => "high",
              "concern" => "rewrites the parser",
              "rationale" => "the bug is in the lexer",
              "requested_change" => "touch only lexer.ex",
              "preserve" => "the new test"
            }
          ]
        },
        attrs
      )
    end

    test "a judge that never answered says so" do
      text = Consensus.format_verdict(nil, "plan", 1, 2, config(), nil)

      assert text =~ "the judge did not answer"
      assert text =~ "round 1 of 2"
    end

    test "every finding is numbered with its severity" do
      text = Consensus.format_verdict(verdict(), "plan", 1, 2, config(), nil)

      assert text =~ "CONSENSUS VERDICT (plan, round 1 of 2): REVISE"
      assert text =~ "1. [high] rewrites the parser — the bug is in the lexer"
      assert text =~ "Requested change: touch only lexer.ex"
      assert text =~ "Preserve: the new test"
      assert text =~ "call submit_plan again"
      refute text =~ "last round"
    end

    test "the last round tells the planner to proceed" do
      text = Consensus.format_verdict(verdict(), "plan", 2, 2, config(), nil)

      assert text =~ "This was the last round."
      refute text =~ "call submit_plan again"
    end

    test "an approved plan in plan mode is the answer" do
      text =
        Consensus.format_verdict(
          verdict(%{"verdict" => "approve", "findings" => []}),
          "plan",
          1,
          2,
          config(%{mode: "plan"}),
          nil
        )

      assert text =~ "APPROVED"
      assert text =~ "Do not implement."
    end

    test "an approved plan in build mode is implemented" do
      text =
        Consensus.format_verdict(
          verdict(%{"verdict" => "approve", "findings" => []}),
          "plan",
          1,
          2,
          config(),
          nil
        )

      assert text =~ "Next: implement the plan now."
    end

    test "the user's gate answer wins over everything else" do
      text =
        Consensus.format_verdict(
          verdict(%{"verdict" => "approve", "findings" => []}),
          "plan",
          1,
          2,
          config(),
          "Plan only"
        )

      assert String.ends_with?(text, "USER: Plan only")
      refute text =~ "Next: implement"
    end

    test "the simpler alternative is quoted when there is one" do
      text =
        Consensus.format_verdict(
          verdict(%{"simpler_alternative" => "one regex change"}),
          "plan",
          1,
          2,
          config(),
          nil
        )

      assert text =~ "Simpler alternative: one regex change"
    end
  end

  describe "verdict_schema/0" do
    test "accepts a well-formed verdict and rejects an unknown one" do
      schema = Consensus.verdict_schema()

      assert :ok =
               Schema.validate(schema, %{
                 "verdict" => "approve",
                 "summary" => "fine",
                 "findings" => []
               })

      assert {:error, _} =
               Schema.validate(schema, %{
                 "verdict" => "maybe",
                 "summary" => "fine",
                 "findings" => []
               })

      assert {:error, _} = Schema.validate(schema, %{"verdict" => "approve", "summary" => "fine"})
    end
  end
end
