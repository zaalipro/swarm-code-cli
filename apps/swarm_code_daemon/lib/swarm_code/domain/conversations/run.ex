defmodule SwarmCode.Domain.Conversations.Run do
  @moduledoc """
  One execution of a chat turn or a swarm task.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Workflow runs add three non-terminal states (spec 09 §4).
  @statuses ~w(running done failed stopped paused waiting_user interrupted)

  def statuses, do: @statuses

  schema "runs" do
    field(:kind, :string)
    field(:status, :string, default: "running")
    field(:prompt, :string, default: "")
    field(:root_node_id, :binary_id)
    field(:tokens_in, :integer, default: 0)
    field(:tokens_out, :integer, default: 0)
    field(:cost_usd, :float)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:interrupted, :boolean, default: false)
    field(:model, :string)
    # The goal this run pursues (spec 10 §16) and its short AI label (§13).
    field(:goal_id, :binary_id)
    field(:label, :string)
    # Pass 12 §1: when the user last saw this run's thread (nil = never).
    field(:seen_at, :utc_datetime_usec)
    # Spec 17 §2.6: the run whose agent started this one (the `start_swarm`
    # tool). A run with this set never claims a user message as its launcher.
    field(:launched_by_run_id, :binary_id)
    # Spec 37 §6.4: this turn ran with a judge. Spec 40 §2.2: with what —
    # checks, rounds, judge model and effort — so the card can say so after
    # the RunServer is gone.
    field(:consensus, :boolean, default: false)
    field(:consensus_config, :map)
    # Spec 45 §5.2: the stopped / failed / interrupted run this one continues.
    field(:resumed_from_run_id, :binary_id)
    # Spec 49 §1.5: a cleanup dropped this run's node payloads. Every node row,
    # its status, tokens, cost and timings are still here — only the tool
    # output, the prompts and the details went.
    field(:pruned, :boolean, default: false)
    # Spec 50 §4: the mode this run actually ran in. `conversations.mode` is
    # mutable, so a finished run could not otherwise say whether it was a plan.
    field(:mode, :string)
    # Spec 50 §7: the planner run this one implements, and what the user did
    # with that plan (nil | approved | declined | revised).
    field(:implements_run_id, :binary_id)
    field(:plan_state, :string)
    # Spec 52 §1.1: the message that launched this run was edited and resent.
    # The card stays in the transcript, folded; the pane, the dock and the LIVE
    # pills drop it.
    field(:superseded_at, :utc_datetime_usec)

    belongs_to(:conversation, SwarmCode.Domain.Conversations.Conversation)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(conversation_id kind status prompt root_node_id
             tokens_in tokens_out cost_usd started_at finished_at interrupted model
             goal_id label seen_at launched_by_run_id consensus consensus_config
             resumed_from_run_id pruned mode implements_run_id plan_state superseded_at)a

  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:conversation_id, :kind, :started_at])
    |> validate_inclusion(:kind, ["chat", "swarm", "workflow", "research", "compact"])
    |> validate_inclusion(:status, @statuses)
    # Spec 50 §4 / §7: both skip `nil`, so every row written before the
    # `20260923000000_plan_gate` migration stays valid.
    |> validate_inclusion(:mode, ["build", "plan"])
    |> validate_inclusion(:plan_state, ["approved", "declined", "revised"])
  end

  @typedoc "What a run is called, drawn as, coloured as, and what its root agent is named."
  @type persona :: %{
          name: String.t(),
          glyph: String.t(),
          kind: :goal | :swarm | :wf | :ai,
          agent: String.t()
        }

  @doc """
  The persona of a run (spec 51 §8.2): one ordered table, top to bottom —
  the user's label · the workflow · the compaction · the goal · the swarm ·
  the workflow-authoring turn · consensus · plan mode · the assistant. Each
  row fills what it knows; a row that names the run and says nothing about
  its glyph or colour (the label, the goal) defers those to the next row that
  matches. The transcript card, the pane's rows, the kind colours, the root
  node's name and the notification title all read this table, so none of
  them can disagree again. `goal` is the goal row when the caller has it,
  `wf` the workflow run (`display_name`) when it has that.
  """
  @spec persona(map(), map() | nil, map() | nil) :: persona()
  def persona(run, goal \\ nil, wf \\ nil) do
    Enum.reduce_while(rows(run, goal, wf), %{}, fn
      {false, _cells}, acc ->
        {:cont, acc}

      {true, cells}, acc ->
        # The earlier row's cells win; a nil cell says nothing.
        acc =
          cells
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
          |> Map.merge(acc)

        if map_size(acc) == 4, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  # Spec 54 §4 (54b U9): `Engine.fallback_label/1` takes the first four words of
  # the *stored message*, and a goal's stored message keeps its command markers
  # — so the side-chat head, the dock pill and the pane row read
  # "◎ /goal slow60 goal six" until the model's label lands, and for ever when
  # it does not. A marker belongs to the command chip, not to the run's name.
  @command_markers ~w(/goal /swarm /compact /plan /ultra /deep_research
                      /create-workflow /workflow /review /resume /rewind)

  defp strip_markers(label) when is_binary(label) do
    case String.split(label, " ", parts: 2) do
      [head, rest] -> if head in @command_markers, do: strip_markers(rest), else: label
      _one_word -> label
    end
  end

  defp strip_markers(label), do: label

  defp rows(run, goal, wf) do
    label = Map.get(run, :label)
    kind = Map.get(run, :kind)
    prompt = Map.get(run, :prompt)
    goal_text = goal && Map.get(goal, :text)

    [
      # Spec 17 §2.7: the user's own label names the run, whatever it is.
      {present?(label), %{name: strip_markers(label)}},
      # A workflow shows its display name; its glyph and colour are the workflow's.
      {is_map(wf), %{name: wf && Map.get(wf, :display_name), glyph: "⧉", kind: :wf}},
      {kind == "workflow", %{glyph: "⧉", kind: :wf}},
      # Spec 50 §1.6: a compaction is bookkeeping — the only card with no kind
      # colour, whatever conversation it folds (above the goal rows for that).
      {kind == "compact",
       %{name: "Context compacted", glyph: "⊟", kind: :ai, agent: "Compactor"}},
      # A goal run is named by its goal (spec 07 §15) — renaming it there edits the goal.
      {present?(goal_text), %{name: goal_text, glyph: "◎", kind: :goal}},
      {is_binary(Map.get(run, :goal_id)),
       %{name: preview(prompt || "goal"), glyph: "◎", kind: :goal}},
      {kind == "swarm", %{name: preview(prompt || "swarm"), glyph: "⋔", kind: :swarm}},
      # Spec 12 §5: the `/create-workflow` turn authors a workflow (the engine's
      # `chat_agent_name/1` puts it first as well).
      {String.starts_with?(to_string(prompt), "/create-workflow"),
       %{name: "Authoring workflow…", glyph: "⧉", kind: :wf, agent: "Workflow author"}},
      # Spec 42 §3.1: a judged turn is a consensus from its first second. Above
      # plan mode: a consensus turn carries the conversation's mode, and pass 36
      # §3.3 pins that such a run reads "Consensus".
      {Map.get(run, :consensus) == true,
       %{name: "Consensus", glyph: "⚖", kind: :ai, agent: "Consensus"}},
      # Spec 50 §4: the Planner, with the mode menu's own glyph.
      {Map.get(run, :mode) == "plan",
       %{name: "Planner", glyph: "▤", kind: :ai, agent: "Planner"}},
      {true, %{name: "Assistant", glyph: "✱", kind: :ai, agent: "Assistant"}}
    ]
  end

  @doc """
  The run's name for a notification (spec 43 §1.7) — the persona's, so the
  notification says what the card says.
  """
  @spec display_name(map()) :: String.t()
  def display_name(run), do: persona(run).name

  @doc """
  What a chat run's root agent is called (spec 50 §4) — the persona's `agent`,
  read by the engine when it names the node, by the pane's row and by the
  transcript card: Workflow author › Consensus › Planner › Assistant.
  """
  @spec agent_name(map()) :: String.t()
  def agent_name(run), do: persona(run).agent

  defp present?(text), do: is_binary(text) and String.trim(text) != ""

  # A prompt on one line, at most 40 characters with its ellipsis — the
  # notification's rule (spec 43 §1.7, pinned by `pass37_engine_test`); the
  # card used `Format.preview(prompt, 40)` (41 with the ellipsis) before the
  # table, so a long swarm prompt reads one character shorter on its card.
  defp preview(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) > 40, do: String.slice(text, 0, 39) <> "…", else: text
  end
end
