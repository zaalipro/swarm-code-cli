defmodule SwarmCode.Domain.Conversations.Conversation do
  @moduledoc """
  A conversation inside a project.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field(:title, :string, default: "New conversation")
    field(:goal, :string)
    field(:mode, :string, default: "build")
    field(:chat_provider_id, :binary_id)
    field(:chat_model, :string)
    field(:swarm_provider_id, :binary_id)
    field(:swarm_model, :string)
    field(:queued, {:array, :string}, default: [])
    field(:effort, :string)
    field(:swarm_effort, :string)
    # The last time the user looked at this conversation — the unread dot in
    # the sidebar compares it with the newest activity (spec 08 §9).
    field(:last_seen_at, :utc_datetime_usec)
    field(:scheduled_task_id, :binary_id)
    # Spec 21 §4: null means unpinned; when set it is also the sort key of the
    # sidebar's Pinned section.
    field(:pinned_at, :utc_datetime_usec)
    field(:ultra, :boolean, default: false)
    field(:authoring_workflow, :boolean, default: false)
    # Spec 37 §1: consensus mode — a second model judges the plan.
    field(:consensus, :boolean, default: false)
    field(:consensus_checks, {:array, :string})
    field(:consensus_rounds, :integer, default: 2)
    field(:judge_provider_id, :binary_id)
    field(:judge_model, :string)
    field(:judge_effort, :string)
    # Spec 45 §4.1: the implementer — nil means the planner implements.
    field(:implementer_provider_id, :binary_id)
    field(:implementer_model, :string)
    field(:implementer_effort, :string)
    # Spec 24 §7.3: set on the hidden conversation a deep research owns. Every
    # sidebar list filters these out; the Usage page deliberately does not.
    field(:research_id, :integer)

    # spec 67 T9 (B34): raised by `AgentServer.maybe_auto_compact/2` when the
    # running turn crosses the compaction threshold, honoured (and cleared) by
    # the next `Engine.start_chat_turn/4` *before* it reserves its rows.
    field(:compact_due, :boolean, default: false)

    belongs_to(:project, SwarmCode.Domain.Projects.Project)
    has_many(:messages, SwarmCode.Domain.Conversations.Message)
    has_many(:runs, SwarmCode.Domain.Conversations.Run)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :project_id,
      :title,
      :goal,
      :mode,
      :chat_provider_id,
      :chat_model,
      :swarm_provider_id,
      :swarm_model,
      :queued,
      :effort,
      :swarm_effort,
      :last_seen_at,
      :scheduled_task_id,
      :pinned_at,
      :ultra,
      :authoring_workflow,
      :research_id,
      :consensus,
      :consensus_checks,
      :consensus_rounds,
      :judge_provider_id,
      :judge_model,
      :judge_effort,
      :implementer_provider_id,
      :implementer_model,
      :implementer_effort,
      :compact_due
    ])
    |> validate_required([:project_id])
    |> validate_length(:title, max: 120)
    |> validate_inclusion(:mode, ["build", "plan"])
    # Spec 45 §3.3: an effort is any well-formed level key — the provider's
    # list decides what it means, and unknown keys are normalised at read time.
    |> validate_format(:effort, SwarmCode.Domain.LLM.Efforts.key_format())
    |> validate_format(:swarm_effort, SwarmCode.Domain.LLM.Efforts.key_format())
    |> validate_format(:judge_effort, SwarmCode.Domain.LLM.Efforts.key_format())
    |> validate_format(:implementer_effort, SwarmCode.Domain.LLM.Efforts.key_format())
    |> validate_inclusion(:consensus_rounds, [1, 2, 3])
  end
end
