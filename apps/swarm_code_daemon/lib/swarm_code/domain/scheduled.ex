defmodule SwarmCode.Domain.Scheduled do
  @moduledoc """
  Scheduled tasks: CRUD, the calendar queries and the one place that actually
  starts a conversation for a task (`run_task/2`, also used by the scheduler).
  """

  # `update/2` here is the context function, not the query macro.
  import Ecto.Query, except: [update: 2, update: 3]
  require Logger

  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.Engine
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Scheduled.{Run, Task}
  alias SwarmCode.Domain.Scheduler.Next

  @topic "scheduled"

  def topic, do: @topic

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, @topic)

  def broadcast(event \\ :scheduled_changed),
    do: SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, @topic, event)

  ## queries

  @spec list() :: [Task.t()]
  def list do
    Task
    |> order_by([t], asc: is_nil(t.next_run_at), asc: t.next_run_at, asc: t.name)
    |> preload(:project)
    |> Repo.all()
  end

  def get(id) do
    case Repo.get(Task, id) do
      nil -> nil
      task -> Repo.preload(task, :project)
    end
  end

  def get!(id), do: Task |> Repo.get!(id) |> Repo.preload(:project)

  @doc "Enabled tasks whose next run is in the future, soonest first."
  @spec upcoming(pos_integer()) :: [Task.t()]
  def upcoming(limit \\ 8) do
    now = DateTime.utc_now()

    Task
    |> where([t], t.enabled == true and not is_nil(t.next_run_at) and t.next_run_at >= ^now)
    |> order_by([t], asc: t.next_run_at)
    |> limit(^limit)
    |> preload(:project)
    |> Repo.all()
  end

  @doc "Tasks whose `next_run_at` has passed (and are still enabled)."
  @spec due(DateTime.t()) :: [Task.t()]
  def due(now \\ DateTime.utc_now()) do
    Task
    |> where([t], t.enabled == true and not is_nil(t.next_run_at) and t.next_run_at <= ^now)
    |> order_by([t], asc: t.next_run_at)
    |> preload(:project)
    |> Repo.all()
  end

  @doc "Every scheduled run whose `scheduled_for` falls inside the given month."
  @spec runs_for_month(integer(), integer()) :: [Run.t()]
  def runs_for_month(year, month) do
    first = Date.new!(year, month, 1)
    last = Date.add(first, Date.days_in_month(first))
    from_dt = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(last, ~T[00:00:00], "Etc/UTC")

    Run
    |> where([r], r.scheduled_for >= ^from_dt and r.scheduled_for < ^to_dt)
    |> order_by([r], desc: r.scheduled_for)
    |> Repo.all()
  end

  @doc """
  Every scheduled run that has not settled yet — including the paused and
  waiting ones, so reconciliation can still move them to a terminal state.
  """
  @spec unsettled_runs() :: [Run.t()]
  def unsettled_runs do
    Run
    |> where([r], r.status in ^["running", "paused", "waiting_user"] and not is_nil(r.run_id))
    |> Repo.all()
  end

  @spec runs_for_task(String.t(), pos_integer()) :: [Run.t()]
  def runs_for_task(task_id, limit \\ 5) do
    Run
    |> where([r], r.task_id == ^task_id)
    |> order_by([r], desc: r.scheduled_for)
    |> limit(^limit)
    |> Repo.all()
  end

  # spec 56 T2: the sidebar's task nodes — the newest six runs of every task
  # in one window-ranked select, and the run count in one grouped select.
  @doc "The newest `limit` runs of every task in `task_ids`, newest first (spec 56 T2)."
  @spec recent_runs_by_task([binary()], pos_integer()) :: %{binary() => [map()]}
  def recent_runs_by_task([], _limit), do: %{}

  def recent_runs_by_task(task_ids, limit) when is_list(task_ids) do
    ranked =
      from(r in Run,
        where: r.task_id in ^task_ids,
        left_join: c in Conversation,
        on: c.id == r.conversation_id,
        windows: [w: [partition_by: r.task_id, order_by: [desc: r.scheduled_for]]],
        select: %{
          task_id: r.task_id,
          run_id: r.run_id,
          conversation_id: r.conversation_id,
          title: c.title,
          status: r.status,
          scheduled_for: r.scheduled_for,
          started_at: r.started_at,
          rank: over(row_number(), :w)
        }
      )

    from(x in subquery(ranked),
      where: x.rank <= ^limit,
      order_by: [asc: x.task_id, desc: x.scheduled_for]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.task_id, &Map.drop(&1, [:task_id, :rank]))
  end

  @doc "How many runs every task in `task_ids` has ever had (spec 56 T2)."
  @spec run_counts([binary()]) :: %{binary() => non_neg_integer()}
  def run_counts([]), do: %{}

  def run_counts(task_ids) when is_list(task_ids) do
    Run
    |> where([r], r.task_id in ^task_ids)
    |> group_by([r], r.task_id)
    |> select([r], {r.task_id, count(r.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The sidebar status of every task (spec 08 §22): `:paused` when it is
  disabled, `:running` while its newest run is going, `:failed` when that run
  failed, `:next` otherwise.
  """
  @spec statuses([Task.t()]) :: %{binary() => :paused | :running | :failed | :next}
  def statuses(tasks) when is_list(tasks) do
    ids = Enum.map(tasks, & &1.id)

    latest =
      Run
      |> where([r], r.task_id in ^ids)
      |> order_by([r], asc: r.task_id, desc: r.scheduled_for)
      |> select([r], {r.task_id, r.status})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {id, status}, acc -> Map.put_new(acc, id, status) end)

    Map.new(tasks, fn task ->
      status =
        cond do
          not task.enabled -> :paused
          Map.get(latest, task.id) in ["running", "paused", "waiting_user"] -> :running
          Map.get(latest, task.id) == "failed" -> :failed
          true -> :next
        end

      {task.id, status}
    end)
  end

  def statuses(_tasks), do: %{}

  @doc "The dates inside `first..last` on which `task` fires (max 62)."
  defdelegate occurrences(task, first, last), to: Next

  ## writes

  def change(%Task{} = task, attrs \\ %{}), do: Task.changeset(task, attrs)

  def create(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> put_next_run()
    |> Repo.insert()
    |> announce()
  end

  def update(%Task{} = task, attrs) do
    task
    |> Task.changeset(attrs)
    |> put_next_run()
    |> Repo.update()
    |> announce()
  end

  def delete(%Task{} = task), do: task |> Repo.delete() |> announce()

  @doc "Flips `enabled` and recomputes (or clears) the next run."
  def toggle(%Task{} = task), do: update(task, %{enabled: not task.enabled})

  defp put_next_run(changeset) do
    if changeset.valid? do
      task = Ecto.Changeset.apply_changes(changeset)
      Ecto.Changeset.put_change(changeset, :next_run_at, Next.next_run(task, DateTime.utc_now()))
    else
      changeset
    end
  end

  defp announce({:ok, _} = result) do
    broadcast()
    result
  end

  defp announce(other), do: other

  ## running

  @doc """
  Starts the task right now, off-schedule. The stored schedule is untouched
  apart from `last_run_at`.
  """
  @spec run_now(Task.t()) :: {:ok, Run.t()} | {:error, term()}
  def run_now(%Task{} = task) do
    task
    |> next_manual_occurrence(DateTime.utc_now() |> DateTime.truncate(:second))
    |> run_manual(task)
  end

  # Manual launches still use the second-precision occurrence key required by
  # the scheduler. If several clicks land in the same second, move forward to
  # the next unclaimed second. Never borrow the task's scheduled slot: a timer
  # racing this call must remain free to claim its exact occurrence.
  defp run_manual(scheduled_for, task) do
    case claim(task, scheduled_for) do
      {:error, :already_claimed} ->
        task
        |> next_manual_occurrence(DateTime.add(scheduled_for, 1, :second))
        |> run_manual(task)

      {:ok, claimed} ->
        launch_claimed(task, scheduled_for, [reschedule: false], claimed)
    end
  end

  defp next_manual_occurrence(%Task{} = task, candidate) do
    scheduled_slot =
      case Repo.get(Task, task.id) do
        %Task{next_run_at: next_run_at} -> next_run_at
        nil -> task.next_run_at
      end

    if same_second?(candidate, scheduled_slot) do
      next_manual_occurrence(task, DateTime.add(candidate, 1, :second))
    else
      candidate
    end
  end

  # spec 60 T39: public for the Scheduler's queued `{:fire, id, scheduled_for}`.
  @doc false
  # pass54: a task whose `next_run_at` is nil (disabled, one-shot already run)
  # matched nothing — but the nil was the FIRST argument and crashed the
  # Scheduler on every boot-queued fire.
  def same_second?(nil, _scheduled_slot), do: false
  def same_second?(_candidate, nil), do: false

  def same_second?(candidate, scheduled_slot) do
    DateTime.compare(
      DateTime.truncate(candidate, :second),
      DateTime.truncate(scheduled_slot, :second)
    ) == :eq
  end

  @doc """
  Fires `task` for the occurrence `scheduled_for`: opens a conversation, starts
  the chat turn or the swarm, records a `scheduled_run` and (unless
  `reschedule: false`) moves `next_run_at` on.
  """
  @spec run_task(Task.t(), DateTime.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run_task(%Task{} = task, scheduled_for, opts \\ []) do
    case claim(task, scheduled_for) do
      {:error, :already_claimed} = error ->
        # spec 60 T39: the occurrence was launched and settled but its `bump/3`
        # was lost to a busy database, so the task still points at it. Move the
        # schedule on now — `claim/2` never launches it twice.
        case Repo.get_by(Run,
               task_id: task.id,
               scheduled_for: DateTime.truncate(scheduled_for, :second)
             ) do
          %Run{status: s} when s != "claimed" ->
            if same_second?(task.next_run_at, scheduled_for), do: bump(task, scheduled_for, opts)

          _ ->
            :ok
        end

        error

      {:ok, claimed} ->
        launch_claimed(task, scheduled_for, opts, claimed)
    end
  end

  # Spec 33 §1: a claimed occurrence must reach a terminal status whatever the
  # launch does. It used to be a flat `with`, so a *raise* anywhere inside it
  # skipped both the settlement and the `bump`: the row stayed `claimed`,
  # `next_run_at` never moved, and every later tick re-claimed the same second
  # and got `:already_claimed`. That task never fired again.
  defp launch_claimed(task, scheduled_for, opts, claimed) do
    case safely(fn -> launch(task, scheduled_for, claimed) end) do
      {:ok, conversation, scheduled_run} ->
        # spec 60 T39: a busy bump must not raise past a settled launch; the next
        # tick's `run_task/3` re-bumps when it meets the settled occurrence.
        case bump(task, scheduled_for, opts) do
          {:ok, _} ->
            :ok

          other ->
            Logger.warning(
              "swarm_code scheduled #{task.id}: could not move the schedule: #{inspect(other)}"
            )
        end

        announce_start(task, conversation)
        broadcast()
        {:ok, scheduled_run}

      {:error, reason} ->
        # Whatever the launch managed to start belongs to nobody now.
        stop_staged_runs(claimed)
        {:ok, _} = record_failure(claimed, reason)
        bump(task, scheduled_for, opts)
        broadcast()
        {:error, reason}
    end
  end

  defp launch(task, scheduled_for, claimed) do
    with {:ok, conversation} <- open_conversation(task, scheduled_for),
         :ok <- launch_step(:conversation),
         {:ok, _staged} <- stage(claimed, conversation),
         {:ok, run_id} <- start(task, conversation),
         :ok <- launch_step(:engine),
         {:ok, scheduled_run} <- settle(claimed, {:ok, run_id}) do
      {:ok, conversation, scheduled_run}
    end
  end

  # A test-only fault injector, the same shape as `:engine_run_starter`. In
  # production it is one `Application.get_env/2` per phase and nothing else.
  defp launch_step(stage) do
    case Application.get_env(:swarm_code_daemon, :scheduled_launch_step) do
      fun when is_function(fun, 1) -> fun.(stage)
      _none -> :ok
    end
  end

  # The conversation is written onto the claim *before* the engine starts, so a
  # failure — or a restart — can still find the work it has to stop.
  defp stage(%Run{} = claimed, conversation) do
    claimed |> Run.changeset(%{conversation_id: conversation.id}) |> Repo.update()
  end

  defp stop_staged_runs(%Run{} = claimed) do
    case Repo.get(Run, claimed.id) do
      %Run{conversation_id: conversation_id} when is_binary(conversation_id) ->
        Engine.stop_all(conversation_id)

      _other ->
        :ok
    end

    :ok
  end

  # A notification that blows up must not turn a running occurrence into a
  # failed one.
  defp announce_start(task, conversation) do
    safely(fn ->
      SwarmCode.Domain.Notifications.notify("Scheduled task started: #{task.name}")

      # Never navigate the user away — the UI shows a toast instead (spec 08 §8).
      broadcast(
        {:scheduled_started,
         %{task_id: task.id, name: task.name, conversation_id: conversation.id}}
      )

      :ok
    end)

    :ok
  end

  # Every way a launch can end badly, as one value.
  defp safely(fun) do
    case fun.() do
      {:error, reason} -> {:error, reason}
      other -> other
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :throw, value -> {:error, {:throw, value}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Settles occurrences left `claimed` by a runtime that went away mid-launch.

  Idempotent: the status change is conditional, so a second pass changes no row,
  stops no run, logs nothing and moves no schedule.
  """
  @spec reconcile_claimed() :: {:ok, non_neg_integer()}
  # spec 60 T38: arity 0 is the boot sweep (Bootstrap) — a dead runtime abandoned everything.
  def reconcile_claimed(), do: reconcile_claimed(DateTime.utc_now(), 0)

  @doc """
  The tick form: a claim younger than `min_age_s` belongs to a launch that is
  still settling (a manual `run_now/1` in the LiveView process) and is left alone.
  """
  @spec reconcile_claimed(DateTime.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def reconcile_claimed(now, min_age_s \\ 90) do
    cutoff = DateTime.add(now, -min_age_s, :second)

    stale =
      Run
      |> where([r], r.status == "claimed" and r.inserted_at < ^cutoff)
      |> order_by([r], asc: r.scheduled_for, asc: r.id)
      |> Repo.all()

    settled = Enum.count(stale, &settle_interrupted(&1, now))
    if settled > 0, do: broadcast()
    {:ok, settled}
  end

  defp settle_interrupted(%Run{} = row, now) do
    # Stop first: the row is the only record of what was started.
    stop_staged_runs(row)

    {changed, _} =
      Run
      |> where([r], r.id == ^row.id and r.status == "claimed")
      |> Repo.update_all(set: [status: "failed", updated_at: DateTime.utc_now()])

    if changed == 1 do
      Logger.warning("scheduled occurrence #{row.id}: interrupted before launch settlement")

      advance_interrupted(row, now)
      true
    else
      false
    end
  end

  # Only when the task is still pointing at this occurrence: a manual run, or a
  # schedule the user has since changed, keeps its own slot.
  defp advance_interrupted(%Run{} = row, now) do
    case Repo.get(Task, row.task_id) do
      %Task{next_run_at: next_run_at} = task ->
        if same_second?(next_run_at, row.scheduled_for), do: bump(task, now, [])

      nil ->
        :ok
    end

    :ok
  end

  @doc "Atomically claims one occurrence before any launch side effect."
  @spec claim(Task.t(), DateTime.t()) :: {:ok, Run.t()} | {:error, :already_claimed}
  def claim(%Task{} = task, scheduled_for) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      id: id,
      task_id: task.id,
      scheduled_for: DateTime.truncate(scheduled_for, :second),
      status: "claimed",
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(Run, [attrs],
           on_conflict: :nothing,
           conflict_target: [:task_id, :scheduled_for]
         ) do
      {1, _} -> {:ok, Repo.get!(Run, id)}
      {0, _} -> {:error, :already_claimed}
    end
  end

  @doc "Settles a previously claimed occurrence after launch succeeds or fails."
  @spec settle(Run.t(), {:ok, String.t()} | {:error, term()}) :: {:ok, Run.t()}
  def settle(%Run{} = claimed, {:ok, run_id}) do
    engine_run = Conversations.get_run(run_id)

    claimed
    |> Run.changeset(%{
      run_id: run_id,
      conversation_id: engine_run && engine_run.conversation_id,
      started_at: DateTime.utc_now(),
      status: "running"
    })
    |> Repo.update()
  end

  def settle(%Run{} = claimed, {:error, reason}) do
    Logger.warning(
      "scheduled occurrence failed: #{SwarmCode.Domain.LLM.HTTP.redact(inspect(reason))}"
    )

    claimed |> Run.changeset(%{status: "failed"}) |> Repo.update()
  end

  @doc "Marks the occurrence as skipped and moves the schedule on."
  @spec skip(Task.t(), DateTime.t()) :: :ok
  def skip(%Task{} = task, scheduled_for) do
    case claim(task, scheduled_for) do
      {:ok, claimed} ->
        claimed |> Run.changeset(%{status: "skipped"}) |> Repo.update()
        bump(task, scheduled_for, [])
        broadcast()

      {:error, :already_claimed} ->
        :ok
    end

    :ok
  end

  @doc "Copies a finished engine run's outcome onto its scheduled run, if any."
  @spec finish(String.t(), String.t()) :: :ok
  def finish(run_id, status) when is_binary(run_id) do
    status = if status in ["done", "failed"], do: status, else: "failed"
    set_status(run_id, status)
  end

  @doc """
  Mirrors a non-terminal engine status onto the scheduled run (sakana task 8).
  No `finished_at` is written — the run has not finished.
  """
  @spec set_status(String.t(), String.t()) :: :ok
  def set_status(run_id, status) when is_binary(run_id) do
    status = if status in Run.statuses(), do: status, else: "failed"

    Run
    |> where([r], r.run_id == ^run_id)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now()])

    broadcast()
    :ok
  end

  defp bump(task, scheduled_for, opts) do
    now = DateTime.utc_now()

    next =
      if Keyword.get(opts, :reschedule, true) do
        # Compute from the occurrence we just fired so a late catch-up does not
        # swallow the following one.
        from = if DateTime.compare(scheduled_for, now) == :gt, do: scheduled_for, else: now
        Next.next_run(task, from)
      else
        task.next_run_at
      end

    # spec 60 T39
    Repo.retry(:scheduled_bump, fn ->
      task
      |> Ecto.Changeset.change(%{last_run_at: DateTime.truncate(now, :second), next_run_at: next})
      |> Repo.update()
    end)
  end

  defp record_failure(%Run{} = claimed, reason), do: settle(claimed, {:error, reason})

  defp open_conversation(task, scheduled_for) do
    with {:ok, conversation} <- Conversations.create(task.project_id) do
      attrs =
        %{
          title: title(task, scheduled_for),
          mode: task.mode || "build",
          scheduled_task_id: task.id
        }
        |> Map.merge(model_attrs(task))

      Conversations.update(conversation, attrs)
    end
  end

  @doc """
  The model a task runs with (spec 08 §7): its own, else the scheduled default
  of the settings, else nothing — in which case the conversation falls back to
  the chat default like any other conversation.
  """
  def model_attrs(task, settings \\ nil) do
    settings = settings || SwarmCode.Domain.Settings.get()

    {provider_id, model, effort} =
      cond do
        task.provider_id && task.model ->
          {task.provider_id, task.model, task.effort || settings.default_scheduled_effort}

        settings.default_scheduled_provider_id && settings.default_scheduled_model ->
          {settings.default_scheduled_provider_id, settings.default_scheduled_model,
           task.effort || settings.default_scheduled_effort}

        true ->
          {nil, nil, task.effort || settings.default_scheduled_effort}
      end

    %{}
    |> put_unless_nil(:chat_provider_id, provider_id)
    |> put_unless_nil(:chat_model, model)
    |> put_unless_nil(:swarm_provider_id, provider_id)
    |> put_unless_nil(:swarm_model, model)
    |> put_unless_nil(:effort, effort)
    |> put_unless_nil(:swarm_effort, effort)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp title(task, scheduled_for) do
    stamp =
      case DateTime.shift_zone(scheduled_for, task.timezone || "Etc/UTC") do
        {:ok, local} -> Calendar.strftime(local, "%b %-d %H:%M")
        _ -> Calendar.strftime(scheduled_for, "%b %-d %H:%M")
      end

    String.slice("#{task.name} · #{stamp}", 0, 120)
  end

  defp start(%Task{kind: "swarm"} = task, conversation),
    do: Engine.start_swarm(conversation, task.prompt)

  defp start(%Task{kind: "workflow"} = task, conversation) do
    project = SwarmCode.Domain.Projects.get!(conversation.project_id)

    case SwarmCode.Domain.Workflows.get(project, task.workflow_name) do
      nil ->
        {:error, "workflow #{task.workflow_name} not found"}

      definition ->
        attrs = %{
          conversation: conversation,
          project: project,
          definition: definition,
          args: task.workflow_args || %{},
          created_by: "scheduled"
        }

        case SwarmCode.Domain.Workflows.launch(attrs) do
          {:ok, wf} -> {:ok, wf.run_id}
          {:error, {:missing_args, keys}} -> {:error, "missing args: " <> Enum.join(keys, ", ")}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  defp start(task, conversation), do: Engine.start_chat_turn(conversation, task.prompt)
end
