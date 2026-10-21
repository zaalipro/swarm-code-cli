defmodule SwarmCodeCLI.Release.R1019DetachRunsTest do
  @moduledoc """
  Review 1019 RC-4 / RC-5 on the real engine registry: what a hang-up with live
  runs waits for. A run paused by hand cannot move without the terminal, so it
  is not progressing; a pending compaction chain starts the user's turn, so it
  is, even while no run is registered.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000
  @moduletag :capture_log

  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCode.Test.C020Backend, as: Fixture
  alias SwarmCodeCLI.Release.Detach

  setup do
    world = Fixture.setup_world("detach-runs")
    {:ok, conversation} = Conversations.create(world.project.id)
    %{world: world, conversation: conversation}
  end

  # A chat run whose model request is held until the test releases it.
  defp live_run(c) do
    test = self()

    {conversation, _, _} =
      Fixture.provider!(c.world, c.conversation, fn _turn ->
        send(test, {:held, self()})
        receive(do: (:release -> :ok))
        {:text, "Done."}
      end)

    {:ok, run_id} = Engine.start_chat_turn(conversation, "work", [])
    assert_receive {:held, handler}, 15_000
    {run_id, handler}
  end

  test "a live run is progressing until it is paused by hand", c do
    {run_id, handler} = live_run(c)
    assert Detach.progressing?()

    assert :ok = Engine.pause_run(run_id)
    assert Conversations.run_status(run_id) == "paused"
    refute Detach.progressing?()

    assert :ok = Engine.continue_run(run_id)
    assert Detach.progressing?()

    send(handler, :release)
    assert Fixture.eventually(fn -> not Detach.progressing?() end)
    Engine.stop_all(c.conversation.id)
  end

  test "the wait settles on a paused run without another signal", c do
    {run_id, _handler} = live_run(c)
    assert :ok = Engine.pause_run(run_id)

    task = Task.async(fn -> Detach.await(recheck_ms: 20) end)
    assert Task.await(task, 10_000) == :settled
    # The run was left to the session's normal close.
    assert Engine.running_run_ids() == [run_id]
    Engine.stop_all(c.conversation.id)
  end

  test "a pending compaction chain is progressing while no run is registered", c do
    test = self()

    owner =
      start_supervised!(%{
        id: :chain_owner,
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, _} =
                 Registry.register(
                   SwarmCode.Domain.Registry,
                   {:chain, c.conversation.id, "compaction"},
                   nil
                 )

               send(test, :chain_registered)
               receive do: (:finish -> :ok)
             end
           ]},
        restart: :temporary
      })

    assert_receive :chain_registered, 5_000
    assert Engine.running_run_ids() == []
    assert Detach.progressing?()

    # The wait does not return while the chain is pending, and does once it has ended.
    task = Task.async(fn -> Detach.await(recheck_ms: 20) end)
    assert Task.yield(task, 200) == nil

    monitor = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
    assert Task.await(task, 10_000) == :settled
    refute Detach.progressing?()
  end
end
