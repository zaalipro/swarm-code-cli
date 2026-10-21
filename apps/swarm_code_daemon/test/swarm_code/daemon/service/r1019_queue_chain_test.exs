defmodule SwarmCode.Daemon.Service.R1019QueueChainTest do
  @moduledoc """
  Pass 77 C-BUG-6: after an automatic compaction the engine starts the
  waiting turn from a chain task. Between the compaction's end and that turn's
  registration neither is in the registry as a run, so the queue used to see an
  idle conversation and start a queued prompt ahead of the user's message. The
  chain owner now counts as a turn: the drain waits for it.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.QueueState
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("queue-chain")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  test "a queued prompt waits for a pending compaction chain, then starts", c do
    {conv, _, _} = provider!(c, c.conversation, fn _turn -> {:text, "Done."} end)
    test = self()

    owner =
      start_supervised!(%{
        id: :chain_owner,
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, _} =
                 Registry.register(SwarmCode.Domain.Registry, {:chain, conv.id, "x"}, nil)

               send(test, :chain_registered)
               receive do: (:finish -> :ok)
             end
           ]},
        restart: :temporary
      })

    assert_receive :chain_registered, 5000
    monitor = Process.monitor(owner)

    {:ok, _} = Conversations.set_queued(Conversations.get!(conv.id), ["b"])
    backend = start_backend(c, conv)
    send(backend, {:drain_queue, conv.id})
    _ = :sys.get_state(backend)

    # The chain is a turn: nothing was popped and the owner is being watched.
    assert Conversations.get(conv.id).queued == ["b"]
    assert Engine.running_runs(conv.id) == []
    entry = QueueState.entry(:sys.get_state(backend).queues, conv.id)
    assert [{_ref, ^owner}] = Map.to_list(entry.monitors)

    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5000

    assert eventually(fn -> Conversations.get(conv.id).queued == [] end)

    assert eventually(fn ->
             conv.id |> Conversations.list_runs() |> Enum.any?(&(&1.prompt == "b"))
           end)
  end
end
