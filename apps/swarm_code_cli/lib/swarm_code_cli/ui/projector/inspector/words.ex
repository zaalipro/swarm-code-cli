defmodule SwarmCodeCLI.UI.Projector.Inspector.Words do
  @moduledoc """
  Plain words for run and agent states, and the number formats the hive shares.

  The status catalogue (`Theme.status/1`) prints the reducer's own vocabulary —
  `RUNNING`, `STOPPED`, `NEEDS ANSWER` — which is right for a status cue and
  wrong for a sentence. Every screen the hive draws says what the state means
  to the person reading it instead: "waiting for you", "stopped by you", "done".
  """

  @live [:queued, :running, :streaming, :waiting_question, :waiting_approval, :paused, :retrying]
  @finished [:done, :failed, :stopped, :interrupted, :superseded]

  @doc "The state as words a person would use."
  def state(:queued), do: "queued"
  def state(:running), do: "running"
  def state(:streaming), do: "writing"
  def state(:waiting_question), do: "waiting for you"
  def state(:waiting_approval), do: "waiting for you"
  def state(:paused), do: "paused"
  def state(:retrying), do: "retrying"
  def state(:done), do: "done"
  def state(:failed), do: "failed"
  def state(:stopped), do: "stopped by you"
  def state(:interrupted), do: "interrupted"
  def state(:superseded), do: "superseded"
  def state(_state), do: ""

  @doc "The theme role that colours a state's words."
  def role(state) when state in [:waiting_question, :waiting_approval], do: :warning
  def role(:failed), do: :error
  def role(:done), do: :success
  def role(state) when state in [:running, :streaming], do: :accent
  def role(state) when state in [:paused, :retrying, :queued, :interrupted], do: :warning
  def role(_state), do: :text_muted

  def waiting?(state), do: state in [:waiting_question, :waiting_approval]
  def running?(state), do: state in [:running, :streaming]
  def live?(state), do: state in @live
  def finished?(state), do: state in @finished

  @doc ~S"""
  A token count in thousands: `1.8k`, `0.9k`, `124k`, `1.2M`.

  One decimal below ten thousand, where the decimal still says something; whole
  thousands above it.
  """
  def tokens(count) when not is_integer(count) or count <= 0, do: "0k"
  def tokens(count) when count < 10_000, do: "#{Float.round(count / 1000, 1)}k"
  def tokens(count) when count < 1_000_000, do: "#{div(count, 1000)}k"
  def tokens(count), do: "#{Float.round(count / 1_000_000, 1)}M"

  @doc """
  The time between two millisecond stamps as `mm:ss`, or `h:mm:ss` past an hour.

  `nil` when either stamp is missing or the clock has not reached the start
  yet: a fixture state whose `now` is still zero has no elapsed time to show,
  and a negative one would be a lie.
  """
  def elapsed(started, until)
      when is_integer(started) and is_integer(until) and until >= started,
      do: duration(until - started)

  def elapsed(_started, _until), do: nil

  @doc "A millisecond span as `mm:ss`, or `h:mm:ss` past an hour."
  def duration(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1000)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    rest = rem(seconds, 60)

    if hours > 0,
      do: "#{hours}:#{pad(minutes)}:#{pad(rest)}",
      else: "#{pad(minutes)}:#{pad(rest)}"
  end

  def duration(_ms), do: nil

  @doc "The moment a run's clock stops: when it finished, else the state's own clock."
  def until(run, state) do
    cond do
      is_integer(Map.get(run, :finished_at)) -> run.finished_at
      is_integer(state.now) and state.now > 0 -> state.now
      true -> nil
    end
  end

  @doc "A unix-millisecond stamp as the local wall clock, `HH:MM`; `nil` when unknown."
  def clock(ms) when is_integer(ms) and ms > 0 do
    {{_y, _mo, _d}, {hour, minute, _s}} =
      ms
      |> div(1000)
      |> Kernel.+(62_167_219_200)
      |> :calendar.gregorian_seconds_to_datetime()
      |> :calendar.universal_time_to_local_time()

    "#{pad(hour)}:#{pad(minute)}"
  end

  def clock(_ms), do: nil

  @doc "`1 agent`, `3 agents`, `0 files`."
  def count(1, one, _many), do: "1 #{one}"
  def count(n, _one, many), do: "#{n} #{many}"

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")
end
