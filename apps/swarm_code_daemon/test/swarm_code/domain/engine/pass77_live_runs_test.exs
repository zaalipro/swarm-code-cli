defmodule SwarmCode.Domain.Engine.Pass77LiveRunsTest do
  @moduledoc """
  pass 77 C-ARCH-11: `Engine.live_runs/0` lists every running run with its pid,
  conversation and kind in one registry read, so a caller that monitors runs does not
  need the registry's key/value shape.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.Engine
  alias SwarmCode.Domain.Engine.RunServer

  # A stand-in RunServer: registers the way `RunServer.start_link/1` does.
  defp start_run!(id, run_id, conversation_id, kind) do
    start_supervised!(
      %{
        id: id,
        start:
          {Agent, :start_link,
           [fn -> :ok end, [name: RunServer.via(run_id, {conversation_id, kind})]]}
      },
      id: id
    )
  end

  test "lists the pid, conversation and kind of every registered run" do
    run_a = "live-runs-a-#{System.unique_integer([:positive])}"
    run_b = "live-runs-b-#{System.unique_integer([:positive])}"
    pid_a = start_run!(:a, run_a, "conv-1", "chat")
    pid_b = start_run!(:b, run_b, "conv-2", "swarm")

    mine = Enum.filter(Engine.live_runs(), &(&1.run_id in [run_a, run_b]))

    assert Enum.sort_by(mine, & &1.run_id) == [
             %{run_id: run_a, pid: pid_a, conversation_id: "conv-1", kind: "chat"},
             %{run_id: run_b, pid: pid_b, conversation_id: "conv-2", kind: "swarm"}
           ]

    assert Enum.sort([run_a, run_b]) ==
             Enum.sort(Enum.filter(Engine.running_run_ids(), &(&1 in [run_a, run_b])))
  end

  test "a stopped run is gone from the list" do
    run_id = "live-runs-c-#{System.unique_integer([:positive])}"
    pid = start_run!(:c, run_id, "conv-3", "workflow")
    ref = Process.monitor(pid)

    assert Enum.any?(Engine.live_runs(), &(&1.run_id == run_id))

    :ok = stop_supervised(:c)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # Registry unregisters on the owner's exit; its own monitor may land a moment later.
    SwarmCode.Domain.Fixtures.eventually(fn ->
      not Enum.any?(Engine.live_runs(), &(&1.run_id == run_id))
    end)
  end
end
