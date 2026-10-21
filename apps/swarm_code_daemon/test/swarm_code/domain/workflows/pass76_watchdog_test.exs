defmodule SwarmCode.Domain.Workflows.Pass76WatchdogTest do
  # pass76 llm-watchdog: the probe runs in owned work, so a hanging or exiting
  # probe cannot stall or crash the watchdog, and parked runs of one model
  # resume one after another.
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.LLM.Gate
  alias SwarmCode.Domain.Workflows.Runner.Watchdog

  @model %{provider: %{id: "wd-provider-pass76"}, model: "m"}

  defp wfs(n), do: for(i <- 1..n//1, do: %{run_id: "run-#{i}", display_name: "wf#{i}"})

  defp start_watchdog(test_pid, opts) do
    group = %{key: {"wd-provider-pass76", "m"}, model: @model, wfs: opts[:wfs] || wfs(0)}

    defaults = [
      interval: 3_600_000,
      list_fun: fn -> [group] end,
      probe_fun: fn _model -> :ok end,
      resume_fun: fn wf ->
        send(test_pid, {:resumed, wf.run_id, System.monotonic_time(:millisecond)})
        :ok
      end
    ]

    start_supervised!({Watchdog, Keyword.merge(defaults, Keyword.delete(opts, :wfs))})
  end

  defp jobs(pid), do: :sys.get_state(pid).jobs

  defp wait_idle(pid, tries \\ 200) do
    cond do
      map_size(jobs(pid)) == 0 -> :ok
      tries == 0 -> flunk("watchdog still has jobs: #{inspect(jobs(pid))}")
      true -> Process.sleep(10) && wait_idle(pid, tries - 1)
    end
  end

  test "a hanging probe is cut off at its timeout and the next tick probes again" do
    test_pid = self()

    pid =
      start_watchdog(test_pid,
        probe_timeout: 100,
        probe_fun: fn _model ->
          send(test_pid, {:probing, self()})
          Process.sleep(:infinity)
        end
      )

    send(pid, :tick)
    assert_receive {:probing, probe_pid}, 2_000
    ref = Process.monitor(probe_pid)

    # the watchdog answers while the probe hangs
    assert map_size(jobs(pid)) == 1

    assert_receive {:DOWN, ^ref, :process, ^probe_pid, _}, 2_000
    wait_idle(pid)

    send(pid, :tick)
    assert_receive {:probing, second}, 2_000
    assert second != probe_pid
    assert Process.alive?(pid)
  end

  test "a probe that exits does not crash the watchdog and resumes nothing" do
    test_pid = self()

    pid =
      start_watchdog(test_pid,
        wfs: wfs(2),
        probe_fun: fn _model -> exit(:gate_down) end
      )

    send(pid, :tick)
    wait_idle(pid)
    refute_received {:resumed, _, _}
    assert Process.alive?(pid)

    # the next round still works
    :sys.replace_state(pid, fn state ->
      %{state | funs: %{state.funs | probe: fn _ -> :ok end}}
    end)

    send(pid, :tick)
    assert_receive {:resumed, "run-1", _}, 2_000
  end

  test "parked runs on one model resume spread over the stagger interval" do
    test_pid = self()
    pid = start_watchdog(test_pid, wfs: wfs(3), stagger: 80)

    send(pid, :tick)
    assert_receive {:resumed, "run-1", t1}, 2_000
    assert_receive {:resumed, "run-2", t2}, 2_000
    assert_receive {:resumed, "run-3", t3}, 2_000

    assert t2 - t1 >= 70
    assert t3 - t2 >= 70
  end

  test "killing the watchdog takes a hanging probe and a delayed resume batch with it" do
    test_pid = self()
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      Watchdog.start_link(
        interval: 3_600_000,
        stagger: 400,
        list_fun: fn ->
          [
            %{key: :a, model: @model, wfs: wfs(3)},
            %{key: :b, model: %{@model | model: "n"}, wfs: []}
          ]
        end,
        probe_fun: fn
          %{model: "n"} ->
            send(test_pid, {:probing, self()})
            Process.sleep(:infinity)

          _ ->
            :ok
        end,
        resume_fun: fn wf ->
          send(test_pid, {:resumed, wf.run_id, self()})
          :ok
        end
      )

    send(pid, :tick)
    assert_receive {:probing, probe_pid}, 2_000
    assert_receive {:resumed, "run-1", resumer}, 2_000

    refs = for p <- [probe_pid, resumer], do: {p, Process.monitor(p)}
    Process.exit(pid, :kill)

    for {p, ref} <- refs, do: assert_receive({:DOWN, ^ref, :process, ^p, _}, 2_000)
    refute_receive {:resumed, _, _}, 900
  end

  test "a resume waits for the provider's rate-limit cooldown" do
    test_pid = self()
    key = "wd-provider-pass76"
    until = System.monotonic_time(:millisecond) + 150
    Gate.cool_down(key, until)
    on_exit(fn -> :ets.delete(:swarm_code_llm_cooldown, key) end)

    pid = start_watchdog(test_pid, wfs: wfs(1), stagger: 0)
    send(pid, :tick)
    assert_receive {:resumed, "run-1", at}, 2_000
    assert at >= until - 5
  end
end
