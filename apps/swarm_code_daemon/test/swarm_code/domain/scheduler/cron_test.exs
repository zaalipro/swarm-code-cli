defmodule SwarmCode.Domain.Scheduler.CronTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Scheduler.Cron

  describe "parse/1" do
    test "accepts the shapes cron accepts" do
      for expr <- [
            "* * * * *",
            "0 9 * * *",
            "*/15 * * * *",
            "30 18 * * mon,fri",
            "0 0 1 * *",
            "0 8-17/2 * * 1-5",
            "0 0 1 jan *",
            "0 0 * * 0",
            "0 0 * * 7"
          ] do
        assert {:ok, _} = Cron.parse(expr), "expected #{expr} to parse"
        assert Cron.valid?(expr)
      end
    end

    test "rejects nonsense" do
      assert {:error, msg} = Cron.parse("0 9 * *")
      assert msg =~ "5 fields"

      assert {:error, _} = Cron.parse("60 * * * *")
      assert {:error, _} = Cron.parse("0 25 * * *")
      assert {:error, _} = Cron.parse("0 9 * * funday")
      assert {:error, _} = Cron.parse("0 9-5 * * *")
      assert {:error, _} = Cron.parse("*/0 * * * *")
      refute Cron.valid?("nope")
    end
  end

  describe "next/2" do
    test "every minute" do
      from = ~U[2026-08-20 10:00:30Z]
      assert Cron.next("* * * * *", from) == ~U[2026-08-20 10:01:00Z]
    end

    test "daily at 09:00 rolls to tomorrow once it has passed" do
      assert Cron.next("0 9 * * *", ~U[2026-08-20 08:00:00Z]) == ~U[2026-08-20 09:00:00Z]
      assert Cron.next("0 9 * * *", ~U[2026-08-20 09:00:00Z]) == ~U[2026-08-21 09:00:00Z]
    end

    test "steps" do
      assert Cron.next("*/15 * * * *", ~U[2026-08-20 10:02:00Z]) == ~U[2026-08-20 10:15:00Z]
      assert Cron.next("*/15 * * * *", ~U[2026-08-20 10:46:00Z]) == ~U[2026-08-20 11:00:00Z]
    end

    test "named weekdays" do
      # 2026-08-20 is a Thursday; the next Monday is the 24th.
      assert Cron.next("30 18 * * mon,fri", ~U[2026-08-20 19:00:00Z]) == ~U[2026-08-21 18:30:00Z]
      assert Cron.next("30 18 * * mon", ~U[2026-08-20 19:00:00Z]) == ~U[2026-08-24 18:30:00Z]
    end

    test "day of month skips short months" do
      assert Cron.next("0 0 31 * *", ~U[2026-01-31 12:00:00Z]) == ~U[2026-03-31 00:00:00Z]
    end

    test "a month that never comes around returns nil for 30 February" do
      assert Cron.next("0 0 30 2 *", ~U[2026-01-01 00:00:00Z]) == nil
    end

    test "day-of-month and day-of-week are OR'ed, as in cron" do
      # The 1st (a Tuesday) and every Monday of September 2026.
      assert Cron.next("0 0 1 9 mon", ~U[2026-08-31 12:00:00Z]) == ~U[2026-09-01 00:00:00Z]
      assert Cron.next("0 0 1 9 mon", ~U[2026-09-01 12:00:00Z]) == ~U[2026-09-07 00:00:00Z]
    end

    test "works in a zone with DST" do
      {:ok, from} = DateTime.new(~D[2026-03-28], ~T[12:00:00], "Europe/Berlin")
      next = Cron.next("0 9 * * *", from)
      assert next.time_zone == "Europe/Berlin"
      assert DateTime.to_date(next) == ~D[2026-03-29]
      assert next.hour == 9
      # 09:00 CEST is 07:00 UTC — the wall clock stayed put across the change.
      assert next |> DateTime.shift_zone!("Etc/UTC") |> Map.get(:hour) == 7
    end

    test "a local time that does not exist is skipped, as in cron" do
      # Berlin jumps 02:00 → 03:00 on 2026-03-29, so 02:30 never happens that
      # day and the expression simply matches the day after.
      {:ok, from} = DateTime.new(~D[2026-03-28], ~T[12:00:00], "Europe/Berlin")
      next = Cron.next("30 2 * * *", from)
      assert DateTime.to_date(next) == ~D[2026-03-30]
      assert {next.hour, next.minute} == {2, 30}
    end

    test "the repeated hour of a fall-back change is strictly after from (spec 60 T41)" do
      # Berlin repeats 02:00–02:59 on 2026-10-25 (03:00 CEST → 02:00 CET). From
      # inside the second pass, the next minute used to resolve to the first
      # pass — an hour *earlier* — and a task fired every tick.
      {:ambiguous, _cest, cet} = DateTime.from_naive(~N[2026-10-25 02:30:00], "Europe/Berlin")
      next = Cron.next("* * * * *", cet)
      assert DateTime.shift_zone!(next, "Etc/UTC") == ~U[2026-10-25 01:31:00Z]
      assert DateTime.compare(next, cet) == :gt

      {:ambiguous, _cest, two_cet} =
        DateTime.from_naive(~N[2026-10-25 02:00:00], "Europe/Berlin")

      hourly = Cron.next("15 * * * *", two_cet)
      assert DateTime.shift_zone!(hourly, "Etc/UTC") == ~U[2026-10-25 01:15:00Z]
      assert DateTime.compare(hourly, two_cet) == :gt

      daily = Cron.next("30 2 * * *", two_cet)
      assert DateTime.shift_zone!(daily, "Etc/UTC") == ~U[2026-10-25 01:30:00Z]
      assert DateTime.compare(daily, two_cet) == :gt
    end
  end

  describe "describe/1" do
    test "the readable shapes" do
      assert Cron.describe("0 9 * * *") == "Every day at 09:00"
      assert Cron.describe("30 18 * * mon,fri") == "Every Monday and Friday at 18:30"
      assert Cron.describe("0 9 1 * *") == "At 09:00 on day 1 of every month"
      assert Cron.describe("0 0 * * 0") == "Every Sunday at 00:00"
    end

    test "falls back to the expression" do
      assert Cron.describe("*/15 * * * *") == "*/15 * * * *"
      assert Cron.describe("nonsense") == "nonsense"
      assert Cron.describe(nil) == ""
    end
  end
end
