defmodule SwarmCode.Domain.Scheduled.Sidebar do
  @moduledoc """
  Everything the Scheduled page's sidebar draws, derived once per change
  instead of once per render (spec 63 §Data).

  `build/2` answers the whole panel — the four KPI tiles, the live cards, a
  fortnight strip and a streak per task, the project groups, the next
  occurrence — out of three queries:

    1. every `scheduled_runs` row of the last 14 days *plus* every row that is
       still live whatever its age (strips, streaks, the week KPI, the NOW
       cards);
    2. this month's spend of the conversations the scheduler opened;
    3. the `nodes` of the live runs (ops, files changed, progress).

  `today_count` and `month_total` are the calendar's own numbers and are passed
  in rather than computed a second time.
  """

  import Ecto.Query

  alias SwarmCode.Domain.Conversations.{Node, Run, Conversation}
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Scheduled.Run, as: ScheduledRun
  alias SwarmCode.Domain.Scheduler.Next

  @days 14
  # What `Scheduled.statuses/1` calls running; `claimed` is an occurrence the
  # scheduler has taken but not started, so it colours the strip without
  # earning a NOW card.
  @live ~w(running paused waiting_user)
  @pending ["claimed" | @live]
  @live_cap 3

  @type t :: %{
          kpis: map(),
          live: [map()],
          strips: %{optional(binary()) => [map()]},
          streaks: %{optional(binary()) => map()},
          groups: [{String.t(), [map()]}],
          next_run: DateTime.t() | nil,
          month_total: non_neg_integer(),
          zone: String.t()
        }

  @doc """
  The sidebar's whole state for `tasks`.

  Options: `:now` (defaults to `DateTime.utc_now/0`), `:zone` (the local zone
  the strip's days are cut on), `:today_count` and `:month_total`.
  """
  @spec build([map()], keyword()) :: t()
  def build(tasks, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    zone = Keyword.get(opts, :zone) || Next.local_zone()
    today = now |> shift(zone) |> DateTime.to_date()
    rows = window_rows(now)
    by_task = Enum.group_by(rows, & &1.task_id)
    live = live_cards(rows, tasks, now, zone)

    %{
      kpis: kpis(rows, now, zone, Keyword.get(opts, :today_count, 0)),
      live: live,
      strips: Map.new(tasks, &{&1.id, strip(Map.get(by_task, &1.id, []), today, zone)}),
      streaks: tasks |> Enum.map(&{&1.id, streak(Map.get(by_task, &1.id, []))}) |> drop_nils(),
      groups: groups(tasks),
      next_run: next_run(tasks),
      month_total: Keyword.get(opts, :month_total, 0),
      zone: zone
    }
  end

  ## ------------------------------------------------------------- the queries

  # Query 1. The OR keeps a long-running occurrence visible even when it was
  # scheduled before the window — a NOW card that vanished at 14 days would be
  # worse than a full scan of a table this small.
  defp window_rows(now) do
    since = DateTime.add(now, -@days * 86_400, :second)

    from(r in ScheduledRun,
      left_join: c in Conversation,
      on: c.id == r.conversation_id,
      where: r.scheduled_for >= ^since or r.status in ^@live,
      order_by: [desc: r.scheduled_for],
      select: %{
        task_id: r.task_id,
        status: r.status,
        scheduled_for: r.scheduled_for,
        started_at: r.started_at,
        run_id: r.run_id,
        conversation_id: c.id
      }
    )
    |> Repo.all()
  end

  # Query 2. The same shape as `Conversations`' month cost, narrowed to the
  # conversations the scheduler opened (spec 63 §2).
  defp month_spend(now) do
    first =
      now
      |> DateTime.to_date()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    scheduled =
      from(s in ScheduledRun, where: not is_nil(s.conversation_id), select: s.conversation_id)

    from(r in Run,
      where: r.started_at >= ^first and r.conversation_id in subquery(scheduled),
      select: sum(r.cost_usd)
    )
    |> Repo.one()
    |> then(&((&1 && &1 * 1.0) || 0.0))
  end

  # Query 3. One select over the nodes of every live run: the op rows carry the
  # count and the written paths, the lead agent carries the progress bar.
  defp live_nodes([]), do: %{}

  defp live_nodes(run_ids) do
    from(n in Node,
      where: n.run_id in ^run_ids,
      select: %{
        run_id: n.run_id,
        kind: n.kind,
        op_type: n.op_type,
        title: n.title,
        role: n.role,
        depth: n.depth,
        progress: n.progress
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.run_id)
  end

  ## ------------------------------------------------------------------- KPIs

  defp kpis(rows, now, zone, today_count) do
    monday = monday(now, zone)
    week = Enum.filter(rows, &(DateTime.compare(&1.scheduled_for, monday) != :lt))
    # A claimed occurrence has not run yet — it is the queued row of spec 63 §2.
    week = Enum.reject(week, &(&1.status == "claimed"))
    done = Enum.count(week, &(&1.status == "done"))
    failed = Enum.count(week, &(&1.status == "failed"))

    %{
      today: today_count,
      week: length(week),
      ok: if(done + failed > 0, do: round(done * 100 / (done + failed))),
      spend: month_spend(now)
    }
  end

  # Monday 00:00 in the local zone, as a UTC instant.
  defp monday(now, zone) do
    local = shift(now, zone)
    date = Date.add(DateTime.to_date(local), -(Date.day_of_week(local) - 1))

    case DateTime.new(date, ~T[00:00:00], zone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:gap, _, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  ## --------------------------------------------------------------- NOW cards

  defp live_cards(rows, tasks, now, zone) do
    index = Map.new(tasks, &{&1.id, &1})

    running =
      rows
      |> Enum.filter(&(&1.status in @live and Map.has_key?(index, &1.task_id)))
      |> Enum.sort_by(&(&1.started_at || &1.scheduled_for), {:desc, DateTime})
      |> Enum.take(@live_cap)

    nodes = running |> Enum.map(& &1.run_id) |> Enum.reject(&is_nil/1) |> live_nodes()

    Enum.map(running, fn row ->
      own = Map.get(nodes, row.run_id, [])
      ops = Enum.filter(own, &(&1.kind == "op"))
      started = row.started_at || row.scheduled_for

      %{
        task: Map.fetch!(index, row.task_id),
        conversation_id: row.conversation_id,
        started_at: started,
        elapsed: DateTime.diff(now, started) |> max(0),
        started_hm: hm(started, zone),
        ops: length(ops),
        files: ops |> Enum.flat_map(&written/1) |> Enum.uniq() |> length(),
        progress: progress(own)
      }
    end)
  end

  # `touched_files/2` (swarm_pane.ex) reads the same title — "Write lib/a.ex".
  defp written(%{op_type: type, title: title}) when type in ["write_file", "edit_file"] do
    case title |> to_string() |> String.split(" ", parts: 2) do
      [_verb, path] -> [path]
      _ -> []
    end
  end

  defp written(_op), do: []

  defp progress(nodes) do
    nodes
    |> Enum.filter(&(&1.kind == "agent" and (&1.role == "lead" or &1.depth == 0)))
    |> Enum.map(&(&1.progress || 0))
    |> Enum.max(fn -> 0 end)
  end

  ## ------------------------------------------------------ strips and streaks

  @doc "The 14 calendar days the strip paints, oldest first."
  @spec days :: pos_integer()
  def days, do: @days

  # One cell per day, oldest left, tinted by that day's LAST run.
  defp strip(rows, today, zone) do
    by_day =
      Enum.group_by(rows, fn row -> row.scheduled_for |> shift(zone) |> DateTime.to_date() end)

    for offset <- (@days - 1)..0//-1 do
      date = Date.add(today, -offset)

      tone =
        by_day
        |> Map.get(date, [])
        |> Enum.max_by(& &1.scheduled_for, DateTime, fn -> nil end)
        |> tone()

      %{date: date, tone: tone}
    end
  end

  defp tone(nil), do: nil
  defp tone(%{status: "done"}), do: "d"
  defp tone(%{status: "skipped"}), do: "s"
  defp tone(%{status: "failed"}), do: "f"
  defp tone(%{status: status}) when status in @pending, do: "l"
  defp tone(_row), do: nil

  @doc "`14 days · 9 done · 2 skipped · 1 failed` — the strip's tooltip."
  @spec strip_title([map()]) :: String.t()
  def strip_title(cells) do
    counts = Enum.frequencies_by(cells, & &1.tone)

    [{"d", "done"}, {"s", "skipped"}, {"f", "failed"}]
    |> Enum.flat_map(fn {tone, word} ->
      case Map.get(counts, tone, 0) do
        0 -> []
        n -> ["#{n} #{word}"]
      end
    end)
    |> then(&Enum.join(["#{@days} days" | &1], " · "))
  end

  # Two or more finished runs in a row with the same bad outcome. Live and
  # claimed occurrences are skipped over, not counted — a task that is running
  # right now has still skipped its last two slots.
  defp streak(rows) do
    finished = Enum.reject(rows, &(&1.status in @pending))

    case finished do
      [%{status: status} | _] when status in ["skipped", "failed"] ->
        n = Enum.count(Enum.take_while(finished, &(&1.status == status)))

        if n >= 2 do
          %{n: n, status: status, conversation_id: Enum.find_value(rows, & &1.conversation_id)}
        end

      _ ->
        nil
    end
  end

  defp drop_nils(pairs) do
    for {id, value} <- pairs, value != nil, into: %{}, do: {id, value}
  end

  ## ------------------------------------------------------- groups and footer

  @doc """
  Every project that owns a task, by name, then `GLOBAL` for the project-less
  ones — the panel is project-agnostic, unlike the chat sidebar's section
  (spec 63 §5).
  """
  @spec groups([map()]) :: [{String.t(), [map()]}]
  def groups(tasks) do
    {globals, owned} = Enum.split_with(tasks, &(project_name(&1) == nil))

    owned
    |> Enum.group_by(&project_name/1)
    |> Enum.sort_by(fn {name, _rows} -> String.downcase(name) end)
    |> Kernel.++(if globals == [], do: [], else: [{"GLOBAL", globals}])
  end

  # A task whose project row is gone joins GLOBAL rather than a nameless group.
  defp project_name(%{project: %{name: name}}) when is_binary(name), do: name
  defp project_name(_task), do: nil

  defp next_run(tasks) do
    tasks
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.next_run_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp hm(%DateTime{} = at, zone), do: at |> shift(zone) |> Calendar.strftime("%H:%M")

  defp shift(%DateTime{} = at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> local
      _ -> at
    end
  end
end
