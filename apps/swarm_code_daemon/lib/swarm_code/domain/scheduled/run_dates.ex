defmodule SwarmCode.Domain.Scheduled.RunDates do
  @moduledoc """
  Spec 74 EFFICIENCY-19: the local dates in a calendar grid on which a
  scheduled run happened — the ✓ marks of /scheduled. The page grouped every
  `Scheduled.Run` struct of the UTC month by its local date (a `zone()` read
  and a validating shift per row) and used the result only as a boolean;
  adjacent-month cells and runs near local midnight lost their ✓.

  This selects only `scheduled_for` over the grid's range, widened by a day
  on each side (more than any UTC offset), converts each with the one `zone`
  it is given, and keeps the local dates inside `first..last`.
  """

  import Ecto.Query

  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Scheduled.Run

  @spec dates(Date.t(), Date.t(), String.t()) :: MapSet.t(Date.t())
  def dates(%Date{} = first, %Date{} = last, zone) when is_binary(zone) do
    from_dt = DateTime.new!(Date.add(first, -1), ~T[00:00:00], "Etc/UTC")
    to_dt = DateTime.new!(Date.add(last, 2), ~T[00:00:00], "Etc/UTC")

    from(r in Run,
      where: r.scheduled_for >= ^from_dt and r.scheduled_for < ^to_dt,
      select: r.scheduled_for
    )
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn at, acc ->
      date = local_date(at, zone)

      if Date.compare(date, first) != :lt and Date.compare(date, last) != :gt,
        do: MapSet.put(acc, date),
        else: acc
    end)
  end

  defp local_date(at, zone) do
    case DateTime.shift_zone(at, zone) do
      {:ok, local} -> DateTime.to_date(local)
      _error -> DateTime.to_date(at)
    end
  end
end
