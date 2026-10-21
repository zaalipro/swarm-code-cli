defmodule SwarmCode.Daemon.Service.R1019QueueShutdownTest do
  @moduledoc """
  Review 1019 RC-3, RC-11, RC-13 (pass 77 C-BUG-5, C-FEAT-1/8).

  - RC-3: a prompt the backend still holds when it stops is stored again, or
    journaled when the database stays busy, and the next backend finishes it.
  - RC-13: the once-only warning is not spent again by a failed put-back.
  - RC-11: the command and workflow listing stops with its backend and is
    bounded.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.{QueueRecovery, QueueState}
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("queue-shutdown")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    on_exit(fn -> Application.delete_env(:swarm_code_daemon, :busy_write_seam) end)
    %{conversation: conv}
  end

  defp prompts(conversation_id),
    do: conversation_id |> Conversations.list_runs() |> Enum.map(& &1.prompt)

  defp busy_requeue! do
    Application.put_env(:swarm_code_daemon, :busy_write_seam, fn
      :requeue_head -> raise DBConnection.ConnectionError, "connection not available"
      _other -> :ok
    end)
  end

  defp hold!(backend, conversation, texts) do
    :sys.replace_state(backend, fn state ->
      {queues, _generation} = QueueState.activate(state.queues, conversation.id)
      queues = Enum.reduce(texts, queues, &QueueState.hold(&2, conversation.id, &1))
      %{state | queues: queues}
    end)
  end

  defp stop!(backend) do
    ref = Process.monitor(backend)
    GenServer.stop(backend, :normal, 15_000)
    assert_receive {:DOWN, ^ref, :process, ^backend, _}, 15_000
  end

  defp journal(conversation), do: Path.join(QueueRecovery.dir(), conversation.id <> ".json")

  test "a held prompt is stored again when the backend stops", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a)
    hold!(backend, a, ["first", "second"])

    stop!(backend)

    assert Conversations.get(a.id).queued == ["first", "second"]
    refute File.exists?(journal(a))
  end

  test "a held prompt survives a database that stays busy through the shutdown", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a)
    hold!(backend, a, ["only copy"])
    busy_requeue!()

    stop!(backend)

    # Stored nowhere in the database, journaled privately.
    assert Conversations.get(a.id).queued == []
    assert File.exists?(journal(a))
    assert File.stat!(journal(a)).mode |> Bitwise.band(0o777) == 0o600
    assert Jason.decode!(File.read!(journal(a)))["texts"] == ["only copy"]

    # The next backend (the database is free again) stores it and starts it.
    Application.delete_env(:swarm_code_daemon, :busy_write_seam)
    _next = start_backend(c, a)

    assert eventually(fn -> "only copy" in prompts(a.id) and not Engine.chat_running?(a.id) end)
    refute File.exists?(journal(a))
  end

  test "a journal that cannot be read is set aside, not deleted", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    File.mkdir_p!(QueueRecovery.dir())
    File.write!(journal(a), "{not json")

    assert :ok = QueueRecovery.hand_over(a.id, ["later"])

    assert Conversations.get(a.id).queued == ["later"]
    assert File.read!(journal(a) <> ".unreadable") == "{not json"
    refute File.exists?(journal(a))
  end

  # The fast retries are used up and the armed timer fires now.
  defp exhaust_retries!(backend, conversation) do
    :sys.replace_state(backend, fn state ->
      entry = QueueState.entry(state.queues, conversation.id)
      send(self(), {:timeout, entry.timer, {:queue_retry, conversation.id, entry.generation}})

      queues =
        Enum.reduce(1..8, state.queues, fn _, q ->
          elem(QueueState.retry(q, conversation.id), 0)
        end)

      %{state | queues: queues}
    end)
  end

  defp armed_timer(backend, conversation, previous) do
    entry = QueueState.entry(:sys.get_state(backend).queues, conversation.id)
    if entry && is_reference(entry.timer) && entry.timer != previous, do: entry.timer
  end

  test "a failed put-back does not spend the once-only warning again", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a)
    busy_requeue!()
    hold!(backend, a, ["kept"])
    send(backend, {:drain_queue, a.id})

    assert eventually(fn -> armed_timer(backend, a, nil) end)
    exhaust_retries!(backend, a)

    # The first exhausted round warns once.
    assert eventually(fn ->
             match?(%{warned: true}, QueueState.entry(:sys.get_state(backend).queues, a.id))
           end)

    first_timer = armed_timer(backend, a, nil)
    revision = :sys.get_state(backend).revision

    # A second exhausted round: the put-back fails again, the warning stays
    # spent, and no second toast (a new revision) is sent.
    exhaust_retries!(backend, a)
    assert eventually(fn -> armed_timer(backend, a, first_timer) end)

    entry = QueueState.entry(:sys.get_state(backend).queues, a.id)
    assert entry.warned
    assert QueueState.held(entry) == ["kept"]
    assert :sys.get_state(backend).revision == revision
  end

  test "keep_held leaves the warning spent, release clears it" do
    state = QueueState.new()
    {state, _generation} = QueueState.activate(state, "q")
    state = QueueState.hold(state, "q", "a") |> QueueState.hold("q", "b")
    {state, :first} = QueueState.warn(state, "q")

    state = QueueState.keep_held(state, "q", ["b"])
    assert QueueState.held(QueueState.entry(state, "q")) == ["b"]
    assert {_, :again} = QueueState.warn(state, "q")

    state = QueueState.release(state, "q")
    assert {_, :first} = QueueState.warn(state, "q")
  end

  describe "the command and workflow listing" do
    defp blocked_listing!(backend) do
      :sys.replace_state(backend, fn state ->
        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            receive do: (:never_sent -> :ok)
          end)

        timer = Process.send_after(self(), {:slash_extras_timeout, task.ref}, 600_000)
        %{state | slash_extras: %{state.slash_extras | task: task, timer: timer}}
      end)

      %Task{} = task = :sys.get_state(backend).slash_extras.task
      task
    end

    test "stops with the backend", c do
      backend = start_backend(c, c.conversation)
      task = blocked_listing!(backend)
      ref = Process.monitor(task.pid)

      stop!(backend)

      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    end

    test "is cut off at its deadline and the previous list stays", c do
      backend = start_backend(c, c.conversation)
      task = blocked_listing!(backend)
      ref = Process.monitor(task.pid)

      send(backend, {:slash_extras_timeout, task.ref})

      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
      assert %{task: nil, timer: nil} = :sys.get_state(backend).slash_extras
    end
  end
end
