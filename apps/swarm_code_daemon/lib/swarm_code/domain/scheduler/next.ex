defmodule SwarmCode.Domain.Scheduler.Next do
  @moduledoc """
  Turns a `%Scheduled.Task{}` into the next UTC instant it should fire.

  All of the recurring kinds are computed in the task's own zone, so a daily
  09:00 task stays at 09:00 across a DST change instead of drifting by an hour.
  """

  alias SwarmCode.Domain.Scheduler.Cron

  @doc "The OS zone name (`/etc/localtime`), or `Etc/UTC` when it cannot be read."
  @spec local_zone() :: String.t()
  def local_zone do
    with tz when is_binary(tz) <- System.get_env("TZ") || read_localtime(),
         {:ok, _} <- DateTime.shift_zone(DateTime.utc_now(), tz) do
      tz
    else
      _ -> "Etc/UTC"
    end
  end

  defp read_localtime do
    case File.read_link("/etc/localtime") do
      {:ok, target} ->
        case String.split(target, "zoneinfo/", parts: 2) do
          [_, zone] -> zone
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  The next fire time (UTC, second precision) strictly after `now`, or `nil` when
  the task can never fire again (a `once` task in the past, a disabled task, or
  an impossible cron expression).
  """
  @spec next_run(map(), DateTime.t()) :: DateTime.t() | nil
  def next_run(task, now \\ DateTime.utc_now())

  def next_run(%{enabled: false}, _now), do: nil

  def next_run(task, now) do
    now = DateTime.truncate(now, :second)

    case task.schedule_kind do
      "once" -> once(task, now)
      "daily" -> recurring(task, now, &daily_candidates/3)
      "weekly" -> recurring(task, now, &weekly_candidates/3)
      "monthly" -> recurring(task, now, &monthly_candidates/3)
      "cron" -> cron(task, now)
      _ -> nil
    end
  end

  defp once(%{run_at: nil}, _now), do: nil

  defp once(%{run_at: at}, now) do
    at = DateTime.truncate(at, :second)
    if DateTime.compare(at, now) == :gt, do: at, else: nil
  end

  defp cron(%{cron: nil}, _now), do: nil

  defp cron(task, now) do
    zone = zone(task)

    with {:ok, local} <- DateTime.shift_zone(now, zone),
         %DateTime{} = next <- Cron.next(task.cron, local),
         {:ok, utc} <- DateTime.shift_zone(next, "Etc/UTC") do
      DateTime.truncate(utc, :second)
    else
      _ -> nil
    end
  end

  # The shared shape: walk candidate local dates forward, take the first whose
  # `time_of_day` lands strictly after `now`.
  defp recurring(task, now, candidates) do
    zone = zone(task)

    with {:ok, time} <- time_of_day(task),
         {:ok, local} <- DateTime.shift_zone(now, zone) do
      today = DateTime.to_date(local)

      candidates.(task, today, 400)
      |> Stream.map(&at_local(&1, time, zone))
      |> Stream.reject(&is_nil/1)
      |> Enum.find(&(DateTime.compare(&1, local) == :gt))
      |> case do
        nil -> nil
        dt -> dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
      end
    else
      _ -> nil
    end
  end

  defp daily_candidates(_task, today, days), do: Stream.map(0..days, &Date.add(today, &1))

  defp weekly_candidates(task, today, days) do
    wanted = MapSet.new(task.weekdays || [])

    0..days
    |> Stream.map(&Date.add(today, &1))
    |> Stream.filter(&MapSet.member?(wanted, Date.day_of_week(&1)))
  end

  defp monthly_candidates(task, today, _days) do
    day = task.day_of_month || 1

    0..48
    |> Stream.map(fn offset ->
      {year, month} = add_months(today.year, today.month, offset)
      last = Date.days_in_month(Date.new!(year, month, 1))
      if day <= last, do: Date.new!(year, month, day)
    end)
    |> Stream.reject(&is_nil/1)
  end

  defp add_months(year, month, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp at_local(date, time, zone) do
    case DateTime.new(date, time, zone) do
      {:ok, dt} -> dt
      {:ambiguous, first, _} -> first
      {:gap, _, after_gap} -> after_gap
      _ -> nil
    end
  end

  defp time_of_day(task) do
    case Time.from_iso8601((task.time_of_day || "09:00") <> ":00") do
      {:ok, time} -> {:ok, time}
      _ -> :error
    end
  end

  defp zone(task) do
    case task.timezone do
      tz when is_binary(tz) and tz != "" -> tz
      _ -> "Etc/UTC"
    end
  end

  @doc """
  The local occurrences of `task` inside `first..last` (inclusive `Date`s), used
  to paint the calendar. Capped at 62 entries.
  """
  @spec occurrences(map(), Date.t(), Date.t()) :: [Date.t()]
  def occurrences(task, %Date{} = first, %Date{} = last) do
    from =
      first
      |> NaiveDateTime.new!(~T[00:00:00])
      |> DateTime.from_naive(zone(task))
      |> case do
        {:ok, dt} -> DateTime.add(dt, -1, :second)
        {:ambiguous, dt, _} -> DateTime.add(dt, -1, :second)
        {:gap, _, dt} -> dt
        _ -> DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
      end

    task
    |> Map.put(:enabled, true)
    |> walk(from, last, [], 0)
    |> Enum.reverse()
  end

  defp walk(_task, _from, _last, acc, count) when count >= 62, do: acc

  defp walk(task, from, last, acc, count) do
    case next_run(task, from) do
      nil ->
        acc

      next ->
        local = DateTime.shift_zone!(next, zone(task))
        date = DateTime.to_date(local)

        if Date.compare(date, last) == :gt do
          acc
        else
          # spec 60 T40: one entry per local date — continue from the end of that
          # day, so a per-minute task paints every day instead of one.
          walk(task, end_of_local_day(date, zone(task)), last, [date | acc], count + 1)
        end
    end
  end

  # The last second of `date` in `zone`, resolved like `occurrences/3` resolves
  # the window's first instant.
  defp end_of_local_day(date, zone) do
    date
    |> Date.add(1)
    |> NaiveDateTime.new!(~T[00:00:00])
    |> DateTime.from_naive(zone)
    |> case do
      {:ok, dt} -> dt
      {:ambiguous, dt, _} -> dt
      {:gap, _, dt} -> dt
      _ -> DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")
    end
    |> DateTime.add(-1, :second)
  end
end
