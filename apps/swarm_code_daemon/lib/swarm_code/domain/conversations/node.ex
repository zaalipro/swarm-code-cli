defmodule SwarmCode.Domain.Conversations.Node do
  @moduledoc """
  One node of a run tree: an agent or an operation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `retrying` is a transport retry in flight (spec 11 §7.3): still live, still
  # billed to the same turn, but shown in the warn colour. It has to be a legal
  # status or every retry ends as `db write failed` and the node row keeps the
  # stale one.
  # Spec 45 §5.2: `paused` — the agent holds before its next think step.
  @statuses ~w(queued running retrying awaiting_approval awaiting_answer paused done failed stopped)

  schema "nodes" do
    field(:parent_id, :binary_id)
    field(:kind, :string)
    field(:op_type, :string)
    field(:name, :string)
    field(:role, :string)
    field(:title, :string, default: "")
    field(:status, :string, default: "running")
    field(:progress, :integer)
    field(:detail, :string)
    field(:result, :string)
    field(:error, :string)
    # spec 67 T30 (G42): why it failed, as an atom-shaped string —
    # `SwarmCode.Domain.LLM.Error.kinds/0`. nil on every row written before pass 63.
    field(:error_kind, :string)
    field(:tokens_in, :integer, default: 0)
    field(:tokens_out, :integer, default: 0)
    # Spec 53b §5: the two parts of `tokens_in` that were not billed at the
    # input rate — a cached prefix read back, and the write that put it there.
    field(:cache_read, :integer, default: 0)
    field(:cache_write, :integer, default: 0)
    field(:cost_usd, :float)
    field(:depth, :integer, default: 0)
    field(:turn, :integer)
    field(:max_turns, :integer)
    field(:position, :integer, default: 0)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:workspace_path, :string)
    field(:branch, :string)
    field(:base_sha, :string)
    field(:changes_stat, :string)
    field(:integrated, :boolean, default: false)
    field(:phase, :string)
    field(:group, :string)
    # Spec 22 §5.1: the prompt this agent is working on — the run's prompt for an
    # assistant or a Lead, the task for a spawned sub-agent or workflow worker.
    field(:prompt, :string)
    # Spec 45 §8.3: the tool arguments of an op as JSON, windowed to 8 KB by
    # `Operation.start/3`; nil for `llm` ops and for rows older than pass 39.
    field(:input, :string)
    field(:pid, :any, virtual: true)
    # spec 72 F5 (R10): the model the agent is on, set by RunServer at start and
    # on a prewalk switch, for the agent card and inspector chips. Virtual: the
    # pass added no column, and `struct/2` silently dropped the key before —
    # the chip never rendered. Lives as long as the run does.
    field(:model, :string, virtual: true)
    # spec 66 T5: the command family the approval card's fourth pill would
    # remember, set by `RunServer` while the node waits. Virtual: it is derived
    # from `input`, it only exists for the seconds the card is on screen, and a
    # reload simply falls back to the three pills.
    field(:approval_prefix, :string, virtual: true)

    belongs_to(:run, SwarmCode.Domain.Conversations.Run)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields ~w(id run_id parent_id kind op_type name role title status progress detail result
             error error_kind tokens_in tokens_out cache_read cache_write cost_usd depth turn max_turns
             position started_at finished_at workspace_path branch base_sha changes_stat
             integrated phase group prompt input)a

  def changeset(node, attrs) do
    node
    |> cast(attrs, @fields)
    # Sakana task 7: `String.slice/3` on the raw change raised whenever an
    # approval or answer cleared a waiting detail with `detail: nil`, so the
    # transition was logged as `db write failed` and the node kept its stale
    # status. nil is a legal clear and passes through untouched.
    |> update_change(:detail, &truncate(&1, 500))
    |> update_change(:result, &truncate(&1, 20_000))
    |> update_change(:prompt, &truncate(&1, 20_000))
    |> update_change(:input, &truncate(&1, 8_192))
    |> validate_required([:run_id, :kind])
    |> validate_inclusion(:kind, ["agent", "op", "workflow", "research"])
    |> validate_inclusion(:status, @statuses)
  end

  defp truncate(nil, _limit), do: nil
  defp truncate(text, limit) when is_binary(text), do: String.slice(text, 0, limit)
  defp truncate(other, _limit), do: other

  def statuses, do: @statuses

  def finished?(%__MODULE__{status: s}), do: s in ["done", "failed", "stopped"]

  @light_chars 4_000
  # Ops whose result the transcript or the consensus card renders whole (spec 51 §1.10).
  # `Conversations.list_nodes_for_runs/2`'s `:light` SQL mirrors this list literally.
  @whole_ops ~w(llm submit_plan write_spec)

  @doc "The op types whose `result` stays whole in a light node (spec 51 §1.10)."
  @spec whole_ops() :: [String.t()]
  def whole_ops, do: @whole_ops

  @doc "The node as the UI keeps it: a tool op's result cut to #{@light_chars} chars, its input dropped."
  @spec light(t()) :: t()
  def light(%__MODULE__{kind: "op", op_type: type} = node) when type not in @whole_ops do
    result =
      case node.result do
        r when is_binary(r) and byte_size(r) > @light_chars ->
          r |> String.slice(0, @light_chars) |> :binary.copy()

        r ->
          r
      end

    %{node | result: result, input: nil}
  end

  def light(node), do: node

  # ------------------------------------------------------------------ patches

  # Spec 54 §2.1 (54a B1): the columns a streaming tick may travel in. A flush
  # whose only changes are these ships `{:nodes_patch, run_id, [{id, cols}]}`
  # — a few hundred bytes — instead of the whole 30-field struct (measured at
  # 345 KB/s per open window in the fast eight-lane scenario, 92 KB bursts).
  # Everything else — a register, a `result`, an `error`, a `branch`, a
  # `finished_at` — forces the full `{:nodes_upsert, …}`, so a subscriber that
  # holds no copy of the node still learns the whole row. `cache_read`/
  # `cache_write` ride with the token counters (spec 53b §5) — an agent's
  # token tick carries all four, and without them here it would be an upsert.
  @patch_cols ~w(status progress detail tokens_in tokens_out cache_read cache_write cost_usd turn)a

  @doc "The columns a `{:nodes_patch, …}` tick may carry (spec 54 §2.1)."
  @spec patch_cols() :: [atom()]
  def patch_cols, do: @patch_cols

  @doc """
  Whether the columns changed since the last flush can travel as a patch.

  `status` qualifies only while the node is still `running`: a finish (or a
  pause, an approval wait, a retry) is what the cards, the timeline and the
  ops counters key off, and it arrives together with `result`/`finished_at`
  on the full struct.
  """
  @spec patchable?(Enumerable.t(), t()) :: boolean()
  def patchable?(cols, %__MODULE__{status: status}) do
    Enum.all?(cols, fn
      :status -> status == "running"
      col -> col in @patch_cols
    end)
  end

  @doc "The changed columns of a light node as a map (spec 54 §2.1)."
  @spec patch(t(), Enumerable.t()) :: map()
  def patch(%__MODULE__{} = node, cols), do: Map.new(cols, &{&1, Map.fetch!(node, &1)})

  @doc "Apply a `patch/2` map to the light node a subscriber already holds."
  @spec apply_patch(t() | map(), map()) :: t() | map()
  def apply_patch(%__MODULE__{} = node, patch), do: struct(node, patch)

  # Spec 54 §2.2: a page that holds a *projection* rather than the struct
  # (`ResearchLive` selects `map(n, ^@node_columns)`) patches through the same
  # function — only the columns it already holds, so a patch can never widen a
  # projection into something its renderers do not expect.
  def apply_patch(node, patch) when is_map(node),
    do: Map.merge(node, Map.take(patch, Map.keys(node)))
end
