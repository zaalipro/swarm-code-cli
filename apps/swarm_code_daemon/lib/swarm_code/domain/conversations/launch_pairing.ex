defmodule SwarmCode.Domain.Conversations.LaunchPairing do
  @moduledoc """
  The user message that launched each run, keyed by run id (spec 13 §5) — the
  pure pairing fold behind `SwarmCode.Domain.Chat.launch_messages/3`, in the data
  layer (spec 74 ARCHITECTURE-21), so `Conversations` finds a legacy message's
  run without calling a web component.

  Runs are matched oldest first so a message is claimed once and only once; a
  run nobody launched from the composer maps to `nil`. A run whose workflow
  row names its launch message takes that one; otherwise the user message
  that carries the run's id (and does not reply to it); a run launched by
  another run has none; a legacy run (no `run_id` on its message) takes the
  newest unclaimed user message sent at most 10 s before it whose text
  matches its prompt.
  """

  @epoch ~U[1970-01-01 00:00:00.000000Z]
  @legacy_window_s 10

  @spec pair(list(), list(), map() | list()) :: %{binary() => map() | nil}
  def pair(messages, runs, workflow_runs \\ %{}) do
    messages =
      messages |> List.wrap() |> Enum.sort_by(&DateTime.to_unix(at(&1.inserted_at), :microsecond))

    launch_ids =
      Map.new(workflow_values(workflow_runs), &{&1.run_id, Map.get(&1, :launch_message_id)})

    runs
    |> List.wrap()
    |> Enum.sort_by(&DateTime.to_unix(at(&1.started_at), :microsecond))
    |> Enum.map_reduce(MapSet.new(), fn run, taken ->
      case launch_message(messages, Map.get(launch_ids, run.id), run, taken) do
        nil -> {{run.id, nil}, taken}
        m -> {{run.id, m}, MapSet.put(taken, m.id)}
      end
    end)
    |> elem(0)
    |> Map.new()
  end

  defp launch_message(messages, launch_id, run, taken) when is_binary(launch_id) do
    case Enum.find(messages, &(&1.id == launch_id)) do
      %{role: "user", id: id} = m -> if MapSet.member?(taken, id), do: nil, else: m
      _other -> launch_message(messages, nil, run, taken)
    end
  end

  defp launch_message(messages, _launch_id, run, taken) do
    own =
      Enum.find(messages, fn m ->
        m.role == "user" and Map.get(m, :run_id) == run.id and
          Map.get(m, :reply_to_run_id) != run.id and not MapSet.member?(taken, m.id)
      end)

    cond do
      own != nil -> own
      is_binary(Map.get(run, :launched_by_run_id)) -> nil
      true -> legacy_launch_message(messages, run, taken)
    end
  end

  defp legacy_launch_message(messages, run, taken) do
    started = at(run.started_at)

    messages
    |> Enum.filter(fn m ->
      m.role == "user" and is_nil(Map.get(m, :run_id)) and
        DateTime.compare(at(m.inserted_at), started) != :gt and
        DateTime.diff(started, at(m.inserted_at)) <= @legacy_window_s and
        not MapSet.member?(taken, m.id) and legacy_match?(m, run)
    end)
    |> List.last()
  end

  defp legacy_match?(m, run) do
    content = to_string(m.content || "")
    prompt = to_string(Map.get(run, :prompt) || "")

    content == prompt or content == "/swarm " <> prompt or
      String.starts_with?(content, "/goal") or
      (String.starts_with?(content, "/") and String.ends_with?(content, prompt) and prompt != "")
  end

  defp workflow_values(runs) when is_map(runs), do: Map.values(runs)
  defp workflow_values(runs) when is_list(runs), do: runs
  defp workflow_values(_runs), do: []

  defp at(%DateTime{} = dt), do: dt
  defp at(_other), do: @epoch
end
