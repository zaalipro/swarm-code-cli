defmodule SwarmCode.Daemon.Service.RewindTest do
  @moduledoc """
  cli020 C16 (competitors-8, decision 4h): rewind the conversation, its
  files, or both, to before a turn (loopback model, fixture project).
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("rewind")
  end

  # Three turns; the second writes notes.txt (v1 before it, v2 after).
  defp three_turns(c) do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    file = Path.join(c.root, "notes-#{System.unique_integer([:positive])}.txt")
    File.write!(file, "v1")

    {conv, _, _} =
      provider!(c, conv, fn
        1 -> {:text, "one"}
        2 -> {:tool, "write_file", %{"path" => Path.basename(file), "content" => "v2"}}
        3 -> {:text, "wrote"}
        4 -> {:text, "three"}
        _ -> :hang
      end)

    backend = start_backend(c, conv)

    for text <- ["first", "second", "third"] do
      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               send_text(backend, scope(conv), text)

      assert eventually(fn -> Engine.running_runs(conv.id) == [] and settled?(conv, text) end)
    end

    assert File.read!(file) == "v2"
    %{conv: conv, backend: backend, file: file}
  end

  defp settled?(conv, text) do
    Enum.any?(Conversations.list_runs(conv.id), &(&1.prompt == text and &1.status == "done"))
  end

  defp turns(t) do
    assert {:ok, %{"value" => %{"status" => "accepted", "result" => result}}} =
             command(t.backend, id("turns"), scope(t.conv), :rewind_turns, %{})

    result["turns"]
  end

  defp rewind(t, message_id, scope) do
    command(t.backend, id("rewind"), scope(t.conv), :rewind_apply, %{
      "message_id" => message_id,
      "scope" => scope
    })
  end

  defp live_prompts(conv),
    do:
      for(
        m <- Conversations.list_messages(conv.id),
        m.role == "user",
        is_nil(m.superseded_at),
        do: m.content
      )

  test "rewind.turns lists the turns newest first with their file counts", c do
    t = three_turns(c)
    assert [third, second, first] = turns(t)
    assert {third["prompt"], second["prompt"], first["prompt"]} == {"third", "second", "first"}
    assert {third["turn"], second["turn"], first["turn"]} == {3, 2, 1}
    assert {second["files"], first["files"]} == {1, 0}
  end

  test "both: turns 2 and 3 fold, the file comes back, the prompt returns", c do
    t = three_turns(c)
    [_, second, _] = turns(t)

    assert {:ok, %{"value" => %{"status" => "accepted", "result" => result}}} =
             rewind(t, second["message_id"], "both")

    assert %{"kind" => "rewound", "text" => "second", "restored" => 1} = result
    assert live_prompts(t.conv) == ["first"]
    assert File.read!(t.file) == "v1"
    assert Enum.any?(Conversations.list_messages(t.conv.id), &(&1.content =~ "Rewound 1 file"))
  end

  test "both: a run a rewound turn launched folds with it (supersede_from/2)", c do
    t = three_turns(c)
    [_, second, _] = turns(t)
    parent = Enum.find(Conversations.list_runs(t.conv.id), &(&1.prompt == "second"))

    {:ok, child} =
      Conversations.create_run(%{
        conversation_id: t.conv.id,
        kind: "swarm",
        prompt: "launched by the second turn",
        status: "done",
        launched_by_run_id: parent.id,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             rewind(t, second["message_id"], "both")

    folded = Enum.find(Conversations.list_runs(t.conv.id), &(&1.id == child.id))
    assert folded.superseded_at
  end

  test "conversation leaves the file; files leaves the messages", c do
    t = three_turns(c)
    [_, second, _] = turns(t)

    assert {:ok, %{"value" => %{"result" => %{"restored" => 0, "text" => "second"}}}} =
             rewind(t, second["message_id"], "conversation")

    assert File.read!(t.file) == "v2"
    assert live_prompts(t.conv) == ["first"]

    t2 = three_turns(c)
    [_, second2, _] = turns(t2)

    assert {:ok, %{"value" => %{"result" => %{"restored" => 1, "text" => nil}}}} =
             rewind(t2, second2["message_id"], "files")

    assert File.read!(t2.file) == "v1"
    assert live_prompts(t2.conv) == ["first", "second", "third"]
  end

  test "an unknown message is refused", c do
    t = three_turns(c)

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             rewind(t, Ecto.UUID.generate(), "both")
  end

  test "a live run of a later turn is stopped first", c do
    t = three_turns(c)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             send_text(t.backend, scope(t.conv), "fourth")

    assert eventually(fn -> Engine.running_runs(t.conv.id) != [] end)
    [fourth | _] = turns(t)
    assert fourth["prompt"] == "fourth"

    assert {:ok, %{"value" => %{"status" => "accepted", "result" => %{"text" => "fourth"}}}} =
             rewind(t, fourth["message_id"], "both")

    assert Engine.running_runs(t.conv.id) == []
    assert live_prompts(t.conv) == ["first", "second", "third"]
  end

  test "/undo rewinds the newest turn, messages and files", c do
    t = three_turns(c)
    [third | _] = turns(t)

    assert {:ok, %{type: :undo, message_id: id}} =
             SwarmCode.Daemon.Service.CommandDispatcher.execute_parsed(t.conv.id, %{
               name: "undo",
               kind: :builtin,
               action: :undo_turn
             })

    assert id == third["message_id"]

    assert {:ok, %{type: :select, subject: :rewind, options: [%{message_id: ^id} | _]}} =
             SwarmCode.Daemon.Service.CommandDispatcher.execute_parsed(t.conv.id, %{
               name: "rewind",
               kind: :builtin,
               action: :select_rewind
             })
  end
end
