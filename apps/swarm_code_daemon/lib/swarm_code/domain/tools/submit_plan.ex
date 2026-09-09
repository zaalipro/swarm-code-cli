defmodule SwarmCode.Domain.Tools.SubmitPlan do
  @moduledoc """
  Consensus mode (spec 37 §3): hands the planner's plan (or, after
  implementing, a summary of the changes) to the judge — a worker agent on the
  judge model — and returns its verdict as the tool result. Blocks like
  `spawn_agent` does, on `RunServer.await_agent/2`.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.{Consensus, RunServer}
  alias SwarmCode.Domain.Tools.AskUser

  # Spec 51 §5.5: the judge reads in one batch, two passes at most — twelve
  # turns re-sent the whole history twelve times (756 k input tokens for three
  # judges in prod).
  @judge_max_turns 6

  @impl true
  def name, do: "submit_plan"

  @impl true
  def description,
    do:
      "Consensus mode: submit your plan to the judge (a second model) and get its verdict. " <>
        "Call it with stage \"plan\" before changing anything, and again with the revised " <>
        "plan after a REVISE verdict. With stage \"changes\", call it after implementing " <>
        "so the judge reviews the diff."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "plan" => %{
          "type" => "string",
          "description" =>
            "the complete plan (summary, numbered steps with file paths, Reviewer Handoff) — " <>
              "or, with stage \"changes\", a short summary of what you changed"
        },
        "disposition" => %{
          "type" => "string",
          "description" =>
            "from the second round on: each previous finding marked accepted, modified or " <>
              "rejected, with a short reason"
        },
        "stage" => %{
          "type" => "string",
          "enum" => ["plan", "changes"],
          "description" => "\"plan\" (default) or \"changes\""
        }
      },
      "required" => ["plan"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args) do
    if args["stage"] == "changes", do: "changes for the judge", else: "plan for the judge"
  end

  @impl true
  def run(args, ctx, progress) do
    stage = if args["stage"] == "changes", do: "changes", else: "plan"
    plan = String.trim(to_string(args["plan"] || ""))

    cond do
      plan == "" ->
        {:error, "plan must not be empty"}

      true ->
        case RunServer.consensus_round(ctx.run_id, stage) do
          {nil, _round, _previous} ->
            {:error, "consensus mode is off for this run"}

          {config, round, previous} ->
            judge(config, round, stage, plan, args["disposition"], previous, ctx, progress)
        end
    end
  end

  # Spec 37 §3: past the last round no judge is started — the planner is told
  # the rounds are used up and goes on with its best plan.
  defp judge(%{rounds: rounds} = config, round, stage, _plan, _disp, _prev, ctx, progress)
       when round > rounds do
    progress.(100, "rounds used up")
    # Spec 51 §5.4: past the last round the gate still asks before anything
    # is implemented.
    user = gate(:exhausted, stage, config, ctx, progress, round, rounds)
    {:ok, Consensus.format_exhausted(stage, round, rounds, config, user)}
  end

  defp judge(config, round, stage, plan, disposition, previous, ctx, progress) do
    rounds = config.rounds
    progress.(nil, "judging · round #{round} of #{rounds}")

    capability =
      if stage == "changes" or "codebase" in config.checks, do: :read_only, else: :none

    opts = [
      capability: capability,
      schema: Consensus.verdict_schema(),
      system_extra: Consensus.judge_system(config.checks, stage),
      max_turns: @judge_max_turns
    ]

    opts = if config.judge, do: Keyword.put(opts, :model_map, config.judge), else: opts
    opts = if config.judge_effort, do: Keyword.put(opts, :effort, config.judge_effort), else: opts

    {:ok, node_id} =
      RunServer.start_agent(ctx.run_id, %{
        parent_id: ctx.node_id,
        role: "worker",
        name: "Judge · round #{round}",
        # Spec 51 §5.6: the previous round's findings ride along, last.
        prompt: Consensus.judge_user(config.request, plan, disposition, stage, previous),
        opts: opts
      })

    verdict =
      case RunServer.await_agent(ctx.run_id, node_id) do
        {:ok, text} -> Consensus.decode_verdict(text)
        {:error, _reason} -> nil
      end

    if verdict, do: RunServer.consensus_verdict(ctx.run_id, stage, verdict)

    # Spec 51 §5.8: the round's outcome is stored when it is produced.
    RunServer.consensus_round_done(ctx.run_id, %{
      "index" => round,
      # spec 60 T8: the entry is matched back to its op by id, not by the per-stage index.
      "op_id" => ctx.node_id,
      "stage" => stage,
      "verdict" => verdict,
      "plan_head" => String.slice(plan, 0, 2_000),
      "disposition_head" => String.slice(disposition || "", 0, 1_000)
    })

    user = gate(verdict, stage, config, ctx, progress, round, rounds)
    progress.(100, outcome(verdict))
    {:ok, Consensus.format_verdict(verdict, stage, round, rounds, config, user)}
  end

  # Spec 37 §3.2: after an approved plan in build mode the run waits for the
  # user when "gate" is ticked. The answer travels back inside the tool result.
  # Spec 51 §5.4: on every outcome — an approval, a judge that did not answer,
  # a REVISE on the last round, the rounds used up — the gate asks; a lost
  # question (a stop) means "Plan only", never nothing.
  defp gate(verdict, "plan", %{mode: "build"} = config, ctx, progress, round, rounds) do
    if "gate" in config.checks do
      case gate_question(verdict, round, rounds) do
        nil -> nil
        question -> ask(question, ctx, progress)
      end
    end
  end

  defp gate(_verdict, _stage, _config, _ctx, _progress, _round, _rounds), do: nil

  defp gate_question(%{"verdict" => "approve"}, _round, _rounds),
    do: "The judge approved the plan. Implement it?"

  defp gate_question(nil, _round, _rounds),
    do: "The judge did not answer (no verdict). Implement anyway?"

  defp gate_question(:exhausted, _round, _rounds),
    do: "The rounds are used up and the judge was not consulted. Implement anyway?"

  defp gate_question(%{"verdict" => "revise"}, round, rounds) when round >= rounds,
    do: "The judge asked for changes on the last round. Implement anyway?"

  defp gate_question(_verdict, _round, _rounds), do: nil

  defp ask(question, ctx, progress) do
    progress.(nil, "waiting for your go")

    questions = [
      %{
        "question" => question,
        "header" => "Consensus",
        "options" => [
          %{"label" => "Implement", "description" => "Go ahead with the plan"},
          %{"label" => "Plan only", "description" => "Stop here and show me the plan"},
          %{"label" => "Revise", "description" => "I will say what to change"}
        ]
      }
    ]

    # Spec 51 §5.4: no clock — the user's answer or their Stop is the way out.
    case RunServer.ask_user(ctx.run_id, ctx.node_id, questions, timeout: :infinity) do
      # `AskUser.format/2` renders "Answers:\n1. <question> → <answer>"; the
      # planner only needs the answer.
      {:ok, answers} ->
        questions
        |> AskUser.format(answers)
        |> String.split(" → ", parts: 2)
        |> List.last()
        |> String.trim()

      {:error, reason} ->
        "Plan only (#{reason})"
    end
  end

  defp outcome(nil), do: "no verdict"
  defp outcome(%{"verdict" => "approve"}), do: "approved"
  defp outcome(%{"findings" => f}) when is_list(f), do: "revise · #{length(f)} findings"
  defp outcome(_), do: "revise"
end
