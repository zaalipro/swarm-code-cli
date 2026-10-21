defmodule SwarmCode.Daemon.Service.R1019AddDirE2ETest do
  @moduledoc """
  Pass 77 C-FEAT-12 end to end on the synced engine: a folder the session was
  launched with (`--add-dir`) reaches the chat turn as `extra_read_roots:`, and
  the model's `read_file` of an absolute path under it reads the file. A path
  outside every root stays refused.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    world = setup_world("add-dir-e2e")
    shared = Path.join(world.path, "shared")
    File.mkdir_p!(shared)
    File.write!(Path.join(shared, "notes.txt"), "marker-from-the-shared-folder\n")
    other = Path.join(world.path, "other")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "secret.txt"), "marker-from-elsewhere\n")
    Map.merge(world, %{shared: shared, other: other})
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  defp read_then_text(path) do
    fn
      1 -> {:tool, "read_file", %{"path" => path}}
      _ -> {:text, "Read it."}
    end
  end

  defp read_op(conversation_id) do
    with [run | _] <- Enum.filter(Conversations.list_runs(conversation_id), &(&1.kind == "chat")),
         true <- run.status == "done",
         %{} = op <-
           Enum.find(
             Conversations.list_nodes(run.id),
             &(&1.kind == "op" and &1.op_type == "read_file")
           ) do
      Conversations.get_node(op.id)
    else
      _ -> nil
    end
  end

  test "read_file reads an absolute path under a launch folder", c do
    {conv, _, _} = provider!(c, c.conversation, read_then_text(Path.join(c.shared, "notes.txt")))
    backend = start_backend(c, conv, extra_read_roots: [c.shared])

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             send_text(backend, scope(conv), "read the shared notes")

    assert eventually(fn -> read_op(conv.id) != nil end)
    op = read_op(conv.id)
    assert op.status == "done"
    assert op.result =~ "marker-from-the-shared-folder"
  end

  test "a path outside the project and every extra root stays refused", c do
    {conv, _, _} = provider!(c, c.conversation, read_then_text(Path.join(c.other, "secret.txt")))
    backend = start_backend(c, conv, extra_read_roots: [c.shared])

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             send_text(backend, scope(conv), "read the other file")

    assert eventually(fn -> read_op(conv.id) != nil end)
    op = read_op(conv.id)
    refute to_string(op.result) =~ "marker-from-elsewhere"
  end
end
