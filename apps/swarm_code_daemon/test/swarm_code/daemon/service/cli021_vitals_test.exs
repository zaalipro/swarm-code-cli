defmodule SwarmCode.Daemon.Service.Cli021VitalsTest do
  @moduledoc """
  cli021 C2: the vitals process measures only while a client watches, keeps a
  12-sample history per slot from the speed monitor's finished calls, sends at
  most one update a second and only when something shown changed.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.Vitals
  alias SwarmCode.Daemon.Service.Vitals.OsMemory

  @cid "5f3c4c52-0d6a-4d1e-9f6e-0a8f6a3f1111"

  setup do
    start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    {:ok, speed} = Agent.start_link(fn -> %{} end)
    test = self()

    config = fn cid ->
      send(test, {:config_read, cid})

      %{
        mode: :two,
        main: "main-model",
        worker: "worker-model",
        validator: "main-model",
        others: []
      }
    end

    sampler = fn opts ->
      send(test, {:sampled, opts})

      %{
        os_rss_bytes: 300 * 1_048_576,
        children_rss_bytes: 40 * 1_048_576,
        machine_bytes: 16 * 1_073_741_824
      }
    end

    vitals =
      start_supervised!(
        {Vitals,
         subscriber: self(),
         conversation_id: @cid,
         speed: fn _cid -> Agent.get(speed, & &1) end,
         config: config,
         sampler: sampler,
         memory: fn -> 280 * 1_048_576 end,
         task_supervisor: __MODULE__.Tasks}
      )

    %{vitals: vitals, speed: speed}
  end

  defp exact(tps, at),
    do: %{tps: tps, ttft_ms: 400, model: "main-model", at: at, live?: false}

  test "nothing is measured or sent until a client watches", c do
    refute_receive {:vitals, _}, 150
    refute_received {:config_read, _}
    refute_received {:sampled, _}

    body = Vitals.body(c.vitals)
    assert body["conversation_id"] == @cid
    # no model name is known before the first read: nothing to list yet
    assert body["models"] == []
  end

  test "the first update names the slots, the speed and the memory", c do
    Agent.update(c.speed, fn _ ->
      %{
        main: exact(61, ~U[2026-10-08 10:00:00Z]),
        worker: %{exact(30, ~U[2026-10-08 10:00:01Z]) | model: "worker-model"}
      }
    end)

    Vitals.demand(c.vitals, true)
    assert_receive {:sampled, [machine: true]}, 1_000
    assert_receive {:config_read, @cid}, 1_000

    body = await_body(fn body -> body["os_rss_bytes"] != nil and length(body["models"]) == 2 end)

    assert [main, worker] = body["models"]

    assert {main["slot"], main["model"], main["tps"], main["live"]} ==
             {"main", "main-model", 61, false}

    assert {worker["slot"], worker["model"], worker["tps"]} == {"worker", "worker-model", 30}
    assert main["history"] == [61] and main["at"] == 1_791_453_600_000
    assert body["os_rss_bytes"] == 300 * 1_048_576
    assert body["children_rss_bytes"] == 40 * 1_048_576
    assert body["machine_bytes"] == 16 * 1_073_741_824
    assert body["beam_bytes"] == 280 * 1_048_576
  end

  test "the history keeps the last 12 finished calls; an estimate is shown, never stored", c do
    Vitals.demand(c.vitals, true)
    assert_receive {:vitals, _}, 1_000

    for n <- 1..14 do
      shown = %{main: exact(n, DateTime.add(~U[2026-10-08 10:00:00Z], n, :second))}
      Agent.update(c.speed, fn _ -> shown end)
      send(c.vitals, {:speed_sample, @cid, shown})
    end

    body = await_body(fn body -> hd(body["models"])["history"] == Enum.to_list(3..14) end)
    assert hd(body["models"])["tps"] == 14

    live = %{main: %{tps: 90, ttft_ms: 300, model: "main-model", at: nil, live?: true}}
    Agent.update(c.speed, fn _ -> live end)
    send(c.vitals, {:speed_sample, @cid, live})

    body = await_body(fn body -> hd(body["models"])["live"] == true end)
    main = hd(body["models"])
    assert main["tps"] == 90 and main["at"] == nil
    assert main["history"] == Enum.to_list(4..14) ++ [90]
    # the stored history is untouched by the estimate
    assert Enum.take(Vitals.body(c.vitals)["models"], 1) |> hd() |> Map.get("history") ==
             Enum.to_list(4..14) ++ [90]
  end

  test "an update is never sooner than a second after the last, and only for a change", c do
    Vitals.demand(c.vitals, true)
    assert_receive {:vitals, _first}, 1_000

    shown = %{main: exact(77, ~U[2026-10-08 10:00:00Z])}
    Agent.update(c.speed, fn _ -> shown end)
    send(c.vitals, {:speed_sample, @cid, shown})

    refute_receive {:vitals, _}, 600
    assert_receive {:vitals, %{"models" => [%{"tps" => 77} | _]}}, 1_200

    # nothing changed: nothing is sent
    refute_receive {:vitals, _}, 1_300
  end

  test "stopping the demand stops the updates; a refocus reads the new conversation", c do
    Vitals.demand(c.vitals, true)
    assert_receive {:vitals, _}, 1_000
    Vitals.demand(c.vitals, false)

    shown = %{main: exact(12, ~U[2026-10-08 10:00:00Z])}
    Agent.update(c.speed, fn _ -> shown end)
    send(c.vitals, {:speed_sample, @cid, shown})
    refute_receive {:vitals, _}, 1_300

    other = "6a4d5d63-1e7b-4e2f-8a7f-1b9a7b4a2222"
    Vitals.demand(c.vitals, true)
    Vitals.focus(c.vitals, other)
    assert_receive {:config_read, ^other}, 1_500
    assert_receive {:vitals, %{"conversation_id" => ^other}}, 2_500
  end

  test "a model name is cut at a character, within the wire's 256 bytes", c do
    long = String.duplicate("é", 200)

    Agent.update(c.speed, fn _ -> %{main: %{exact(5, ~U[2026-10-08 10:00:00Z]) | model: long}} end)

    Vitals.demand(c.vitals, true)
    body = await_body(fn body -> hd(body["models"])["tps"] == 5 end)
    model = hd(body["models"])["model"]
    assert byte_size(model) <= 256 and String.valid?(model) and String.starts_with?(long, model)
  end

  describe "OsMemory" do
    @table """
        1     0  1200 /sbin/launchd
      500     1 90000 /app/beam.smp
      501   500  8000 /app/swarm-terminal-port
      502   500  2000 /bin/sh
      503   502   400 /bin/ps
      900     1  7000 /usr/bin/other
    """

    test "the VM's resident bytes and its descendants' (the ps itself left out)" do
      rows = OsMemory.parse_ps(@table)
      assert length(rows) == 6
      assert OsMemory.split(rows, 500) == {90_000 * 1024, (8_000 + 2_000) * 1024}
      assert OsMemory.split(rows, 4242) == {nil, 0}
    end

    test "a line that is not a process row is skipped" do
      assert OsMemory.parse_ps("garbage\n  12  1  100 /x\nnot numbers here now\n") ==
               [{12, 1, 100, "/x"}]
    end

    test "the live reading finds this VM" do
      reading = OsMemory.read(machine: false)
      assert reading.os_rss_bytes > 1_000_000
      assert is_integer(reading.children_rss_bytes)
      assert reading.machine_bytes == nil
    end
  end

  defp await_body(done?) do
    receive do
      {:vitals, body} -> if done?.(body), do: body, else: await_body(done?)
    after
      3_000 -> flunk("no matching vitals update")
    end
  end
end
