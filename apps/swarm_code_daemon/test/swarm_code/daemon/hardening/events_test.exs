defmodule SwarmCode.Daemon.Hardening.EventsTest do
  @moduledoc """
  Hardening 13.1-13.3: the persisted backend hears the real producers of the
  rate-limit chip (`HTTP.capture_rate_limit/2`) and of standalone run totals
  (`Writes.add_run_usage/4`, `RunServer.add_usage/3` and its flush). Every
  event is broadcast by the producer; nothing is sent to the backend by hand.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Engine, LLM, Providers}
  alias SwarmCode.Domain.Conversations.Writes
  alias SwarmCode.Domain.Engine.RunServer
  alias SwarmCode.Domain.LLM.HTTP
  alias SwarmCode.Protocol.ServiceRequest
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    setup_world("events")
  end

  defp watch!(backend, scope, ref) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{"watch_ref" => ref, "slot" => "shell", "page_size" => 20, "byte_limit" => 262_144}
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), "watch-#{ref}", scope, request})

    send(backend, {:service_ready, self(), ref})
  end

  defp workspace_watch!(backend, scope, ref) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{
        "watch_ref" => ref,
        "slot" => "workspace",
        "page_size" => 50,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), "watch-#{ref}", scope, request})

    send(backend, {:service_ready, self(), ref})
  end

  # The next delta of `kind` on `ref`, acknowledged like a client does.
  defp next!(ref, kind, timeout \\ 3000) do
    assert_receive {:service_delta, backend, ^ref, %{"kind" => ^kind} = delta}, timeout
    send(backend, {:service_credit, self(), ref, delta["sequence"]})
    delta
  end

  defp ack_others!(ref) do
    receive do
      {:service_delta, backend, ^ref, delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})
        ack_others!(ref)
    after
      0 -> :ok
    end
  end

  defp provider! do
    {:ok, provider} =
      Providers.create(%{
        name: "events-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:9/v1",
        models: ["m"],
        default_model: "m"
      })

    provider
  end

  defp run!(c, status) do
    {:ok, conv} = Conversations.create(c.project.id)

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "chat",
        prompt: "Totals",
        status: status,
        started_at: DateTime.utc_now()
      })

    {conv, run}
  end

  defp projections(backend), do: :sys.get_state(backend).projections

  defp settled!(backend, tries \\ 400) do
    state = :sys.get_state(backend)

    cond do
      not state.refresh_pending ->
        state

      tries > 0 ->
        receive do
        after
          5 -> settled!(backend, tries - 1)
        end

      true ->
        flunk("the refresh never ran")
    end
  end

  describe "rate limits (13.1)" do
    test "the real capture reaches the shell watch once and unchanged state adds nothing", c do
      {:ok, conv} = Conversations.create(c.project.id)
      backend = start_backend(c, conv)
      provider = provider!()

      assert Registry.lookup(SwarmCode.Domain.PubSub, LLM.rate_limit_topic())
             |> Enum.any?(fn {pid, _} -> pid == backend end)

      watch!(backend, scope(conv), "shell")

      response = %Req.Response{
        headers: %{
          "x-ratelimit-limit-requests" => ["100"],
          "x-ratelimit-remaining-requests" => ["10"]
        }
      }

      assert %{used_percent: used} = HTTP.capture_rate_limit(response, provider.id)
      assert_in_delta used, 90.0, 0.01

      delta = next!("shell", "rate_limit")
      assert {:ok, %Delta{entity_id: id, body: %DTO.RateLimit{} = limit}} = Delta.decode(delta)
      assert id == provider.id
      assert {limit.provider, limit.scope} == {provider.name, "requests"}
      assert_in_delta limit.used_percent, 90.0, 0.01

      shown = :sys.get_state(backend).rate_limits

      # The same shown state: the producer stays silent and the backend adds nothing.
      assert %{used_percent: _} = HTTP.capture_rate_limit(response, provider.id)
      refute_receive {:service_delta, _, "shell", %{"kind" => "rate_limit"}}, 200
      assert :sys.get_state(backend).rate_limits == shown

      # A visibly different window is news again.
      busier = %Req.Response{
        headers: %{
          "x-ratelimit-limit-requests" => ["100"],
          "x-ratelimit-remaining-requests" => ["5"]
        }
      }

      HTTP.capture_rate_limit(busier, provider.id)
      next = next!("shell", "rate_limit")
      assert {:ok, %Delta{body: %DTO.RateLimit{used_percent: 95.0}}} = Delta.decode(next)
    end

    test "a stopped backend is no longer a subscriber of the topic", c do
      {:ok, conv} = Conversations.create(c.project.id)
      backend = start_backend(c, conv)
      ref = Process.monitor(backend)

      topic = LLM.rate_limit_topic()
      assert Enum.any?(Registry.lookup(SwarmCode.Domain.PubSub, topic), &(elem(&1, 0) == backend))

      GenServer.stop(backend, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^backend, _}, 5000

      refute Enum.any?(Registry.lookup(SwarmCode.Domain.PubSub, topic), &(elem(&1, 0) == backend))
    end
  end

  describe "standalone run totals (13.2, 13.3)" do
    test "late label usage on a finished run reads the row once per burst", c do
      {conv, run} = run!(c, "done")
      backend = start_backend(c, conv)
      _ = workspace(backend, scope(conv))
      workspace_watch!(backend, scope(conv), "ws")
      ack_others!("ws")
      settled!(backend)

      before = projections(backend)

      assert :ok = Writes.add_run_usage(run.id, 7, 11, 0.25)
      delta = next!("ws", "run_update")
      assert delta["body"]["id"] == run.id
      assert {delta["body"]["tokens_in"], delta["body"]["tokens_out"]} == {7, 11}
      assert_in_delta delta["body"]["cost_usd"], 0.25, 1.0e-9

      after_one = settled!(backend).projections
      assert after_one.partial == before.partial + 1
      assert after_one.full == before.full

      # Two more increments before the timer fires are one reread of the row.
      ack_others!("ws")
      assert :ok = Writes.add_run_usage(run.id, 3, 2, 0.5)
      assert :ok = Writes.add_run_usage(run.id, 1, 1, 0.0)
      delta = next!("ws", "run_update")

      assert {delta["body"]["tokens_in"], delta["body"]["tokens_out"]} == {11, 14}
      assert_in_delta delta["body"]["cost_usd"], 0.75, 1.0e-9

      final = settled!(backend).projections
      assert final.partial == after_one.partial + 1
      assert final.full == after_one.full

      # Absolute totals: the row, never a sum of event payloads.
      row = Conversations.get_run(run.id)
      assert {row.tokens_in, row.tokens_out} == {11, 14}
    end

    test "a totals event shares one partial reload with a node update", c do
      {conv, run} = run!(c, "running")

      {:ok, agent} =
        Conversations.insert_node(%{
          run_id: run.id,
          kind: "agent",
          role: "lead",
          name: "lead",
          status: "running",
          started_at: DateTime.utc_now()
        })

      backend = start_backend(c, conv)
      _ = workspace(backend, scope(conv))
      workspace_watch!(backend, scope(conv), "ws")
      ack_others!("ws")
      settled!(backend)
      before = projections(backend)

      {:ok, _} = Conversations.update_node(agent, %{progress: 40})

      SwarmCode.Domain.Engine.Events.broadcast(
        conv.id,
        {:nodes_patch, run.id, [{agent.id, %{progress: 40}}]}
      )

      assert :ok = Writes.add_run_usage(run.id, 4, 5, 0.0)

      settled = settled!(backend)
      assert settled.projections.partial == before.partial + 1
      assert settled.projections.full == before.full
      assert {settled.runs[run.id].tokens_in, settled.runs[run.id].tokens_out} == {4, 5}
    end

    test "a run this service does not hold fabricates no row and no refresh", c do
      {conv, _run} = run!(c, "done")
      backend = start_backend(c, conv)
      _ = workspace(backend, scope(conv))
      settled!(backend)
      before = :sys.get_state(backend)

      {other, foreign} = run!(c, "done")
      assert other.id != conv.id
      assert :ok = Writes.add_run_usage(foreign.id, 9, 9, 0.0)
      # The foreign conversation's topic is not ours; a held-run check also
      # guards a totals event that does arrive for an unknown id.
      Engine.Events.broadcast(
        conv.id,
        {:run_totals, foreign.id, %{tokens_in: 9, tokens_out: 9, cost_usd: nil}}
      )

      refute_receive {:service_delta, _, _, _}, 150
      state = settled!(backend)
      assert state.runs == before.runs
      assert state.projections.partial == before.projections.partial
      assert state.refresh_pending == false
    end

    test "a live run's one-shot usage and its flush reach the watch as absolute totals", c do
      {conv, _provider, _server} =
        provider!(c, conv_for(c), fn _ -> :hang end)

      backend = start_backend(c, conv)

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               send_text(backend, scope(conv), "hello")

      assert eventually(fn -> Engine.running_runs(conv.id) != [] end)
      [run_id | _] = Engine.running_runs(conv.id)
      on_exit(fn -> Engine.stop_run(run_id) end)

      _ = workspace(backend, scope(conv))
      workspace_watch!(backend, scope(conv), "ws")
      assert eventually(fn -> :sys.get_state(backend).runs[run_id] != nil end)
      ack_others!("ws")
      settled!(backend)
      before = projections(backend)

      assert :ok = RunServer.add_usage(run_id, %{input: 5, output: 3}, 0.5)
      assert :ok = RunServer.add_usage(run_id, %{input: 2, output: 1}, nil)

      assert eventually(fn ->
               row = Conversations.get_run(run_id)
               {row.tokens_in, row.tokens_out} == {7, 4}
             end)

      assert eventually(fn ->
               run = :sys.get_state(backend).runs[run_id]
               {run.tokens_in, run.tokens_out} == {7, 4}
             end)

      row = Conversations.get_run(run_id)
      assert_in_delta row.cost_usd, 0.5, 1.0e-9
      assert :sys.get_state(backend).runs[run_id].cost_usd == row.cost_usd
      now = projections(backend)
      assert now.partial + now.full > before.partial + before.full
    end
  end

  defp conv_for(c) do
    {:ok, conv} = Conversations.create(c.project.id)
    conv
  end
end
