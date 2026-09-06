defmodule SwarmCodeCLI.UI.TimerSupervisor do
  @moduledoc "Runtime-local timer registry. Replacement and cancellation settle exact identities."
  def start(timers, id, milliseconds, action) when map_size(timers) < 256 do
    timers = cancel(timers, id)
    token = make_ref()
    timer = Process.send_after(self(), {:owned_timer, id, token}, milliseconds)
    Map.put(timers, id, {timer, token, action})
  end

  def cancel(timers, id) do
    case Map.pop(timers, id) do
      {nil, _} ->
        timers

      {{timer, _, _}, rest} ->
        Process.cancel_timer(timer)
        rest
    end
  end

  def settle(timers, id, token) do
    case Map.get(timers, id) do
      {_, ^token, action} -> {:ok, action, cancel(timers, id)}
      _ -> :stale
    end
  end

  def close(timers) do
    Enum.each(timers, fn {_, {timer, _, _}} -> Process.cancel_timer(timer) end)
    %{}
  end
end
