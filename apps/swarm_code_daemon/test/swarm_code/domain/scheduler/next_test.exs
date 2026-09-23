defmodule SwarmCode.Domain.Scheduler.NextTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Scheduled.Task
  alias SwarmCode.Domain.Scheduler.Next

  defp task(attrs) do
    struct!(
      %Task{
        name: "t",
        prompt: "p",
        kind: "chat",
        mode: "build",
        enabled: true,
        timezone: "Europe/Berlin",
        time_of_day: "09:00"
      },
      attrs
    )
  end

  test "local_zone/0 returns a zone the tz database knows" do
    zone = Next.local_zone()
    assert is_binary(zone)
    assert {:ok, _} = DateTime.shift_zone(DateTime.utc_now(), zone)
  end

  test "a disabled task never runs" do
    assert Next.next_run(task(schedule_kind: "daily", enabled: false), ~U[2026-08-20 06:00:00Z]) ==
             nil
  end

  describe "once" do
    test "takes run_at while it is in the future" do
      at = ~U[2026-08-21 07:00:00Z]

      assert Next.next_run(task(schedule_kind: "once", run_at: at), ~U[2026-08-20 06:00:00Z]) ==
               at
    end

    test "is nil once it has passed" do
      at = ~U[2026-08-19 07:00:00Z]

      assert Next.next_run(task(schedule_kind: "once", run_at: at), ~U[2026-08-20 06:00:00Z]) ==
               nil

      assert Next.next_run(task(schedule_kind: "once", run_at: nil), ~U[2026-08-20 06:00:00Z]) ==
               nil
    end
  end

  describe "daily" do
    test "today when the time is still ahead, tomorrow otherwise" do
      t = task(schedule_kind: "daily", time_of_day: "09:00")
      # 06:00 UTC is 08:00 in Berlin — 09:00 local is still to come.
      assert Next.next_run(t, ~U[2026-08-20 06:00:00Z]) == ~U[2026-08-20 07:00:00Z]
      assert Next.next_run(t, ~U[2026-08-20 08:00:00Z]) == ~U[2026-08-21 07:00:00Z]
    end

    test "keeps the wall clock across a DST change" do
      t = task(schedule_kind: "daily", time_of_day: "09:00")
      # Berlin is +01:00 before 2026-03-29 and +02:00 after.
      assert Next.next_run(t, ~U[2026-03-27 12:00:00Z]) == ~U[2026-03-28 08:00:00Z]
      assert Next.next_run(t, ~U[2026-03-28 12:00:00Z]) == ~U[2026-03-29 07:00:00Z]
    end

    test "a time inside the spring-forward gap runs at the first valid instant" do
      t = task(schedule_kind: "daily", time_of_day: "02:30")
      next = Next.next_run(t, ~U[2026-03-28 12:00:00Z])
      local = DateTime.shift_zone!(next, "Europe/Berlin")
      assert DateTime.to_date(local) == ~D[2026-03-29]
      assert local.hour == 3
    end
  end

  describe "weekly" do
    test "picks the next selected weekday" do
      # 2026-08-20 is a Thursday. Monday = 1 … Sunday = 7.
      t = task(schedule_kind: "weekly", weekdays: [1, 5], time_of_day: "18:30")
      # Friday the 21st at 18:30 Berlin = 16:30 UTC.
      assert Next.next_run(t, ~U[2026-08-20 06:00:00Z]) == ~U[2026-08-21 16:30:00Z]
      # After Friday's slot the next is Monday the 24th.
      assert Next.next_run(t, ~U[2026-08-21 17:00:00Z]) == ~U[2026-08-24 16:30:00Z]
    end

    test "no weekdays means no run" do
      t = task(schedule_kind: "weekly", weekdays: [], time_of_day: "18:30")
      assert Next.next_run(t, ~U[2026-08-20 06:00:00Z]) == nil
    end
  end

  describe "monthly" do
    test "the same day every month" do
      t = task(schedule_kind: "monthly", day_of_month: 1, time_of_day: "09:00")
      assert Next.next_run(t, ~U[2026-08-20 06:00:00Z]) == ~U[2026-09-01 07:00:00Z]
    end

    test "months without the day are skipped" do
      t = task(schedule_kind: "monthly", day_of_month: 31, time_of_day: "09:00")
      assert Next.next_run(t, ~U[2026-01-31 12:00:00Z]) == ~U[2026-03-31 07:00:00Z]
    end
  end

  describe "cron" do
    test "delegates to the parser in the task zone" do
      t = task(schedule_kind: "cron", cron: "0 9 * * *")
      assert Next.next_run(t, ~U[2026-08-20 08:00:00Z]) == ~U[2026-08-21 07:00:00Z]
    end

    test "an unparseable expression never runs" do
      assert Next.next_run(task(schedule_kind: "cron", cron: "nope"), ~U[2026-08-20 08:00:00Z]) ==
               nil

      assert Next.next_run(task(schedule_kind: "cron", cron: nil), ~U[2026-08-20 08:00:00Z]) ==
               nil
    end
  end

  describe "occurrences/3" do
    test "expands a weekly task over a month" do
      t = task(schedule_kind: "weekly", weekdays: [1], time_of_day: "09:00")
      dates = Next.occurrences(t, ~D[2026-08-01], ~D[2026-08-31])

      assert dates == [
               ~D[2026-08-03],
               ~D[2026-08-10],
               ~D[2026-08-17],
               ~D[2026-08-24],
               ~D[2026-08-31]
             ]
    end

    test "a once task appears exactly once, and never outside the window" do
      t = task(schedule_kind: "once", run_at: ~U[2026-08-21 07:00:00Z])
      assert Next.occurrences(t, ~D[2026-08-01], ~D[2026-08-31]) == [~D[2026-08-21]]
      assert Next.occurrences(t, ~D[2026-09-01], ~D[2026-09-30]) == []
    end

    test "a per-minute cron paints every date of the month (spec 60 T40)" do
      t = task(schedule_kind: "cron", cron: "* * * * *")

      assert Next.occurrences(t, ~D[2026-08-01], ~D[2026-08-31]) ==
               Enum.map(1..31, &Date.new!(2026, 8, &1))
    end

    test "the cap is 62 dates (spec 60 T40)" do
      t = task(schedule_kind: "cron", cron: "* * * * *")
      assert length(Next.occurrences(t, ~D[2026-08-01], ~D[2026-11-30])) == 62
    end

    test "a disabled task still paints the calendar" do
      t = task(schedule_kind: "daily", time_of_day: "09:00", enabled: false)
      assert length(Next.occurrences(t, ~D[2026-08-01], ~D[2026-08-07])) == 7
    end
  end

  ## --------------------------------------- occurrence table tests (spec 08 §25)

  describe "occurrences across month boundaries and DST" do
    test "a once task next month is expanded from this month's grid" do
      t = task(schedule_kind: "once", run_at: ~U[2026-09-15 07:00:00Z])

      # the September grid starts on Mon 31 Aug and ends on Sun 11 Oct
      assert Next.occurrences(t, ~D[2026-08-31], ~D[2026-10-11]) == [~D[2026-09-15]]
      # and for that exact day alone (what the day panel asks for)
      assert Next.occurrences(t, ~D[2026-09-15], ~D[2026-09-15]) == [~D[2026-09-15]]
      assert Next.occurrences(t, ~D[2026-09-14], ~D[2026-09-14]) == []
    end

    test "a once task is expanded in its own zone, not in UTC" do
      # 00:30 Berlin on 1 Sep is 22:30 UTC on 31 Aug
      t = task(schedule_kind: "once", run_at: ~U[2026-08-31 22:30:00Z], timezone: "Europe/Berlin")
      assert Next.occurrences(t, ~D[2026-09-01], ~D[2026-09-30]) == [~D[2026-09-01]]

      utc = task(schedule_kind: "once", run_at: ~U[2026-08-31 22:30:00Z], timezone: "Etc/UTC")
      assert Next.occurrences(utc, ~D[2026-09-01], ~D[2026-09-30]) == []
    end

    test "a daily task keeps its wall clock across the spring DST change" do
      t = task(schedule_kind: "daily", time_of_day: "02:30", timezone: "Europe/Berlin")

      assert Next.occurrences(t, ~D[2026-03-27], ~D[2026-03-31]) == [
               ~D[2026-03-27],
               ~D[2026-03-28],
               ~D[2026-03-29],
               ~D[2026-03-30],
               ~D[2026-03-31]
             ]
    end

    test "a weekly task spans the year end" do
      t = task(schedule_kind: "weekly", weekdays: [4], time_of_day: "23:30")

      assert Next.occurrences(t, ~D[2026-12-28], ~D[2027-01-10]) == [
               ~D[2026-12-31],
               ~D[2027-01-07]
             ]
    end

    test "a monthly task on day 31 skips the short months" do
      t = task(schedule_kind: "monthly", day_of_month: 31)

      assert Next.occurrences(t, ~D[2026-01-01], ~D[2026-06-30]) == [
               ~D[2026-01-31],
               ~D[2026-03-31],
               ~D[2026-05-31]
             ]
    end

    test "a weekday cron crosses the month boundary" do
      t = task(schedule_kind: "cron", cron: "0 9 * * 1-5")

      assert Next.occurrences(t, ~D[2026-08-31], ~D[2026-09-06]) == [
               ~D[2026-08-31],
               ~D[2026-09-01],
               ~D[2026-09-02],
               ~D[2026-09-03],
               ~D[2026-09-04]
             ]
    end
  end
end
