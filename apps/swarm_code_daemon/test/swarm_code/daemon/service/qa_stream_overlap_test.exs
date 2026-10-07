defmodule SwarmCode.Daemon.Service.QaStreamOverlapTest do
  @moduledoc """
  cli020 live QA: an answer was drawn twice ("Done, I recorded the
  result.Done, I recorded the result.") after a queue drain and after a
  retry. `RunServer.flush/1` writes a flush to the database before it
  broadcasts that flush's `{:assistant_delta, …}`; a reload between the two
  read text that already held the chunk, and the delta then appended it
  again. Deltas already in the mailbox are applied before the database is
  read, and a first delta the read text already ends with is not appended.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  import Ecto.Query
  alias SwarmCode.Domain.{Conversations, Repo}
  alias SwarmCode.Domain.Conversations.Message

  setup_all do
    setup_world("qa-stream")
  end

  defp live_answer(c, content) do
    {:ok, conv} = Conversations.create(c.project.id)

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: conv.id,
        kind: "chat",
        prompt: "Hi",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, message} =
      Conversations.create_message(%{
        conversation_id: conv.id,
        role: "assistant",
        content: content,
        run_id: run.id
      })

    backend = start_backend(c, conv)
    _ = workspace(backend, scope(conv))
    {conv, run, message, backend}
  end

  defp text(backend, run_id, message_id) do
    %{runs: runs} = :sys.get_state(backend)
    Enum.find(runs[run_id].records, &(&1.id == message_id)).text
  end

  defp write(message_id, content),
    do: Repo.update_all(from(m in Message, where: m.id == ^message_id), set: [content: content])

  test "a delta whose chunk the reloaded text already ends with is not appended again", c do
    {_conv, run, message, backend} = live_answer(c, "Hello there")
    send(backend, {:assistant_delta, message.id, "Hello there"})
    assert text(backend, run.id, message.id) == "Hello there"
    send(backend, {:assistant_delta, message.id, " friend"})
    assert text(backend, run.id, message.id) == "Hello there friend"
  end

  test "deltas queued behind a reload are applied before the database is read", c do
    {conv, run, message, backend} = live_answer(c, "")
    :ok = :sys.suspend(backend)
    reader = Task.async(fn -> workspace(backend, scope(conv)) end)

    assert eventually(fn -> Process.info(backend, :message_queue_len) |> elem(1) >= 1 end)

    # The run server's two flushes: each writes the database, then broadcasts.
    write(message.id, "one")
    send(backend, {:assistant_delta, message.id, "one"})
    write(message.id, "one two")
    send(backend, {:assistant_delta, message.id, " two"})
    :ok = :sys.resume(backend)
    _ = Task.await(reader, 15_000)

    assert text(backend, run.id, message.id) == "one two"
  end
end
