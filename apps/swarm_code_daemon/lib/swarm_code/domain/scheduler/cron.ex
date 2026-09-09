defmodule SwarmCode.Domain.Scheduler.Cron do
  @moduledoc """
  A small, dependency-free 5-field cron parser: `minute hour day-of-month month
  day-of-week`. Supports `*`, lists (`1,15`), ranges (`1-5`), steps (`*/15`,
  `1-5/2`) and the usual three-letter names (`mon`…`sun`, `jan`…`dec`).

  Day-of-week uses cron's convention (0 and 7 are both Sunday). As in cron, when
  *both* day-of-month and day-of-week are restricted a date matches if **either**
  of them matches.
  """

  @type field :: %{min: 0..59, max: integer(), values: MapSet.t()}
  @type t :: %{minute: field(), hour: field(), dom: field(), month: field(), dow: field()}

  @days ~w(sun mon tue wed thu fri sat)
  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
  @day_names %{
    1 => "Monday",
    2 => "Tuesday",
    3 => "Wednesday",
    4 => "Thursday",
    5 => "Friday",
    6 => "Saturday",
    7 => "Sunday"
  }

  @doc "Parses a 5-field expression. Returns `{:ok, cron}` or `{:error, message}`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(expr) when is_binary(expr) do
    case expr |> String.trim() |> String.split(~r/\s+/, trim: true) do
      [m, h, dom, mon, dow] ->
        with {:ok, minute} <- field(m, 0, 59, %{}),
             {:ok, hour} <- field(h, 0, 23, %{}),
             {:ok, dom_f} <- field(dom, 1, 31, %{}),
             {:ok, month} <- field(mon, 1, 12, month_names()),
             {:ok, dow_f} <- field(dow, 0, 7, day_names()) do
          {:ok,
           %{
             minute: minute,
             hour: hour,
             dom: dom_f,
             month: month,
             dow: dow_f,
             dom_star?: String.trim(dom) == "*",
             dow_star?: String.trim(dow) == "*"
           }}
        end

      fields ->
        {:error, "needs 5 fields (minute hour day month weekday), got #{length(fields)}"}
    end
  end

  def parse(_), do: {:error, "needs 5 fields (minute hour day month weekday)"}

  @doc "True when `expr` parses."
  @spec valid?(String.t()) :: boolean()
  def valid?(expr), do: match?({:ok, _}, parse(expr))

  @doc """
  The first minute strictly after `from` that matches `expr`, in `from`'s own
  time zone. Returns `nil` when nothing matches within four years (`30 2 30 2 *`).
  """
  @spec next(String.t() | t(), DateTime.t()) :: DateTime.t() | nil
  def next(expr, %DateTime{} = from) when is_binary(expr) do
    case parse(expr) do
      {:ok, cron} -> next(cron, from)
      {:error, _} -> nil
    end
  end

  def next(cron, %DateTime{} = from) when is_map(cron) do
    start =
      from
      |> DateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> Map.put(:microsecond, {0, 0})
      |> add_minutes(1)

    # spec 60 T41: never an instant at or before `from`, whatever the zone did
    # inside the repeated hour of a fall-back change.
    case search(cron, start, 0) do
      %DateTime{} = r ->
        if DateTime.compare(r, from) == :gt, do: r, else: search(cron, add_minutes(r, 1), 0)

      nil ->
        nil
    end
  end

  # Walks minute by minute but skips whole days and hours that cannot match, so
  # the worst case stays in the low thousands of iterations.
  defp search(_cron, _dt, steps) when steps > 200_000, do: nil

  defp search(cron, dt, steps) do
    cond do
      not member?(cron.month, dt.month) ->
        search(cron, start_of_next_month(dt), steps + 1)

      not day_matches?(cron, dt) ->
        search(cron, start_of_next_day(dt), steps + 1)

      not member?(cron.hour, dt.hour) ->
        search(cron, start_of_next_hour(dt), steps + 1)

      not member?(cron.minute, dt.minute) ->
        search(cron, add_minutes(dt, 1), steps + 1)

      true ->
        dt
    end
  end

  defp day_matches?(cron, dt) do
    dow = dt |> DateTime.to_date() |> Date.day_of_week() |> normalize_dow()
    dom? = member?(cron.dom, dt.day)
    dow? = member?(cron.dow, dow) or member?(cron.dow, if(dow == 0, do: 7, else: dow))

    cond do
      cron.dom_star? and cron.dow_star? -> true
      cron.dom_star? -> dow?
      cron.dow_star? -> dom?
      true -> dom? or dow?
    end
  end

  # `Date.day_of_week/1` is 1 (Monday) … 7 (Sunday); cron wants 0 for Sunday.
  defp normalize_dow(7), do: 0
  defp normalize_dow(n), do: n

  defp member?(field, value), do: MapSet.member?(field.values, value)

  @doc """
  A plain-English sentence for the common shapes, and the raw expression for
  everything else.
  """
  @spec describe(String.t()) :: String.t()
  def describe(expr) when is_binary(expr) do
    with {:ok, cron} <- parse(expr),
         [minute] <- MapSet.to_list(cron.minute.values),
         [hour] <- MapSet.to_list(cron.hour.values) do
      at = " at " <> two(hour) <> ":" <> two(minute)

      cond do
        cron.dom_star? and cron.dow_star? and full?(cron.month) ->
          "Every day" <> at

        cron.dom_star? and full?(cron.month) and not cron.dow_star? ->
          "Every " <> weekday_list(cron.dow) <> at

        cron.dow_star? and full?(cron.month) and not cron.dom_star? ->
          "At " <>
            two(hour) <>
            ":" <> two(minute) <> " on day " <> day_list(cron.dom) <> " of every month"

        true ->
          String.trim(expr)
      end
    else
      _ -> String.trim(expr)
    end
  end

  def describe(_), do: ""

  defp full?(field), do: MapSet.size(field.values) == field.max - field.min + 1

  defp weekday_list(field) do
    field.values
    |> Enum.map(fn
      0 -> 7
      n -> n
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Map.fetch!(@day_names, &1))
    |> join_and()
  end

  defp day_list(field), do: field.values |> Enum.sort() |> Enum.map(&to_string/1) |> join_and()

  defp join_and([one]), do: one
  defp join_and([a, b]), do: a <> " and " <> b

  defp join_and(list) do
    {init, [last]} = Enum.split(list, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp two(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  ## field parsing

  defp field(spec, min, max, names) do
    spec
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case part_values(String.trim(part), min, max, names) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, values} ->
        if MapSet.size(values) == 0 do
          {:error, "empty field"}
        else
          {:ok, %{min: min, max: max, values: values}}
        end

      err ->
        err
    end
  end

  defp part_values(part, min, max, names) do
    {base, step} =
      case String.split(part, "/", parts: 2) do
        [b, s] -> {b, s}
        [b] -> {b, nil}
      end

    with {:ok, step} <- parse_step(step),
         {:ok, lo, hi} <- range(base, min, max, names) do
      {:ok, lo |> Stream.iterate(&(&1 + 1)) |> Enum.take(hi - lo + 1) |> take_step(lo, step)}
    end
  end

  defp take_step(values, lo, step),
    do: values |> Enum.filter(&(rem(&1 - lo, step) == 0)) |> MapSet.new()

  defp parse_step(nil), do: {:ok, 1}

  defp parse_step(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "bad step “#{s}”"}
    end
  end

  defp range("*", min, max, _names), do: {:ok, min, max}

  defp range(base, min, max, names) do
    case String.split(base, "-", parts: 2) do
      [a, b] ->
        with {:ok, lo} <- value(a, min, max, names), {:ok, hi} <- value(b, min, max, names) do
          if lo <= hi, do: {:ok, lo, hi}, else: {:error, "range “#{base}” is backwards"}
        end

      [a] ->
        with {:ok, v} <- value(a, min, max, names), do: {:ok, v, v}
    end
  end

  defp value(text, min, max, names) do
    text = text |> String.trim() |> String.downcase()

    parsed =
      case Map.fetch(names, text) do
        {:ok, n} -> {:ok, n}
        :error -> parse_int(text)
      end

    case parsed do
      {:ok, n} when n >= min and n <= max -> {:ok, n}
      {:ok, n} -> {:error, "“#{n}” is outside #{min}-#{max}"}
      :error -> {:error, "“#{text}” is not a number"}
    end
  end

  defp parse_int(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp day_names, do: @days |> Enum.with_index() |> Map.new()
  defp month_names, do: @months |> Enum.with_index(1) |> Map.new()

  ## calendar helpers (all zone-aware: `DateTime.add` walks real time)

  defp add_minutes(dt, n) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.add(n * 60, :second)
    |> to_zone(dt.time_zone, dt)
  end

  defp start_of_next_hour(dt) do
    dt
    |> DateTime.to_naive()
    |> Map.merge(%{minute: 0, second: 0, microsecond: {0, 0}})
    |> NaiveDateTime.add(3600, :second)
    |> to_zone(dt.time_zone, dt)
  end

  defp start_of_next_day(dt) do
    dt
    |> DateTime.to_date()
    |> Date.add(1)
    |> NaiveDateTime.new!(~T[00:00:00])
    |> to_zone(dt.time_zone, dt)
  end

  defp start_of_next_month(dt) do
    date = DateTime.to_date(dt)
    days = Date.days_in_month(date) - date.day + 1

    date
    |> Date.add(days)
    |> NaiveDateTime.new!(~T[00:00:00])
    |> to_zone(dt.time_zone, dt)
  end

  # Skipped local times (spring forward) resolve to the first valid instant.
  #
  # spec 60 T41: a repeated local time (fall back) resolves to the occurrence
  # after `not_before` — the first one when stepping out of the first pass of
  # the hour, the second when stepping inside the second — so a step never
  # lands before where it started. (`after` is a reserved word.)
  defp to_zone(naive, zone, not_before) do
    case DateTime.from_naive(naive, zone) do
      {:ok, dt} ->
        dt

      {:ambiguous, first, second} ->
        if DateTime.compare(first, not_before) == :gt, do: first, else: second

      {:gap, _before, after_gap} ->
        after_gap

      {:error, _} ->
        DateTime.from_naive!(naive, "Etc/UTC")
    end
  end
end
