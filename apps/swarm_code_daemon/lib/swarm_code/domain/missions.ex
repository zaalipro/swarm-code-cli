defmodule SwarmCode.Domain.Missions do
  @moduledoc """
  Spec 75 (pass 71): Ultra missions — the constants the builtin `mission`
  workflow, the `mission_start` tool and the UI share, the budget rule and two
  narrow reads (the plan outline of one run, the conversation's live mission).
  """

  import Ecto.Query, warn: false

  alias SwarmCode.Domain.Conversations.Run, as: RunRow
  alias SwarmCode.Domain.Missions.Outline
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Workflows.Run

  @live_statuses ~w(running waiting_user paused interrupted)

  def definition_name, do: "mission"
  def approval_question, do: "Approve the mission plan?"
  def approve_answer, do: "Approve"
  def cancel_answer, do: "Cancel"
  def max_parallel, do: 4
  def default_fix_rounds, do: 2
  def extra_fix_rounds, do: 2
  def max_fix_features, do: 4

  @doc """
  The agent budget of a plan: every feature twice (a conflict redo), and per
  milestone two validators plus, per possible fix round, up to two fix planners
  (a blocked plan is asked again with the user's answer), two validators and up
  to `max_fix_features/0` fixes with a redo each. Capped at the workflow row's
  limit (1024, `Workflows.Run` changeset).
  """
  @spec budget(map(), non_neg_integer()) :: pos_integer()
  def budget(plan, fix_rounds) do
    milestones = plan["milestones"] || []
    features = Enum.reduce(milestones, 0, &(&2 + length(&1["features"] || [])))
    rounds = fix_rounds + extra_fix_rounds()
    per_round = 4 + 2 * max_fix_features()

    min(2 * features + length(milestones) * (2 + rounds * per_round), 1024)
  end

  @doc "The plan outline of one mission run — one primary-key read of `args`."
  @spec outline(String.t()) :: Outline.t() | nil
  def outline(run_id) when is_binary(run_id) do
    Repo.one(from(w in Run, where: w.run_id == ^run_id, select: w.args))
    |> Outline.from_args()
  end

  def outline(_run_id), do: nil

  @doc """
  The outlines of several mission runs in one query (spec 75 critic: the
  workspace loads every missing outline of a conversation at once, never one
  select per run). Ids without a row map to nil.
  """
  @spec outlines([String.t()]) :: %{String.t() => Outline.t() | nil}
  def outlines([]), do: %{}

  def outlines(run_ids) when is_list(run_ids) do
    found =
      Repo.all(from(w in Run, where: w.run_id in ^run_ids, select: {w.run_id, w.args}))
      |> Map.new(fn {id, args} -> {id, Outline.from_args(args)} end)

    Map.new(run_ids, &{&1, Map.get(found, &1)})
  end

  @doc "Whether a workflow row (or wire map) is the builtin mission — never a user workflow named so."
  @spec builtin_mission?(map() | nil) :: boolean()
  def builtin_mission?(%{definition_name: "mission", scope: "builtin"}), do: true
  def builtin_mission?(_wf), do: false

  @doc "The conversation's mission that has not finished, or nil."
  @spec active_run(String.t()) :: map() | nil
  def active_run(conversation_id) when is_binary(conversation_id) do
    Repo.one(
      from(w in Run,
        join: r in RunRow,
        on: r.id == w.run_id,
        where:
          w.conversation_id == ^conversation_id and w.definition_name == "mission" and
            w.scope == "builtin" and r.status in @live_statuses,
        order_by: [desc: r.inserted_at],
        limit: 1,
        select: %{run_id: w.run_id, display_name: w.display_name, status: r.status}
      )
    )
  end

  def active_run(_conversation_id), do: nil

  @doc "Whether `wf` (a workflow row) waits at the mission's approval gate; `run` is its runs row."
  @spec approval_gate?(map() | nil, map() | nil) :: boolean()
  def approval_gate?(
        %{definition_name: "mission", scope: "builtin", gate_question: q},
        %{status: "waiting_user"}
      ),
      do: q == approval_question()

  def approval_gate?(_wf, _run), do: false
end
