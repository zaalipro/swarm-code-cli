defmodule SwarmCode.Domain.Workflows.Sidebar do
  @moduledoc """
  Everything the Workflows page's sidebar draws (spec 64 §Data), derived once
  per change instead of once per render — the shape of
  `SwarmCode.Domain.Scheduled.Sidebar`.

  `build/4` answers the whole panel — the four KPI tiles, the phase board, the
  needs-you cards, the per-definition health of the Library and the next
  scheduled workflow — out of **four** queries:

    1. the unfinished runs (`Workflows.list_runs(:active)` as it is);
    2. the agent nodes of those runs (live and done counts per run);
    3. this month's workflow runs (the WEEK and SPEND tiles);
    4. every workflow run that carries a `definition_name` (the Library's
       `runs · ok %` and its last-run glyph).

  The definitions and the scheduled tasks come in as arguments — the page
  already holds both — so nothing else is read.
  """

  import Ecto.Query

  alias SwarmCode.Domain.Conversations.{Node, Run}
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Scheduler.Next
  alias SwarmCode.Domain.Workflows
  alias SwarmCode.Domain.Workflows.Run, as: WorkflowRun

  # What the board shows, in the order it shows them.
  @rank %{"running" => 0, "waiting_user" => 1, "paused" => 2, "interrupted" => 3}
  @unfinished Map.keys(@rank)
  @needs ~w(waiting_user paused)
  @node_live ~w(running retrying)
  @finished ~w(done failed stopped interrupted)
  # Tracks, not runs: past this the board shows one `+ n more` line.
  @cap 8

  @type track :: map()

  @type t :: %{
          kpis: %{
            live: non_neg_integer(),
            live_agents: non_neg_integer(),
            need_you: non_neg_integer(),
            week: non_neg_integer(),
            week_ok: non_neg_integer(),
            spend: float()
          },
          board: [track()],
          board_more: non_neg_integer(),
          unfinished: non_neg_integer(),
          needs: [map()],
          stats: %{optional({String.t(), String.t()}) => map()},
          groups: [{String.t(), [map()]}],
          next_task: map() | nil,
          topics: MapSet.t()
        }

  @doc """
  The sidebar's whole state.

  `definitions` are the page's cached ones (already the union of every scope
  under `All projects`), `projects` name the board's chips and the Library's
  groups, `tasks` are the shell's scheduled ones.

  Options: `:now`, `:zone` (the local zone the week and the month are cut on)
  and `:scope` — the switcher's project id or `"all"`, which says whether the
  footer can tell a broken scheduled workflow from one it simply cannot see.
  """
  @spec build([map()], [map()], [map()], keyword()) :: t()
  def build(definitions, projects, tasks, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    zone = Keyword.get(opts, :zone) || Next.local_zone()
    scope = Keyword.get(opts, :scope, "all")

    rows = Workflows.list_runs(:active) |> Enum.filter(&(&1.run.status in @unfinished))
    agents = agent_nodes(Enum.map(rows, & &1.wf.run_id))
    month = month_rows(month_start(now, zone))
    history = definition_rows()

    tracks = tracks(rows, agents, projects, now)

    %{
      kpis: kpis(rows, agents, month, monday(now, zone)),
      board: Enum.take(tracks, @cap),
      board_more: max(length(tracks) - @cap, 0),
      unfinished: length(tracks),
      needs: needs(rows),
      stats: stats(history, rows),
      groups: groups(definitions, projects),
      next_task: next_task(tasks, definitions, scope),
      topics: rows |> Enum.map(& &1.wf.conversation_id) |> Enum.reject(&is_nil/1) |> MapSet.new()
    }
  end

  ## ------------------------------------------------------------- the queries

  # Query 2. Only the agent nodes of the unfinished runs, only their status:
  # the board's `6 live` and the segment titles' `3 done of 9 admitted`.
  defp agent_nodes([]), do: %{}

  defp agent_nodes(run_ids) do
    from(n in Node,
      where: n.run_id in ^run_ids and n.kind == "agent",
      select: {n.run_id, n.status}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {run_id, statuses} ->
      {run_id,
       %{
         live: Enum.count(statuses, &(&1 in @node_live)),
         done: Enum.count(statuses, &(&1 == "done"))
       }}
    end)
  end

  # Query 3. A month of workflow runs is small; the week split and both sums
  # happen in Elixir rather than in three aggregate queries.
  defp month_rows(since) do
    from(r in Run,
      where: r.kind == "workflow" and r.started_at >= ^since,
      select: {r.started_at, r.status, r.cost_usd}
    )
    |> Repo.all()
  end

  # Query 4. Every run that names a definition, newest first. If `workflow_runs`
  # ever grows past a few thousand rows this is the query to page (a per-name
  # `LIMIT` needs a window function; today the whole table is cheaper than the
  # complexity).
  defp definition_rows do
    from(w in WorkflowRun,
      join: r in Run,
      on: r.id == w.run_id,
      where: not is_nil(w.definition_name),
      order_by: [desc: r.started_at],
      select: %{
        scope: w.scope,
        name: w.definition_name,
        status: r.status,
        started_at: r.started_at,
        run_id: w.run_id,
        display_name: w.display_name
      }
    )
    |> Repo.all()
  end

  ## -------------------------------------------------------------------- KPIs

  defp kpis(rows, agents, month, monday) do
    running = Enum.filter(rows, &(&1.run.status == "running"))
    week = Enum.filter(month, fn {at, _s, _c} -> at && DateTime.compare(at, monday) != :lt end)

    %{
      live: length(running),
      live_agents: Enum.reduce(running, 0, &(count(agents, &1.wf.run_id, :live) + &2)),
      need_you: Enum.count(rows, &(&1.run.status in @needs)),
      week: length(week),
      week_ok: Enum.count(week, fn {_at, status, _c} -> status == "done" end),
      spend: Enum.reduce(month, 0.0, fn {_at, _s, cost}, acc -> acc + (cost || 0.0) end)
    }
  end

  defp count(agents, run_id, key), do: agents |> Map.get(run_id, %{}) |> Map.get(key, 0)

  ## ------------------------------------------------------------- phase board

  # One track per unfinished run, except that interrupted runs of the same
  # definition collapse into one — three `review-changes` rows left by a quit
  # are one thing to resume, not three (spec 64 §3).
  defp tracks(rows, agents, projects, now) do
    rows
    |> Enum.group_by(&cluster_key/1)
    |> Map.values()
    |> Enum.map(&Enum.sort_by(&1, fn row -> unix(row.run.started_at) end, :desc))
    |> Enum.map(&track(&1, agents, projects, now))
    |> Enum.sort_by(&{Map.get(@rank, &1.status, 9), -unix(&1.started_at)})
  end

  # An adhoc or assistant-written run (no `definition_name`) is always its own
  # track, and so is anything that is not interrupted.
  defp cluster_key(%{run: %{status: "interrupted"}, wf: %{definition_name: name} = wf})
       when is_binary(name),
       do: {:group, wf.scope, name}

  defp cluster_key(%{wf: wf}), do: {:one, wf.run_id}

  defp track([%{wf: wf, run: run} = primary | _] = cluster, agents, projects, now) do
    count = length(cluster)
    phases = phases(wf)
    current = current_index(phases, wf.phase)
    live = count(agents, wf.run_id, :live)
    done = count(agents, wf.run_id, :done)
    started = run.started_at || wf.inserted_at

    %{
      run_id: wf.run_id,
      run_ids: Enum.map(cluster, & &1.wf.run_id),
      count: count,
      status: run.status,
      name: (count > 1 && wf.definition_name) || wf.display_name,
      project: project_name(projects, primary[:conversation]),
      conversation_id: wf.conversation_id,
      phase: wf.phase,
      phases: phases,
      live: live,
      done: done,
      admitted: wf.agents_admitted || 0,
      budget: wf.budget,
      pause_kind: wf.pause_kind,
      pause_message: wf.pause_message,
      started_at: started,
      updated_at: run.updated_at || started,
      elapsed_ms: DateTime.diff(now, started, :millisecond) |> max(0),
      title: title(cluster, count),
      segs: segments(phases, current, run.status, count, live, done, wf)
    }
  end

  defp title([%{wf: wf, run: run} | _], 1), do: "#{wf.display_name} — #{run.status}"

  defp title(cluster, _count),
    do: cluster |> Enum.map_join(", ", & &1.wf.display_name) |> then(&"interrupted: #{&1}")

  @doc "The phases a run draws; a run with none still gets one segment."
  @spec phases(map()) :: [String.t()]
  def phases(%{phases: phases}) when is_list(phases) and phases != [], do: phases
  def phases(_wf), do: ["Run"]

  defp current_index(_phases, nil), do: nil

  defp current_index(phases, phase), do: Enum.find_index(phases, &(&1 == phase))

  # One segment per phase: filled behind the current one, toned by the run's
  # status at it, hollow ahead of it (spec 64 §3).
  defp segments(phases, current, status, count, live, done, wf) do
    for {phase, index} <- Enum.with_index(phases) do
      cond do
        current && index < current ->
          %{tone: "done", text: phase <> " ✓", title: "#{phase} · done"}

        current == index ->
          current_segment(phase, status, count, live, done, wf)

        true ->
          %{tone: nil, text: phase, title: "#{phase} · pending"}
      end
    end
  end

  defp current_segment(phase, "running", _count, live, done, wf) do
    %{
      tone: "now",
      text: if(live > 0, do: "#{phase} · #{live} live", else: phase),
      title: "#{phase} · #{live} live · #{done} done of #{wf.agents_admitted || 0} admitted"
    }
  end

  defp current_segment(phase, "waiting_user", _count, _live, _done, _wf),
    do: %{tone: "gate", text: phase, title: "#{phase} · waiting at the gate"}

  defp current_segment(phase, "paused", _count, _live, _done, wf),
    do: %{
      tone: "pause",
      text: phase <> " · paused",
      title: "#{phase} · paused: #{wf.pause_message || "no message"}"
    }

  defp current_segment(phase, "interrupted", count, _live, _done, wf) do
    %{
      tone: "int",
      text: phase <> " ⏸" <> if(count > 1, do: " ×#{count}", else: ""),
      title: "#{phase} · interrupted at #{wf.agents_admitted || 0}/#{wf.budget}"
    }
  end

  defp current_segment(phase, _status, _count, _live, _done, _wf),
    do: %{tone: nil, text: phase, title: "#{phase} · pending"}

  ## --------------------------------------------------------------- needs you

  # Every run that is waiting for an answer or parked, in board order — one
  # card each, the gate's question or the pause's message answerable in place.
  defp needs(rows) do
    rows
    |> Enum.filter(&(&1.run.status in @needs))
    |> Enum.sort_by(&{Map.get(@rank, &1.run.status, 9), -unix(&1.run.started_at)})
    |> Enum.map(fn %{wf: wf, run: run} ->
      phases = phases(wf)

      %{
        kind: (run.status == "waiting_user" && :gate) || :paused,
        run_id: wf.run_id,
        name: wf.display_name,
        status: run.status,
        phase: wf.phase,
        phase_index: current_index(phases, wf.phase),
        phase_count: length(phases),
        admitted: wf.agents_admitted || 0,
        budget: wf.budget,
        cost: run.cost_usd,
        question: wf.gate_question || wf.pause_message || "Waiting for you.",
        options: wf.gate_options || [],
        pause_kind: wf.pause_kind,
        pause_message: wf.pause_message,
        updated_at: run.updated_at || run.started_at
      }
    end)
  end

  ## ----------------------------------------------------------- library stats

  # `%{{scope, name} => %{runs, ok_pct, last, unfinished}}`. Runs launched
  # adhoc (no `definition_name`) are counted nowhere, as spec 64 §Data asks.
  defp stats(history, rows) do
    unfinished =
      rows
      |> Enum.sort_by(&Map.get(@rank, &1.run.status, 9))
      |> Enum.reduce(%{}, fn %{wf: wf, run: run}, acc ->
        case wf.definition_name do
          nil ->
            acc

          name ->
            Map.put_new(acc, {wf.scope, name}, %{
              run_id: wf.run_id,
              display_name: wf.display_name,
              status: run.status
            })
        end
      end)

    history
    |> Enum.group_by(&{&1.scope, &1.name})
    |> Map.new(fn {key, rows} ->
      done = Enum.count(rows, &(&1.status == "done"))
      bad = Enum.count(rows, &(&1.status in ["failed", "stopped"]))
      last = Enum.find(rows, &(&1.status in @finished))

      {key,
       %{
         runs: length(rows),
         ok_pct: if(done + bad > 0, do: round(done * 100 / (done + bad))),
         last:
           last &&
             %{
               run_id: last.run_id,
               display_name: last.display_name,
               status: last.status,
               at: last.started_at
             },
         unfinished: Map.get(unfinished, key)
       }}
    end)
    |> merge_unfinished_only(unfinished)
  end

  # A definition whose only run is still going has no history row of its own.
  defp merge_unfinished_only(stats, unfinished) do
    Enum.reduce(unfinished, stats, fn {key, row}, acc ->
      Map.put_new(acc, key, %{runs: 0, ok_pct: nil, last: nil, unfinished: row})
    end)
  end

  ## ------------------------------------------------------------- the library

  @doc """
  The Library's groups: `Built-in`, then one per project that owns a
  definition (alphabetical), then `Personal` (spec 64 §5). Empty groups are
  dropped rather than drawn.
  """
  @spec groups([map()], [map()]) :: [{String.t(), [map()]}]
  def groups(definitions, projects) do
    by_scope = Enum.group_by(definitions, & &1.scope)

    owned =
      by_scope
      |> Map.get("project", [])
      |> Enum.group_by(&Map.get(&1, :project_id))
      |> Enum.map(fn {id, defs} -> {project_label(projects, id), defs} end)
      |> Enum.sort_by(fn {label, _defs} -> String.downcase(label) end)

    ([{"Built-in", Map.get(by_scope, "builtin", [])}] ++
       owned ++ [{"Personal", Map.get(by_scope, "user", [])}])
    |> Enum.reject(fn {_label, defs} -> defs == [] end)
  end

  defp project_label(_projects, nil), do: "Project"

  defp project_label(projects, id) do
    case Enum.find(projects, &(&1.id == id)) do
      nil -> "Project"
      project -> project.name
    end
  end

  defp project_name(projects, %{project_id: id}) when is_binary(id) do
    case Enum.find(projects, &(&1.id == id)) do
      nil -> "—"
      project -> project.name
    end
  end

  defp project_name(_projects, _conversation), do: "—"

  ## ------------------------------------------------------------- the footer

  # The next enabled scheduled task that launches a workflow, with the schedule
  # in the footer's shorthand and the warning the launch would earn.
  defp next_task(tasks, definitions, scope) do
    tasks
    |> Enum.filter(&(&1.enabled and &1.kind == "workflow" and &1.next_run_at))
    |> Enum.min_by(&DateTime.to_unix(&1.next_run_at), fn -> nil end)
    |> case do
      nil ->
        nil

      task ->
        %{
          task: task,
          schedule: schedule_short(task),
          will_fail: will_fail(task, definitions, scope)
        }
    end
  end

  @doc """
  The footer's schedule shorthand: `daily 02:00`, `weekly Thu 09:00`,
  `monthly 1st`, `once Sep 12 14:00`, or the cron as it is.
  """
  @spec schedule_short(map()) :: String.t()
  def schedule_short(%{schedule_kind: "daily"} = task), do: "daily #{task.time_of_day}"

  def schedule_short(%{schedule_kind: "weekly"} = task) do
    days =
      (task.weekdays || [])
      |> Enum.sort()
      |> Enum.map_join(" ", &Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), &1 - 1))

    String.trim("weekly #{days} #{task.time_of_day}")
  end

  def schedule_short(%{schedule_kind: "monthly"} = task),
    do: "monthly #{ordinal(task.day_of_month)}"

  def schedule_short(%{schedule_kind: "once", run_at: %DateTime{} = at} = task) do
    case DateTime.shift_zone(at, task.timezone || "Etc/UTC") do
      {:ok, local} -> "once " <> Calendar.strftime(local, "%b %-d %H:%M")
      _ -> "once " <> Calendar.strftime(at, "%b %-d %H:%M")
    end
  end

  def schedule_short(%{schedule_kind: "cron", cron: cron}) when is_binary(cron), do: cron
  def schedule_short(_task), do: "scheduled"

  defp ordinal(nil), do: "1st"
  defp ordinal(n) when n in [1, 21, 31], do: "#{n}st"
  defp ordinal(n) when n in [2, 22], do: "#{n}nd"
  defp ordinal(n) when n in [3, 23], do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  # A task whose project is out of the switcher's scope is not judged: the
  # definitions assign cannot see that project's `.swarm_code/workflows`, and
  # "no workflow named …" would be a lie.
  defp will_fail(%{workflow_name: nil}, _definitions, _scope), do: nil

  defp will_fail(task, definitions, scope) do
    if covered?(task, scope) do
      case Enum.find(definitions, &visible?(&1, task)) do
        nil ->
          %{reason: "no workflow named #{task.workflow_name}", scope: nil, name: nil}

        %{problems: [_ | _]} = definition ->
          %{
            reason: "#{task.workflow_name} has a smoke problem — edit it",
            scope: definition.scope,
            name: definition.name
          }

        _ok ->
          nil
      end
    end
  end

  defp covered?(%{project_id: nil}, _scope), do: true
  defp covered?(_task, "all"), do: true
  defp covered?(%{project_id: id}, scope), do: id == scope

  defp visible?(definition, task) do
    definition.name == task.workflow_name and
      (definition.scope != "project" or Map.get(definition, :project_id) == task.project_id)
  end

  ## ------------------------------------------------------------ local clocks

  # Monday 00:00 and the first of the month, local, as UTC instants — the same
  # shape `Scheduled.Sidebar` cuts its days on.
  defp monday(now, zone) do
    local = shift(now, zone)
    date = Date.add(DateTime.to_date(local), -(Date.day_of_week(local) - 1))
    utc(date, zone)
  end

  defp month_start(now, zone) do
    now |> shift(zone) |> DateTime.to_date() |> Date.beginning_of_month() |> utc(zone)
  end

  defp utc(date, zone) do
    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp unix(_none), do: 0

  defp shift(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _ -> at
    end
  end
end
