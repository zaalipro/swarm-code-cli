defmodule SwarmCode.Daemon.Service.Pass76CompactChainOwnerTest do
  @moduledoc """
  A chat turn started on behalf of a run (`launched_by_run_id:`, what a
  finished workflow's continuation passes) after the conversation asked for an
  automatic compaction: the compaction run records that run as its launcher,
  the chain task that starts the turn carries its id (so
  `RunProcesses.pending?/1` answers for it while only the task holds the
  launch), and the turn, once written, records it too. A turn started for
  nobody (a user's own send) leaves all of that empty.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias SwarmCode.Daemon.Service.RunProcesses
  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCode.Test.C020Backend, as: Fixture
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup do
    test = self()
    world = Fixture.setup_world("compact-owner")
    {:ok, conversation} = Conversations.create(world.project.id)
    on_exit(fn -> Engine.stop_all(conversation.id) end)

    server =
      HTTP.start(fn socket, request, _turn ->
        last = request.body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()

        if String.contains?(Jason.encode!(last), "Compact this conversation") do
          send(test, {:compactor_held, self()})
          receive(do: (:release -> :ok))
          answer(socket, "## Goal\nsummary")
        else
          answer(socket, "the turn")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      SwarmCode.Domain.Providers.create(%{
        name: "owner-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, conversation} =
      Conversations.update(conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    for {role, content} <- [{"user", "earlier ask"}, {"assistant", "earlier answer"}] do
      {:ok, _} =
        Conversations.create_message(%{
          conversation_id: conversation.id,
          role: role,
          content: content
        })
    end

    :ok = Conversations.mark_compact_due(conversation.id)
    %{conversation: conversation}
  end

  defp answer(socket, text) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => "stop"}]
      })
    ])
  end

  defp runs(c, kind),
    do: Enum.filter(Conversations.list_runs(c.conversation.id), &(&1.kind == kind))

  defp chain_value(compaction_id) do
    SwarmCode.Domain.Registry
    |> Registry.select([{{{:chain, :_, compaction_id}, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.at(0)
  end

  test "the compaction, the chain and the turn all name the run they continue", c do
    owner = Ecto.UUID.generate()

    assert {:ok, compaction_id} =
             Engine.start_chat_turn(c.conversation, "[workflow finished]", [],
               store_user: false,
               launched_by_run_id: owner
             )

    assert_receive {:compactor_held, compactor}, 15_000
    assert %{kind: "compact", launched_by_run_id: ^owner} = Conversations.get_run(compaction_id)
    assert chain_value(compaction_id) == owner
    assert RunProcesses.chained?(owner) and RunProcesses.pending?(owner)
    refute RunProcesses.chained?(Ecto.UUID.generate())

    send(compactor, :release)

    assert Fixture.eventually(fn -> not RunProcesses.pending?(owner) end)
    assert [%{status: "done", launched_by_run_id: ^owner}] = runs(c, "chat")
    assert [%{status: "done", launched_by_run_id: ^owner}] = runs(c, "compact")
  end

  test "a turn started for nobody leaves the chain without an owner", c do
    assert {:ok, compaction_id} = Engine.start_chat_turn(c.conversation, "and then?")

    assert_receive {:compactor_held, compactor}, 15_000
    assert %{kind: "compact", launched_by_run_id: nil} = Conversations.get_run(compaction_id)
    assert chain_value(compaction_id) == nil

    send(compactor, :release)
    assert Fixture.eventually(fn -> [] != runs(c, "chat") end)
  end
end
