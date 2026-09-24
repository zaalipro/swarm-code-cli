defmodule SwarmCode.Daemon.Service.Pass72SteerTargetTest do
  @moduledoc """
  pass72 G11 (QA Q12): a steer from the agent overlay (`node_id:`) reaches
  that agent's server and no other; without a node it reaches the Lead.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Engine.RunServer

  # A stand-in AgentServer: it reports every cast to the test, tagged.
  defp agent(name) do
    test = self()

    pid =
      spawn_link(fn ->
        loop = fn loop ->
          receive do
            {:"$gen_cast", message} ->
              send(test, {name, message})
              loop.(loop)

            :stop ->
              :ok
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> send(pid, :stop) end)
    %{server: pid, result: nil}
  end

  defp state do
    %{
      root_node_id: "lead",
      agents: %{"lead" => agent(:lead), "plugs" => agent(:plugs), "views" => agent(:views)}
    }
  end

  test "a steer with a node reaches only that agent" do
    state = state()

    assert {:reply, :ok, ^state} =
             RunServer.handle_call({:steer, "mention PINEAPPLE", [], "plugs"}, nil, state)

    assert_receive {:plugs, {:user_message, "mention PINEAPPLE", []}}
    refute_receive {:lead, _}, 100
    refute_receive {:views, _}, 10
  end

  test "a steer without a node reaches the Lead" do
    state = state()
    assert {:reply, :ok, _} = RunServer.handle_call({:steer, "go on", [], nil}, nil, state)
    assert_receive {:lead, {:user_message, "go on", []}}
    refute_receive {:plugs, _}, 100
  end

  test "a finished agent is not steered" do
    state = put_in(state().agents["plugs"].result, "done")

    assert {:reply, {:error, :finished}, _} =
             RunServer.handle_call({:steer, "late", [], "plugs"}, nil, state)
  end
end
