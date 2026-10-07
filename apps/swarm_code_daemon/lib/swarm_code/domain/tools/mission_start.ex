defmodule SwarmCode.Domain.Tools.MissionStart do
  @moduledoc """
  Spec 75 (pass 71): the Ultra orchestrator's one mission tool. Validates the
  plan and launches the builtin `mission` workflow, which waits for the user's
  approval before any worker starts.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.{Git, Missions, Settings, Workflows}
  alias SwarmCode.Domain.Missions.Plan
  alias SwarmCode.Domain.Tools.WorkflowTools

  # Spec 75 §11.2: a bounded probe — `HEAD` must resolve before workers can be
  # isolated (an isolated tree starts at HEAD).
  @head_timeout_ms 10_000

  @impl true
  def name, do: "mission_start"

  @impl true
  def description,
    do:
      "Start a mission for multi-feature work: give the validation contract (VAL-AREA-NNN " <>
        "assertions, written before the features), the milestones with their features (each " <>
        "claims assertions), the guidelines and what you learned. The user approves the plan " <>
        "and picks the worker and validator models; then workers build each milestone's " <>
        "features in parallel and validators check them. Returns at once — you are re-invoked " <>
        "with the mission's report."

  @impl true
  def parameters, do: Plan.parameters()

  # Spec 75 critic: `:write`, not `:execute` — in the default "auto" approval
  # mode `:execute` is always asked (policy.ex:37), which would put a tool
  # approval in front of the plan's own approval card. The card is the gate.
  @impl true
  def permission(_args), do: :write

  # One mission per conversation is a check-then-insert (`Missions.active_run/1`
  # then `Workflows.launch/1`): two calls in one assistant batch would both pass
  # the check, so the batch runs them one after the other.
  @impl true
  def parallel?, do: false

  @impl true
  def title(args), do: "mission_start " <> String.slice(to_string(args["title"] || ""), 0, 60)

  @impl true
  def run(args, ctx, _progress) do
    conversation = WorkflowTools.conversation(ctx)

    cond do
      WorkflowTools.in_workflow?(ctx) ->
        {:error, "a mission cannot start inside a workflow"}

      is_nil(conversation) ->
        {:error, "no conversation to start the mission in"}

      active = Missions.active_run(conversation.id) ->
        {:error,
         "#{active.display_name} is still #{active.status} — finish or stop it before " <>
           "starting another mission"}

      true ->
        case Plan.validate(args) do
          {:ok, plan} ->
            launch(plan, ctx, conversation)

          {:error, problems} ->
            {:error, "the plan does not check out: " <> Enum.join(problems, "; ")}
        end
    end
  end

  defp launch(plan, ctx, conversation) do
    project = WorkflowTools.project(ctx)
    isolate = isolate?(project)
    parallel = if isolate, do: Missions.max_parallel(), else: 1
    rounds = Missions.default_fix_rounds()

    case Enum.find(Workflows.builtins(), &(&1.name == Missions.definition_name())) do
      nil ->
        {:error, "the builtin mission workflow is missing"}

      definition ->
        attrs = %{
          conversation: conversation,
          project: project,
          definition: definition,
          args: %{
            "title" => plan["title"],
            "plan" => plan,
            "parallel" => parallel,
            "isolate" => isolate,
            "max_fix_rounds" => rounds
          },
          budget: Missions.budget(plan, rounds),
          max_live: parallel,
          created_by: "model",
          auto_continue: true
        }

        case Workflows.launch(attrs) do
          {:ok, wf} ->
            {:ok, started_text(wf, plan, isolate)}

          {:error, {:bad_args, problems}} ->
            {:error, Enum.join(problems, "; ")}

          {:error, {:invalid, problems}} ->
            {:error, "the mission workflow does not check out: " <> Enum.join(problems, "; ")}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  # Isolated, parallel workers need worktrees switched on, a git repository and
  # at least one commit (spec 75 §10 #6, §11.2); anything else runs the
  # features one at a time in the project tree.
  defp isolate?(project) do
    root = project && project.root_path

    Settings.get().worktrees_enabled == true and Git.repo?(root) and has_commit?(root)
  end

  defp has_commit?(root),
    do:
      match?(
        {:ok, _},
        Git.run(root, ["rev-parse", "--verify", "HEAD"], timeout: @head_timeout_ms)
      )

  defp started_text(wf, plan, isolate) do
    features = Enum.reduce(plan["milestones"], 0, &(&2 + length(&1["features"])))

    "Started #{wf.display_name}: #{length(plan["milestones"])} milestones, #{features} " <>
      "features, #{length(plan["contract"])} assertions. It is waiting for the user's " <>
      "approval in the approval card — say in one or two sentences what the mission will do " <>
      "and that it waits for their approval. " <>
      if(isolate,
        do: "Features run in parallel, each in its own worktree.",
        else:
          "Worktrees are off, this is not a git repository or it has no commit yet, so " <>
            "features run one at a time in the project tree."
      ) <> " You will be re-invoked with the report."
  end
end
