defmodule SwarmCode.Daemon.Service.Cli022VitalsSamplesTest do
  @moduledoc """
  cli022 F6: one sparkline bar is one finished, measured model call (the
  desktop's speed monitor shows the latest finished call's tok/s; a streaming
  call is a live estimate, never stored). QA saw 2 worker bars after 4 worker
  calls. Two causes:

  - CLI (`Vitals.absorb/3`): a sample was marked by `{at, tps}` with `at` in
    whole seconds, so a second call finishing in the same second at the same
    rate (equal fake speeds) was taken for the first and dropped, though the
    speed monitor published it (its ttft differed). Fixed: the whole value.
  - Synced (`domain/llm/speed.ex` `publish/2`: `Map.merge(conv.exact,
    conv.live)`): while a call of the slot still streams, its live estimate
    hides an exact value that finished beside it, so of two parallel workers
    only the later finish is ever published. The repro below pins that
    behaviour of the synced file; the desktop change in notes/Y.md adds a
    `{:speed_call, cid, role, value}` per measured call, which `Vitals`
    already takes (tested here with the message itself). When that change is
    synced the repro's last assertion flips to two samples.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Vitals
  alias SwarmCode.Domain.LLM.Speed

  @cid "7a3c4c52-0d6a-4d1e-9f6e-0a8f6a3f2222"

  setup do
    start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    Application.put_env(:swarm_code_daemon, :speed_clock, fn -> Agent.get(clock, & &1) end)
    on_exit(fn -> Application.delete_env(:swarm_code_daemon, :speed_clock) end)

    if :ets.whereis(:swarm_code_speed) == :undefined,
      do: start_supervised!(Speed),
      else: Speed.reset()

    on_exit(fn -> :ets.delete(:swarm_code_speed, {:conv, @cid}) end)

    vitals =
      start_supervised!(
        {Vitals,
         subscriber: self(),
         conversation_id: @cid,
         config: fn _cid -> %{mode: :two, main: "m", worker: "w", validator: "m", others: []} end,
         sampler: fn _ -> %{os_rss_bytes: 1, children_rss_bytes: 0, machine_bytes: 2} end,
         memory: fn -> 1 end,
         task_supervisor: __MODULE__.Tasks}
      )

    %{vitals: vitals, clock: clock}
  end

  defp at(c, ms), do: Agent.update(c.clock, fn _ -> ms end)

  # The worker slot's stored samples, after every message sent before: the
  # speed monitor's casts first (`:sys.get_state/1`), then the vitals process.
  defp worker_history(vitals) do
    _ = :sys.get_state(Speed)
    vitals |> :sys.get_state() |> get_in([:history, @cid, :worker]) |> List.wrap()
  end

  # One worker call: begins at `t0`, first token at `first`, ends at `to`.
  defp call(c, output, t0, first, to) do
    at(c, t0)
    h = Speed.begin(%{conversation_id: @cid, role: :worker}, "w")
    at(c, first)
    Speed.delta(h, 400)

    fn ->
      at(c, to)
      Speed.finish(h, {:ok, %{usage: %{output: output}}})
    end
  end

  test "repro (synced speed.ex): a finish beside a live call of its slot is never published", c do
    Speed.subscribe()
    finish_a = call(c, 100, 0, 0, 2_000)
    finish_b = call(c, 180, 0, 0, 3_000)
    # A finishes at 2 s while B has streamed for 2 s (a live estimate exists).
    finish_a.()
    finish_b.()

    published =
      collect([])
      |> Enum.flat_map(fn shown -> List.wrap(Map.get(shown, :worker)) end)
      |> Enum.filter(&(&1.live? == false))
      |> Enum.map(& &1.tps)

    # A's 50 tok/s was measured, but the live estimate of B hid it: only B's 60.
    assert published == [60]
    assert worker_history(c.vitals) == [60]
  end

  test "two calls finishing in the same second at the same rate are two bars", c do
    finish_a = call(c, 100, 0, 0, 2_000)
    finish_a.()
    assert worker_history(c.vitals) == [50]

    # Same model, same rate, same wall second; only the first-token time differs.
    finish_b = call(c, 100, 2_000, 2_100, 4_100)
    finish_b.()
    assert worker_history(c.vitals) == [50, 50]
  end

  test "each {:speed_call, …} is one bar, several between two ticks, none counted twice", c do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    value = fn tps, ttft -> %{tps: tps, ttft_ms: ttft, model: "w", at: now, live?: false} end

    for {tps, ttft} <- [{40, 300}, {40, 300}, {55, 310}, {61, 290}],
        do: send(c.vitals, {:speed_call, @cid, :worker, value.(tps, ttft)})

    assert worker_history(c.vitals) == [40, 40, 55, 61]

    # The speed monitor's own sample of the newest call is the same call.
    send(c.vitals, {:speed_sample, @cid, %{worker: value.(61, 290)}})
    assert worker_history(c.vitals) == [40, 40, 55, 61]

    # Malformed calls are ignored.
    send(c.vitals, {:speed_call, @cid, :nobody, value.(1, 1)})
    send(c.vitals, {:speed_call, @cid, :worker, %{tps: nil}})
    assert worker_history(c.vitals) == [40, 40, 55, 61]
  end

  defp collect(acc) do
    receive do
      {:speed_sample, @cid, shown} -> collect([shown | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end
end
