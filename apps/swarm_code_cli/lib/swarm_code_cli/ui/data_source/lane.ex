defmodule SwarmCodeCLI.UI.DataSource.Lane do
  @moduledoc """
  pass72 S: the client half of the rolling activity lane (plan P4, rule R7).

  The daemon sends an agent's last 60 seconds as 12 five-second cells ending
  at `lane_at`, a cell boundary at or after the agent's last recorded event,
  plus `lane_now`, the kind still going on then. The body only changes when
  the database does, so the client rolls the window forward to its own clock:
  every whole cell since `lane_at` repeats `lane_now` (an open command keeps
  its `▅`, an idle agent drifts to `·`). Pure: the clock is an argument.
  """

  @cell_ms 5_000
  @cells 12

  @type kind :: :think | :tools | :write | :wait_you | :idle

  def cell_ms, do: @cell_ms

  @doc """
  The newest `cells` kinds (12 in the full panel, 8 in compact) of `agent` at
  `now_ms`, oldest first; `[]` when the agent has no lane (done, failed,
  queued, or no recorded activity), which the panel draws as no lane at all.
  """
  @spec window(map(), integer() | nil, pos_integer()) :: [kind()]
  def window(agent, now_ms, cells \\ @cells) do
    lane = Map.get(agent, :lane, [])
    lane_at = Map.get(agent, :lane_at)

    cond do
      lane == [] ->
        []

      is_integer(now_ms) and is_integer(lane_at) and now_ms > lane_at ->
        shift = min(div(now_ms - lane_at, @cell_ms), @cells)
        Enum.take(lane ++ List.duplicate(Map.get(agent, :lane_now, :idle), shift), -cells)

      true ->
        Enum.take(lane, -cells)
    end
  end

  @doc "How long the agent has run at `now_ms`: its recorded span once finished, else the clock's."
  @spec elapsed_ms(map(), integer() | nil) :: non_neg_integer() | nil
  def elapsed_ms(agent, now_ms) do
    case {Map.get(agent, :elapsed_ms), Map.get(agent, :started_at), Map.get(agent, :finished_at)} do
      {ms, _, _} when is_integer(ms) -> ms
      {_, s, f} when is_integer(s) and is_integer(f) -> max(f - s, 0)
      {_, s, nil} when is_integer(s) and is_integer(now_ms) -> max(now_ms - s, 0)
      _ -> nil
    end
  end
end
