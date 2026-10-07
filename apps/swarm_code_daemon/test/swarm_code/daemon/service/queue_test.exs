defmodule SwarmCode.Daemon.Service.QueueTest do
  @moduledoc """
  cli020 C1 (bugs-7, bugs-17): the conversation's queue survives a switch and a
  restart, a stop the user asked for pauses it, `queue.resume` drains it, and
  `queue.edit` clears it or drops one prompt under a full-text revision.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("queue")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  defp prompts(conversation_id),
    do: conversation_id |> Conversations.list_runs() |> Enum.map(& &1.prompt)

  test "the revision is the first 16 hex of sha256 over the unit-separated texts" do
    expected =
      :crypto.hash(:sha256, "a\x1fb") |> Base.encode16(case: :lower) |> binary_part(0, 16)

    assert Backend.queue_revision(["a", "b"]) == expected
    assert byte_size(Backend.queue_revision([])) == 16
  end

  test "a queued prompt drains when its conversation is opened again", c do
    {conv, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Hi."} end)
    {:ok, other} = Conversations.create(c.project.id)
    backend = start_backend(c, other)
    {:ok, _} = Conversations.set_queued(Conversations.get!(conv.id), ["Queued hello"])

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(backend, "open", scope(other), :conversation_open, %{
               "conversation_id" => conv.id
             })

    assert eventually(fn -> "Queued hello" in prompts(conv.id) end)
    assert Conversations.get(conv.id).queued == []
  end

  test "a queued prompt drains when the backend starts again", c do
    {conv, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Hi."} end)
    {:ok, _} = Conversations.set_queued(Conversations.get!(conv.id), ["After restart"])
    _backend = start_backend(c, conv)
    assert eventually(fn -> "After restart" in prompts(conv.id) end)
  end

  test "a stop the user asked for pauses the queue; queue.resume drains it", c do
    {conv, _, _} = provider!(c, c.conversation, command_then_text("touch c1-pause.txt"))
    backend = start_backend(c, conv)
    s = scope(conv)

    assert {:ok, %{"value" => %{"identifiers" => [run]}}} = send_text(backend, s, "Run it")
    assert eventually(fn -> pending_approvals(backend, s) != [] end)

    assert {:ok, %{"value" => %{"disposition" => "queued"}}} =
             send_text(backend, s, "Then this", "queue")

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(backend, "stop", s, :run_control, %{"run_id" => run, "action" => "stop"})

    assert eventually(fn -> not Engine.chat_running?(conv.id) end)
    # The queue waits: nothing new started, the workspace says it is paused.
    assert eventually(fn -> workspace(backend, s)["queue_paused"] == true end)
    assert Conversations.get(conv.id).queued == ["Then this"]
    assert workspace(backend, s)["queued_count"] == 1
    refute "Then this" in prompts(conv.id)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(backend, "resume", s, :queue_resume, %{})

    assert eventually(fn -> "Then this" in prompts(conv.id) end)
    assert workspace(backend, s)["queue_paused"] == false
  end

  test "queue.edit drops one prompt and clears; a stale revision is refused", c do
    {conv, _, _} = provider!(c, c.conversation, command_then_text("touch c1-edit.txt"))
    backend = start_backend(c, conv)
    s = scope(conv)
    assert {:ok, _} = send_text(backend, s, "Hold the turn")
    assert eventually(fn -> pending_approvals(backend, s) != [] end)

    for text <- ["one", "two", "three"], do: send_text(backend, s, text, "queue")
    assert Conversations.get(conv.id).queued == ["one", "two", "three"]
    revision = workspace(backend, s)["queue_revision"]
    assert revision == Backend.queue_revision(["one", "two", "three"])

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(backend, "drop", s, :queue_edit, %{
               "revision" => revision,
               "action" => "drop",
               "position" => 1
             })

    assert Conversations.get(conv.id).queued == ["two", "three"]

    # The old revision no longer names the queue.
    assert {:ok, %{"value" => %{"status" => "rejected", "reason" => reason}}} =
             command(backend, "stale", s, :queue_edit, %{
               "revision" => revision,
               "action" => "clear",
               "position" => nil
             })

    assert reason == %{"code" => "stale", "text" => "The queue changed · look again."}
    assert Conversations.get(conv.id).queued == ["two", "three"]

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(backend, "clear", s, :queue_edit, %{
               "revision" => Backend.queue_revision(["two", "three"]),
               "action" => "clear",
               "position" => nil
             })

    assert Conversations.get(conv.id).queued == []
    assert eventually(fn -> workspace(backend, s)["queued_count"] == 0 end)
  end
end
