defmodule SwarmCode.Daemon.Service.R1019LiveRunsTest do
  @moduledoc """
  Pass 77 C-ARCH-11: `LiveRuns` is the one reader of the engine registry's run
  and chain entries.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend, only: [setup_world: 1, provider!: 3, eventually: 1]
  alias SwarmCode.Daemon.Service.LiveRuns
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("live-runs")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  test "all/0 and of_conversation/2 name a running chat run", c do
    owner = self()

    {conv, _, _} =
      provider!(c, c.conversation, fn _turn ->
        send(owner, {:held, self()})
        receive do: (:release -> :ok)
        {:text, "Done."}
      end)

    assert {:ok, run_id} = Engine.start_chat_turn(conv, "Hold")
    assert_receive {:held, response}, 5000

    assert %{run_id: ^run_id, conversation_id: conversation_id, kind: "chat", pid: pid} =
             Enum.find(LiveRuns.all(), &(&1.run_id == run_id))

    assert conversation_id == conv.id
    assert is_pid(pid)
    assert LiveRuns.of_conversation(conv.id, ["chat"]) == [{run_id, pid}]
    assert LiveRuns.of_conversation(conv.id, ["compact"]) == []
    assert conv.id in LiveRuns.conversation_ids()

    send(response, :release)
    assert eventually(fn -> LiveRuns.of_conversation(conv.id, ["chat"]) == [] end)
  end

  test "chains/1 lists the owner of a pending compaction chain", c do
    conv = c.conversation
    test = self()

    pid =
      start_supervised!(%{
        id: :chain_owner,
        start:
          {Task, :start_link,
           [
             fn ->
               {:ok, _} =
                 Registry.register(SwarmCode.Domain.Registry, {:chain, conv.id, "c1"}, nil)

               send(test, :registered)
               receive do: (:stop -> :ok)
             end
           ]},
        restart: :temporary
      })

    assert_receive :registered, 5000
    assert LiveRuns.chains(conv.id) == [{"c1", pid}]
    assert LiveRuns.chains("another-conversation") == []
  end
end
