defmodule SwarmCodeCLI.Companion.View do
  @moduledoc """
  Pure projection of the reducer `State` into the companion page's JSON view.

  Every key in the contract is always present: unknown scalars are `nil`,
  unknown lists `[]`. The active run and the tab order come from the same
  projector helpers the TUI paints with, so the page never disagrees with it.
  Nothing here performs IO; the hub owns the clock and the encoding cadence.
  """

  alias SwarmCodeCLI.UI.{ReadModel, State}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Projector.{Shell, Support}

  @max_items 200
  @max_text 4_000
  @hues 6
  @unavailable "not reported by the daemon yet"
  @terminal_states [:done, :failed, :stopped, :interrupted, :superseded]
  @waiting_states [:waiting_question, :waiting_approval]
  @swarm_kinds [:swarm, :consensus, :ultra, :workflow]

  @doc """
  Builds the view for `state` at wall-clock `now` (milliseconds).

  `meta` may carry `:project` (a display name for the header) and `:started_at`
  (session start in milliseconds); both default to what the state knows.
  `revision` is always `0` here: the hub assigns it when the view changes.
  """
  @spec build(State.t(), non_neg_integer(), keyword()) :: map()
  def build(%State{} = state, now, meta \\ []) when is_integer(now) and now >= 0 do
    run = Support.run(state)
    rows = run_agents(state, run)
    items = run_items(state, run)
    lead = lead_id(items, rows)
    rows = lead_first(rows, lead)
    agents = rows |> Enum.with_index() |> Enum.map(fn {row, index} -> agent(row, index, lead) end)

    %{
      revision: 0,
      session: %{
        id: session_id(state.source_epoch),
        started_at: Keyword.get(meta, :started_at) || state.now,
        now: now
      },
      header: header(state, run, meta),
      tabs: tabs(state, run),
      run: run_json(run, rows, lead),
      agents: agents,
      transcript: Enum.map(items, &item(&1, state)),
      needs: needs(state),
      changes: %{files: [], unavailable: @unavailable},
      timeline: %{events: Enum.map(items, &event(&1, state, lead)), checkpoints: []},
      verdict: nil,
      artifacts: [],
      focus: focus(state, run, items),
      notice: notice(state.notice)
    }
  end

  @doc "The view with the volatile fields zeroed, for change detection."
  @spec fingerprint(map()) :: map()
  def fingerprint(view), do: %{view | revision: 0, session: %{view.session | now: 0}}

  # -- header ---------------------------------------------------------------

  defp header(state, run, meta) do
    workspace =
      case Map.get(state.read_model.snapshots, :workspace) do
        %DTO.WorkspaceSnapshot{} = snapshot -> snapshot
        _ -> nil
      end

    swarm? = run != nil and run.kind in @swarm_kinds

    %{
      project: Keyword.get(meta, :project),
      model: pick(workspace, swarm?, :swarm_model, :chat_model),
      mode: workspace && workspace.mode && word(workspace.mode),
      approval: nil,
      keymap: word(state.keymap),
      effort: pick(workspace, swarm?, :swarm_effort, :effort),
      cost: nil,
      context_tokens: nil
    }
  end

  defp pick(nil, _, _, _), do: nil

  defp pick(workspace, swarm?, swarm_field, chat_field) do
    {first, second} = if swarm?, do: {swarm_field, chat_field}, else: {chat_field, swarm_field}
    blank_to_nil(Map.get(workspace, first)) || blank_to_nil(Map.get(workspace, second))
  end

  # -- tabs and run ---------------------------------------------------------

  defp tabs(state, run) do
    active = if run, do: run.id
    needs = pending_interactions(state)

    Enum.map(Shell.tabline_runs(state), fn row ->
      %{
        id: row.id,
        title: row.title,
        state: word(row.state),
        kind: word(row.kind),
        agents: Enum.count(state.read_model.agents, fn {_, a} -> a.run_id == row.id end),
        needs: Enum.count(needs, &(&1.run_id == row.id)),
        started_at: nil,
        finished_at: nil,
        active: row.id == active
      }
    end)
  end

  defp run_json(nil, _, _),
    do: %{
      id: nil,
      title: nil,
      state: nil,
      kind: nil,
      started_at: nil,
      finished_at: nil,
      edges: []
    }

  defp run_json(run, rows, lead) do
    edges =
      if lead,
        do: for(row <- rows, row.id != lead, do: %{from: lead, to: row.id, kind: "spawn"}),
        else: []

    %{
      id: run.id,
      title: run.title,
      state: word(run.state),
      kind: word(run.kind),
      started_at: nil,
      finished_at: nil,
      edges: edges
    }
  end

  # -- agents ---------------------------------------------------------------

  defp run_agents(_state, nil), do: []

  defp run_agents(state, run) do
    state.read_model.agents
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.sort_by(& &1.id)
  end

  # The daemon sends no parent or root marker, and agent ids are node ids, so
  # the lead is the agent that authored the run's earliest non-user item. When
  # no item names an agent, nobody is the lead and the hive has no centre.
  defp lead_id(_items, []), do: nil

  defp lead_id(items, rows) do
    ids = MapSet.new(rows, & &1.id)

    Enum.find_value(items, fn item ->
      if item.role != :user and MapSet.member?(ids, item.node_id), do: item.node_id
    end)
  end

  defp lead_first(rows, nil), do: rows

  defp lead_first(rows, lead) do
    {leads, rest} = Enum.split_with(rows, &(&1.id == lead))
    leads ++ rest
  end

  defp agent(row, index, lead) do
    lead? = row.id == lead

    %{
      id: row.id,
      name: if(lead?, do: "lead", else: "agent-" <> short(row.id)),
      role: if(lead?, do: "lead", else: "worker"),
      state: word(row.state),
      step: word(row.state),
      progress: progress(row.state),
      tokens: nil,
      hue: rem(index, @hues),
      waiting: row.state in @waiting_states,
      parent_id: if(lead?, do: nil, else: lead),
      started_at: nil
    }
  end

  defp short(id) do
    id
    |> String.replace_prefix("agent-", "")
    |> String.slice(0, 4)
  end

  defp progress(state) when state in @terminal_states, do: 1.0
  defp progress(:queued), do: 0.0
  defp progress(_), do: 0.5

  # -- transcript and timeline ---------------------------------------------

  defp run_items(_state, nil), do: []

  defp run_items(state, run) do
    model = state.read_model

    model.transcript
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.sort_by(&{&1.created_sequence, &1.id})
    |> Enum.take(-@max_items)
    |> Enum.map(&ReadModel.transcript_item(model, &1.id))
  end

  defp item(item, state) do
    %{
      id: item.id,
      role: word(item.role),
      agent_id: agent_id(state, item.node_id),
      state: word(item.state),
      kind: "text",
      text: cap(item.text),
      reasoning: blank_to_nil(cap(item.reasoning)),
      at: item.created_sequence
    }
  end

  defp event(item, state, lead) do
    agent = agent_id(state, item.node_id)

    kind =
      cond do
        item.role == :user -> "you"
        item.state in @waiting_states -> "wait"
        agent != nil and agent != lead -> "agent"
        true -> "lead"
      end

    %{at: item.created_sequence, kind: kind, agent_id: agent}
  end

  defp cap(nil), do: ""
  defp cap(text) when is_binary(text), do: String.slice(text, 0, @max_text)

  # -- needs ----------------------------------------------------------------

  defp needs(state) do
    state
    |> pending_interactions()
    |> Enum.map(&need(&1, state))
  end

  defp pending_interactions(state) do
    state.read_model.interactions
    |> Map.values()
    |> Enum.filter(&(&1.state == :pending))
    |> Enum.sort_by(&{&1.created_at, &1.id})
  end

  defp need(%DTO.PendingInteraction{kind: :approval} = need, state) do
    approval = need.approval || %DTO.Approval{}

    base(need, state)
    |> Map.merge(%{
      title: blank_to_nil(approval.tool) || "approval",
      command: blank_to_nil(approval.arguments_preview),
      risk: word(approval.permission),
      options: [%{id: "approve", label: "allow"}, %{id: "deny", label: "deny"}]
    })
  end

  defp need(%DTO.PendingInteraction{} = need, state) do
    question = need.question || %DTO.Question{}

    base(need, state)
    |> Map.merge(%{
      title: blank_to_nil(question.prompt) || "question",
      command: nil,
      risk: nil,
      options: Enum.map(question.options, &%{id: &1.id, label: &1.label})
    })
  end

  defp base(need, state) do
    %{
      id: need.id,
      kind: word(need.kind),
      run_id: need.run_id,
      agent_id: agent_id(state, need.node_id),
      cwd: nil,
      reason: nil,
      revision: need.expected_revision
    }
  end

  # -- focus and notice -----------------------------------------------------

  defp focus(state, run, items) do
    main = Map.get(state.selection, "main")
    inspector = Map.get(state.selection, "inspector")

    cond do
      state.focus == "composer" ->
        %{kind: "composer", id: nil}

      state.focus == "inspector" and agent_id(state, inspector) != nil ->
        %{kind: "agent", id: inspector}

      state.focus == "main" and is_binary(main) and Enum.any?(items, &(&1.id == main)) ->
        %{kind: "item", id: main}

      run != nil ->
        %{kind: "run", id: run.id}

      true ->
        %{kind: "composer", id: nil}
    end
  end

  defp notice(nil), do: nil
  defp notice({:command_feedback, text}) when is_binary(text), do: text

  defp notice({kind, reason}) when is_atom(kind) and is_atom(reason),
    do: label(kind) <> " · " <> label(reason)

  defp notice(kind) when is_atom(kind), do: label(kind)
  defp notice(_), do: nil

  defp label(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  # -- helpers --------------------------------------------------------------

  defp agent_id(_state, nil), do: nil

  defp agent_id(state, id) when is_binary(id),
    do: if(Map.has_key?(state.read_model.agents, id), do: id, else: nil)

  defp agent_id(_state, _), do: nil

  defp session_id(epoch) when is_binary(epoch), do: String.slice(epoch, 0, 8)
  defp session_id(_), do: nil

  defp word(nil), do: nil
  defp word(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp word(text) when is_binary(text), do: text

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text) when is_binary(text), do: text
end
