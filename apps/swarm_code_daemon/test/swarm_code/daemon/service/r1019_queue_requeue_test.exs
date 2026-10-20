defmodule SwarmCode.Daemon.Service.R1019QueueRequeueTest do
  @moduledoc """
  Pass 77 C-BUG-5: a prompt popped off the stored queue is never lost. A start
  that raises is a failed start; a failed start puts the prompt back at the
  head of the stored queue in one retried write; a prompt whose put-back could
  not be written is held in memory and restored before anything else pops.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import ExUnit.CaptureLog
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Daemon.Service.QueueState
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("queue-requeue")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  defp prompts(conversation_id),
    do: conversation_id |> Conversations.list_runs() |> Enum.map(& &1.prompt)

  defp fault(backend, mode) do
    :sys.replace_state(backend, fn state ->
      %{state | opts: Keyword.put(state.opts, :approval_mode, mode)}
    end)
  end

  test "safe_start turns a raise, an exit and a throw into a failed start without the prompt" do
    log =
      capture_log(fn ->
        assert Backend.safe_start(fn -> raise "boom" end) == {:error, :operation_failed}
        assert Backend.safe_start(fn -> exit(:gone) end) == {:error, :operation_failed}
        assert Backend.safe_start(fn -> throw(:ball) end) == {:error, :operation_failed}
        assert Backend.safe_start(fn -> {:ok, "run"} end) == {:ok, "run"}
      end)

    assert log =~ "queue: a queued item raised"
    assert log =~ "boom"
  end

  test "a failed start puts the prompt back at the head, behind nothing that was added", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a, approval_mode: "read_only")
    fault(backend, "invalid")

    {:ok, _} = Conversations.set_queued(Conversations.get!(a.id), ["first", "second"])
    assert {:ok, _} = command(backend, "resume", scope(a), :queue_resume, %{})

    assert eventually(fn ->
             match?(
               %{retries: 1, timer: timer} when is_reference(timer),
               QueueState.entry(:sys.get_state(backend).queues, a.id)
             )
           end)

    assert Conversations.get(a.id).queued == ["first", "second"]
    assert prompts(a.id) == []

    fault(backend, "read_only")
    assert eventually(fn -> length(prompts(a.id)) == 2 and not Engine.chat_running?(a.id) end)
    assert Conversations.get(a.id).queued == []
  end

  test "held prompts go back before the stored queue and start in order", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a, approval_mode: "read_only")
    fault(backend, "invalid")

    # `earlier` was popped and could not be stored again; `later` was queued
    # meanwhile (another window). Neither may be lost or reordered.
    {:ok, _} = Conversations.set_queued(Conversations.get!(a.id), ["later"])

    :sys.replace_state(backend, fn state ->
      {queues, _generation} = QueueState.activate(state.queues, a.id)
      %{state | queues: QueueState.hold(queues, a.id, "earlier")}
    end)

    assert {:ok, _} = command(backend, "resume", scope(a), :queue_resume, %{})

    # The held prompt is stored again first; the start fault puts it back at
    # the head, and the entry is kept for the retry.
    assert eventually(fn ->
             match?(
               %{retries: retries} when retries >= 1,
               QueueState.entry(:sys.get_state(backend).queues, a.id)
             )
           end)

    assert Conversations.get(a.id).queued == ["earlier", "later"]
    entry = QueueState.entry(:sys.get_state(backend).queues, a.id)
    assert QueueState.held(entry) == []

    fault(backend, "read_only")
    assert eventually(fn -> length(prompts(a.id)) == 2 and not Engine.chat_running?(a.id) end)
    assert Enum.sort(prompts(a.id)) == ["earlier", "later"]

    users =
      a.id
      |> Conversations.list_messages()
      |> Enum.filter(&(&1.role == "user"))
      |> Enum.map(& &1.content)

    assert users == ["earlier", "later"]
    assert Conversations.get(a.id).queued == []
  end

  test "a put-back that meets a busy database holds the prompt, then stores it again", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a, approval_mode: "read_only")
    fault(backend, "invalid")

    # The seam fails every `requeue_head` attempt the way a locked database
    # does; the start itself fails too, so the popped prompt has to be held.
    Application.put_env(:swarm_code_daemon, :busy_write_seam, fn
      :requeue_head -> raise DBConnection.ConnectionError, "connection not available"
      _other -> :ok
    end)

    on_exit(fn -> Application.delete_env(:swarm_code_daemon, :busy_write_seam) end)

    {:ok, _} = Conversations.set_queued(Conversations.get!(a.id), ["only copy"])
    assert {:ok, _} = command(backend, "resume", scope(a), :queue_resume, %{})

    assert eventually(fn ->
             QueueState.held(QueueState.entry(:sys.get_state(backend).queues, a.id)) ==
               ["only copy"]
           end)

    # Popped, held in memory, stored nowhere.
    assert Conversations.get(a.id).queued == []
    assert prompts(a.id) == []

    # The eight fast retries are used up while the prompt is still held: the
    # queue is kept (the held prompt is the only copy), the user is told once,
    # and the next try is armed slowly.
    :sys.replace_state(backend, fn state ->
      entry = QueueState.entry(state.queues, a.id)
      send(self(), {:timeout, entry.timer, {:queue_retry, a.id, entry.generation}})
      queues = Enum.reduce(1..8, state.queues, fn _, q -> elem(QueueState.retry(q, a.id), 0) end)
      %{state | queues: queues}
    end)

    assert eventually(fn ->
             match?(
               %{warned: true, timer: timer} when is_reference(timer),
               QueueState.entry(:sys.get_state(backend).queues, a.id)
             )
           end)

    entry = QueueState.entry(:sys.get_state(backend).queues, a.id)
    assert QueueState.held(entry) == ["only copy"]
    assert Process.read_timer(entry.timer) in 1_000..5_000

    Application.delete_env(:swarm_code_daemon, :busy_write_seam)
    fault(backend, "read_only")

    assert eventually(fn -> "only copy" in prompts(a.id) and not Engine.chat_running?(a.id) end)
    assert Conversations.get(a.id).queued == []
    assert QueueState.held(QueueState.entry(:sys.get_state(backend).queues, a.id)) == []
  end

  test "a held prompt keeps the queue alive while the stored queue is empty", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a, approval_mode: "read_only")

    :sys.replace_state(backend, fn state ->
      {queues, _generation} = QueueState.activate(state.queues, a.id)
      %{state | queues: QueueState.hold(queues, a.id, "only held")}
    end)

    assert Conversations.get(a.id).queued == []
    send(backend, {:drain_queue, a.id})

    assert eventually(fn -> "only held" in prompts(a.id) and not Engine.chat_running?(a.id) end)
    assert Conversations.get(a.id).queued == []
    assert QueueState.held(QueueState.entry(:sys.get_state(backend).queues, a.id)) == []
  end

  test "a queued send appends to what another window already queued", c do
    owner = self()

    {a, _, _} =
      provider!(c, c.conversation, fn turn ->
        if turn == 1 do
          send(owner, {:held, self()})
          receive do: (:release -> :ok)
        end

        {:text, "Done."}
      end)

    backend = start_backend(c, a)
    assert {:ok, _} = send_text(backend, scope(a), "Hold")
    assert_receive {:held, response}, 5000
    {:ok, _} = Conversations.append_queued(a.id, "from another window")

    assert {:ok, %{"value" => %{"disposition" => "queued"}}} =
             send_text(backend, scope(a), "Wait", "queue")

    assert Conversations.get(a.id).queued == ["from another window", "Wait"]
    send(response, :release)
    assert eventually(fn -> length(prompts(a.id)) == 3 and not Engine.chat_running?(a.id) end)
  end
end
