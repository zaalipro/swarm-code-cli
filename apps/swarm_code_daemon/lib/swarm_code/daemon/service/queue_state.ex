defmodule SwarmCode.Daemon.Service.QueueState do
  @moduledoc "Pure session-owned queue identities. Effects belong to the backend."

  def new, do: %{next_generation: 0, entries: %{}}
  def entry(state, id), do: Map.get(state.entries, id)

  def activate(state, id) do
    case entry(state, id) do
      nil ->
        generation = state.next_generation + 1
        entry = %{generation: generation, monitors: %{}, retries: 0, timer: nil}

        {%{state | next_generation: generation, entries: Map.put(state.entries, id, entry)},
         generation}

      entry ->
        {state, entry.generation}
    end
  end

  def put_monitor(state, id, ref, pid),
    do: update(state, id, &%{&1 | monitors: Map.put(&1.monitors, ref, pid)})

  def pop_monitor(state, ref) do
    case Enum.find(state.entries, fn {_id, entry} -> Map.has_key?(entry.monitors, ref) end) do
      nil ->
        {state, :stale}

      {id, entry} ->
        {update(state, id, &%{&1 | monitors: Map.delete(&1.monitors, ref)}),
         {id, entry.generation}}
    end
  end

  def retry(state, id) do
    case entry(state, id) do
      %{retries: n} when n < 8 -> {update(state, id, &%{&1 | retries: n + 1}), :retry}
      _ -> {state, :exhausted}
    end
  end

  def put_timer(state, id, timer), do: update(state, id, &%{&1 | timer: timer})
  def reset(state, id), do: update(state, id, &%{&1 | retries: 0, timer: nil})
  def remove(state, id), do: %{state | entries: Map.delete(state.entries, id)}

  defp update(state, id, fun),
    do: %{state | entries: Map.update!(state.entries, id, fun)}
end
