defmodule SwarmCode.Domain.Chat do
  @moduledoc "Canonical run-launch pairing shared by history, edit/resend and terminal projection."
  @epoch DateTime.from_unix!(0)
  def launch_messages(messages, runs, workflow_runs \\ %{}) do
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

  @legacy_window_s 10

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

  # The legacy pairing rule, reached through `launch_messages/3` — which is what
  # `mix swarm_code.repair_launches` calls (spec 36 §B9: private).
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
  defp at(_), do: @epoch
end
