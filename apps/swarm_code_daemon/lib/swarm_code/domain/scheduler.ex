defmodule SwarmCode.Domain.Scheduler do
  @moduledoc """
  Fires scheduled tasks. Ticks every 30 seconds: anything whose `next_run_at`
  has passed is started (or skipped, when it is more than a day late and the
  task does not want catch-ups), and running scheduled runs are reconciled with
  their engine run.
  """

  use GenServer
  require Logger

  alias SwarmCode.Domain.{Conversations, Scheduled}

  @tick :timer.seconds(30)
  # Anything later than this is not worth catching up on after a long shutdown.
  @catch_up_window :timer.hours(24)
  @catch_up_gap :timer.seconds(10)
  # A task fired within this window of its slot counts as "on time".
  @fresh :timer.minutes(2)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one tick synchronously — used by the tests."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @tick)
    state = %{interval: interval, gap: Keyword.get(opts, :gap, @catch_up_gap)}

    if Keyword.get(opts, :catch_up, true), do: send(self(), :boot)
    if interval > 0, do: Process.send_after(self(), :tick, interval)

    {:ok, state}
  end

  @impl true
  def handle_info(:boot, state) do
    reconcile_then_run_due(state.gap)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    reconcile()
    reconcile_then_run_due(0)
    retention()
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  def handle_info({:fire, task_id, scheduled_for}, state) do
    case Scheduled.get(task_id) do
      # spec 60 T39: a boot-queued fire of an occurrence the task no longer points
      # at (edited or already moved on) is stale and runs nothing.
      %{enabled: true} = task ->
        if Scheduled.same_second?(task.next_run_at, scheduled_for),
          do: fire(task, DateTime.utc_now(), scheduled_for)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:tick, _from, state) do
    reconcile()
    reconcile_then_run_due(0)
    retention()
    {:reply, :ok, state}
  end

  # Spec 49 §2: the storage retention sweep. It settles itself — `:skipped`
  # until a policy is set and the last sweep is more than a day old — and it is
  # held off entirely while a VACUUM has the database.
  defp retention do
    unless SwarmCode.Domain.Storage.paused?(), do: SwarmCode.Domain.Storage.apply_retention()
    :ok
  rescue
    error ->
      Logger.warning("swarm_code scheduler: retention failed — #{Exception.message(error)}")
      :ok
  end

  @doc """
  Reconciles the running scheduled runs right now (spec 13 §11 A-7, tests).
  """
  @spec reconcile_now() :: :ok
  def reconcile_now, do: reconcile()

  ## the work

  # Spec 33 §1: a Scheduler that restarts on its own — without Bootstrap — must
  # still clear an interrupted claim before it fires anything, or the claim
  # blocks its task for good. A reconciliation that fails skips this pass; the
  # next tick tries again before starting work.
  defp reconcile_then_run_due(gap) do
    now = DateTime.utc_now()

    case Scheduled.reconcile_claimed(now) do
      {:ok, _count} ->
        run_due(now, gap)

      other ->
        Logger.warning(
          "scheduled reconciliation failed: #{SwarmCode.Domain.LLM.HTTP.redact(inspect(other))}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "scheduled reconciliation failed: #{SwarmCode.Domain.LLM.HTTP.redact(Exception.message(error))}"
      )
  end

  @doc false
  def run_due(now, gap) do
    tasks = Scheduled.due(now)

    if gap == 0 do
      Enum.each(tasks, &fire(&1, now))
    else
      tasks
      |> Enum.with_index()
      |> Enum.each(fn
        {task, 0} ->
          fire(task, now)

        {task, index} ->
          Process.send_after(self(), {:fire, task.id, task.next_run_at || now}, index * gap)
      end)
    end
  end

  # Late by more than a day, or late at all on a task that does not want
  # catch-ups: record a skip and jump to the next occurrence.
  defp fire(task, now) do
    scheduled_for = task.next_run_at || now
    fire(task, now, scheduled_for)
  end

  defp fire(task, now, scheduled_for) do
    late_ms = DateTime.diff(now, scheduled_for, :millisecond)

    if late_ms > @catch_up_window or (not task.catch_up and late_ms > @fresh) do
      Scheduled.skip(task, scheduled_for)
    else
      run(task, scheduled_for)
    end
  end

  defp run(task, scheduled_for) do
    case Scheduled.run_task(task, scheduled_for) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "scheduled task #{task.name} failed: #{SwarmCode.Domain.LLM.HTTP.redact(inspect(reason))}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "scheduled task #{task.name} crashed: #{SwarmCode.Domain.LLM.HTTP.redact(inspect(error))}"
      )

      :error
  end

  # Scheduled runs stay "running" until their engine run reports back.
  #
  # Spec 13 §11 A-7: `"interrupted"` (a workflow run the app restart cut short)
  # and a run that was deleted left the `scheduled_runs` row spinning for ever,
  # and a `stopped` run that was really interrupted was recorded as `done`.
  defp reconcile do
    # spec 60 T42 (spec 55 A14): `finish/2` and `set_status/2` raise on a busy
    # database; a crash here restarts the Scheduler into a `:boot` catch-up.
    for scheduled_run <- Scheduled.unsettled_runs(), scheduled_run.run_id do
      desired = scheduled_status(Conversations.get_run(scheduled_run.run_id))

      cond do
        desired in ["done", "failed"] -> Scheduled.finish(scheduled_run.run_id, desired)
        desired != scheduled_run.status -> Scheduled.set_status(scheduled_run.run_id, desired)
        true -> :ok
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("swarm_code scheduler: reconcile skipped — #{Exception.message(e)}")
      :ok
  end

  @doc """
  The scheduled-run status that mirrors an engine run (sakana task 8). Paused
  and waiting runs are non-terminal and keep saying so; only a truly finished
  run settles.
  """
  @spec scheduled_status(map() | nil) :: String.t()
  def scheduled_status(nil), do: "failed"
  def scheduled_status(%{status: "interrupted"}), do: "failed"
  def scheduled_status(%{status: "failed"}), do: "failed"
  def scheduled_status(%{status: "done"}), do: "done"
  def scheduled_status(%{status: "stopped", interrupted: true}), do: "failed"
  def scheduled_status(%{status: "stopped"}), do: "done"
  def scheduled_status(%{status: "paused"}), do: "paused"
  def scheduled_status(%{status: "waiting_user"}), do: "waiting_user"
  def scheduled_status(_other), do: "running"
end
