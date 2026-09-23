defmodule SwarmCodeCLI.Companion.View do
  @moduledoc """
  Pure projection of the reducer `State` into the companion page's JSON view.

  Every key in the contract is always present: unknown scalars are `nil`,
  unknown lists `[]`. The active run and the tab order come from the same
  projector helpers the TUI paints with, so the page never disagrees with it.
  Nothing here performs IO; the hub owns the clock and the encoding cadence.

  The wire now carries real facts, so the page shows them: agent names, roles,
  steps, gauges, tokens and cost; tool calls on transcript items; the changes
  ledger with its blast radius; the judge's verdict. Two shapes are derived
  rather than reported, and both are documented where they are built:
  `run.edges` fall back to lead → everyone when the daemon reports no parent
  ids, and `timeline.checkpoints` are one change per minute. Only artefacts
  stay empty; the daemon does not record them yet.

  `at` is milliseconds everywhere (transcript, timeline, changes), so the
  page's scrubber axis is wall-clock time. Items whose time is unknown inherit
  the previous item's time, which keeps that axis monotonic and finite.
  """

  alias SwarmCodeCLI.UI.{ReadModel, State}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Projector.{Shell, Support}

  @max_items 200
  @max_changes 200
  @max_checkpoints 12
  @max_text 4_000
  @hues 6
  @minute 60_000
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
    raw = run_items(state, run)
    lead = lead_id(raw, rows)
    rows = lead_first(rows, lead)
    parents = parents(rows, lead)
    judges = for row <- rows, row.role == :judge, into: MapSet.new(), do: row.id
    items = stamp(raw, run)
    changes = run_changes(state, run)

    agents =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> agent(row, index, lead, parents) end)

    %{
      revision: 0,
      session: %{
        id: session_id(state.source_epoch),
        started_at: Keyword.get(meta, :started_at) || state.now,
        now: now
      },
      header: header(state, run, meta),
      tabs: tabs(state, run),
      run: run_json(run, rows, parents),
      agents: agents,
      transcript: Enum.map(items, &item(&1, state)),
      needs: needs(state),
      changes: changes_json(changes),
      timeline: %{
        events: items |> Enum.map(&event(&1, state, lead, judges)) |> Enum.sort_by(& &1.at),
        checkpoints: checkpoints(changes)
      },
      verdict: verdict(state, run),
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
      model: run_model(run) || pick(workspace, swarm?, :swarm_model, :chat_model),
      mode: workspace && workspace.mode && word(workspace.mode),
      approval: approval_words(workspace && Map.get(workspace, :approval_mode)),
      keymap: word(state.keymap),
      effort: pick(workspace, swarm?, :swarm_effort, :effort),
      cost: (run && run.cost_usd) || (workspace && Map.get(workspace, :cost_usd)),
      context_tokens:
        (run && sum_tokens(run.tokens_in, run.tokens_out)) ||
          (workspace && Map.get(workspace, :context_used))
    }
  end

  # pass70 C1: the project's approval mode, in the status row's words.
  defp approval_words(nil), do: nil
  defp approval_words(mode) when mode in [:read_only, "read_only"], do: "read-only"

  defp approval_words(mode) when mode in [:full, :full_access, "full", "full_access"],
    do: "full access"

  defp approval_words(mode), do: word(mode)

  defp run_model(nil), do: nil
  defp run_model(run), do: blank_to_nil(run.model)

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
      counted = Enum.count(state.read_model.agents, fn {_, a} -> a.run_id == row.id end)
      pending = Enum.count(needs, &(&1.run_id == row.id))

      %{
        id: row.id,
        title: row.title,
        state: word(row.state),
        kind: word(row.kind),
        agents: max(row.agents_total, counted),
        needs: max(row.needs, pending),
        started_at: row.started_at,
        finished_at: row.finished_at,
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

  defp run_json(run, rows, parents) do
    %{
      id: run.id,
      title: run.title,
      state: word(run.state),
      kind: word(run.kind),
      started_at: run.started_at,
      finished_at: run.finished_at,
      edges:
        for row <- rows, parent = Map.get(parents, row.id), parent != nil do
          %{from: parent, to: row.id, kind: "spawn"}
        end
    }
  end

  # -- agents ---------------------------------------------------------------

  defp run_agents(_state, nil), do: []

  defp run_agents(state, run) do
    state.read_model.agents
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.sort_by(&{&1.depth, &1.id})
  end

  # The lead is the agent the daemon marks `:lead`; failing that the root of
  # the parent forest; failing that the agent that authored the run's earliest
  # non-user item. When nothing names one, nobody leads and the hive has no
  # centre.
  defp lead_id(_items, []), do: nil

  defp lead_id(items, rows) do
    ids = MapSet.new(rows, & &1.id)

    cond do
      row = Enum.find(rows, &(&1.role == :lead)) ->
        row.id

      row = Enum.find(rows, &root_of_forest?(&1, rows)) ->
        row.id

      true ->
        Enum.find_value(items, fn item ->
          id = item.agent_id || item.node_id
          if item.role != :user and is_binary(id) and MapSet.member?(ids, id), do: id
        end)
    end
  end

  defp root_of_forest?(row, rows),
    do: row.parent_id == nil and Enum.any?(rows, &(&1.parent_id == row.id))

  defp lead_first(rows, nil), do: rows

  defp lead_first(rows, lead) do
    {leads, rest} = Enum.split_with(rows, &(&1.id == lead))
    leads ++ rest
  end

  # Spawn parents, honest first: every reported `parent_id` that names another
  # agent of this run. Only when the daemon reports none at all does the lead
  # stand in as everyone's parent, so the hive still draws a graph instead of a
  # scatter. Agents and edges read the same map, so they can never disagree.
  defp parents(rows, lead) do
    ids = MapSet.new(rows, & &1.id)

    real =
      for row <- rows,
          is_binary(row.parent_id),
          row.parent_id != row.id,
          MapSet.member?(ids, row.parent_id),
          into: %{},
          do: {row.id, row.parent_id}

    if map_size(real) == 0 and lead != nil,
      do: Map.new(rows, &{&1.id, if(&1.id == lead, do: nil, else: lead)}),
      else: real
  end

  defp agent(row, index, lead, parents) do
    lead? = row.id == lead

    %{
      id: row.id,
      name: blank_to_nil(row.name) || "agent-" <> short(row.id),
      role: role(row, lead?),
      state: word(row.state),
      step: blank_to_nil(row.step) || word(row.state),
      progress: progress(row),
      tokens: sum_tokens(row.tokens_in, row.tokens_out),
      cost: row.cost_usd,
      hue: if(lead?, do: 0, else: rem(index, @hues)),
      waiting: row.state in @waiting_states,
      parent_id: Map.get(parents, row.id),
      started_at: row.started_at,
      finished_at: row.finished_at,
      error: blank_to_nil(row.error)
    }
  end

  defp role(%{role: role}, _lead?) when role not in [:unknown, nil], do: word(role)
  defp role(_row, true), do: "lead"
  defp role(_row, false), do: "worker"

  defp short(id) when is_binary(id) do
    id
    |> String.replace_prefix("agent-", "")
    |> String.slice(0, 4)
  end

  defp short(_), do: "?"

  # The reported gauge wins. Without one, the state still says something true:
  # finished work is full, queued work is empty, anything else is half.
  defp progress(%{progress: progress}) when is_integer(progress) and progress > 0,
    do: min(progress, 100) / 100

  defp progress(%{state: state}) when state in @terminal_states, do: 1.0
  defp progress(%{state: :queued}), do: 0.0
  defp progress(_), do: 0.5

  # -- transcript and timeline ---------------------------------------------

  defp run_items(_state, nil), do: []

  defp run_items(state, run) do
    model = state.read_model

    model.transcript
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.sort_by(&{reading_rank(&1), &1.created_sequence, &1.id})
    |> Enum.take(-@max_items)
    |> Enum.map(&ReadModel.transcript_item(model, &1.id))
  end

  # The page lists a run's items flat, so it reads them as a turn: the prompt,
  # then the work as it happened, then what was said (the daemon creates the
  # reply before the calls that produce it).
  defp reading_rank(%{role: :user}), do: 0
  defp reading_rank(%{kind: kind}) when kind in [:tool, :thinking], do: 1
  defp reading_rank(%{id: id, node_id: id}), do: 1
  defp reading_rank(_), do: 2

  # One axis for the scrubber: milliseconds. An item with no time of its own
  # sits where the previous one did, starting at the run's own start.
  defp stamp(items, run) do
    start = (run && run.started_at) || 0

    items
    |> Enum.map_reduce(start, fn item, last ->
      at = if is_integer(item.at) and item.at > 0, do: item.at, else: last
      {{item, at}, at}
    end)
    |> elem(0)
  end

  defp item({item, at}, state) do
    %{
      id: item.id,
      role: word(item.role),
      agent_id: item_agent(state, item),
      state: word(item.state),
      kind: word(item.kind),
      text: cap(item.text),
      reasoning: blank_to_nil(cap(item.reasoning)),
      tool: tool(item.tool),
      tokens: sum_tokens(item.tokens_in, item.tokens_out),
      at: at
    }
  end

  defp tool(%DTO.ToolCall{} = tool) do
    %{
      name: blank_to_nil(tool.name),
      title: blank_to_nil(tool.title),
      detail: blank_to_nil(tool.detail),
      status: word(tool.status),
      duration_ms: tool.duration_ms,
      result_bytes: tool.result_bytes,
      files: tool.files
    }
  end

  defp tool(_), do: nil

  defp event({item, at}, state, lead, judges) do
    agent = item_agent(state, item)

    kind =
      cond do
        item.role == :user -> "you"
        item.state in @waiting_states -> "wait"
        agent != nil and MapSet.member?(judges, agent) -> "judge"
        item.kind == :tool -> "tool"
        agent != nil and agent != lead -> "agent"
        true -> "lead"
      end

    %{at: at, kind: kind, agent_id: agent}
  end

  defp cap(nil), do: ""
  defp cap(text) when is_binary(text), do: String.slice(text, 0, @max_text)

  # -- changes and verdict --------------------------------------------------

  defp run_changes(_state, nil), do: []

  defp run_changes(state, run) do
    state.read_model.changes
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.sort_by(&{&1.at, &1.id})
    |> Enum.take(-@max_changes)
  end

  defp changes_json(changes) do
    files =
      Enum.map(changes, fn change ->
        %{
          id: change.id,
          path: change.path,
          agent_id: change.agent_id,
          restorable: change.restorable,
          at: change.at
        }
      end)

    %{files: files, blast: blast(changes), unavailable: nil}
  end

  # Blast radius: the paths two or more agents wrote. Everything else in the
  # ledger is one agent's own work and needs no warning.
  defp blast(changes) do
    changes
    |> Enum.reject(&(blank_to_nil(&1.agent_id) == nil))
    |> Enum.group_by(& &1.path, & &1.agent_id)
    |> Enum.map(fn {path, ids} -> {path, ids |> Enum.uniq() |> Enum.sort()} end)
    |> Enum.filter(fn {_path, ids} -> length(ids) > 1 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {path, ids} -> %{path: path, agent_ids: ids} end)
  end

  # Checkpoints are the timeline's pins, so one per minute is enough: the first
  # change of each minute, newest twelve, labelled with the file's name.
  defp checkpoints(changes) do
    changes
    |> Enum.reject(&(&1.at == 0))
    |> Enum.group_by(&div(&1.at, @minute))
    |> Enum.map(fn {_minute, [first | _]} -> first end)
    |> Enum.sort_by(& &1.at)
    |> Enum.take(-@max_checkpoints)
    |> Enum.map(&%{at: &1.at, label: Path.basename(&1.path)})
  end

  defp verdict(_state, nil), do: nil

  defp verdict(state, run) do
    state.read_model.verdicts
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.max_by(&{&1.round, &1.revision, &1.id}, fn -> nil end)
    |> verdict_json()
  end

  defp verdict_json(nil), do: nil

  defp verdict_json(verdict) do
    %{
      id: verdict.id,
      run_id: verdict.run_id,
      round: verdict.round,
      status: word(verdict.status),
      checks: Enum.map(verdict.checks, &%{key: &1.key, ok: &1.ok, note: blank_to_nil(&1.note)}),
      summary: blank_to_nil(verdict.summary)
    }
  end

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

    # pass70 C1: the command itself, where it runs, why, and the daemon's
    # verdict on it when it has one; the argument preview otherwise.
    risk =
      case Map.get(approval, :classification) do
        classification when classification in [:dangerous, :safe] -> word(classification)
        _ -> word(approval.permission)
      end

    base(need, state)
    |> Map.merge(%{
      title: blank_to_nil(approval.tool) || "approval",
      command:
        blank_to_nil(Map.get(approval, :command)) || blank_to_nil(approval.arguments_preview),
      risk: risk,
      cwd: blank_to_nil(Map.get(approval, :cwd)),
      reason: blank_to_nil(Map.get(approval, :reason)),
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

      state.focus == "main" and is_binary(main) and Enum.any?(items, &(elem(&1, 0).id == main)) ->
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

  defp item_agent(state, item),
    do: agent_id(state, item.agent_id) || agent_id(state, item.node_id)

  defp agent_id(_state, nil), do: nil

  defp agent_id(state, id) when is_binary(id),
    do: if(Map.has_key?(state.read_model.agents, id), do: id, else: nil)

  defp agent_id(_state, _), do: nil

  defp sum_tokens(into, out) do
    total = (is_integer(into) && into) || 0
    total = total + ((is_integer(out) && out) || 0)
    if total > 0, do: total
  end

  defp session_id(epoch) when is_binary(epoch), do: String.slice(epoch, 0, 8)
  defp session_id(_), do: nil

  defp word(nil), do: nil
  defp word(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp word(text) when is_binary(text), do: text

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text) when is_binary(text), do: text
end
