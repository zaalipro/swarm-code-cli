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
  alias SwarmCode.Daemon.Service.QueueState
  alias SwarmCode.Protocol.{Envelope, Frame, Message, ServiceHandshake, ServiceRequest}

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

  test "A drains exactly once after navigation to B without changing B", c do
    owner = self()

    {a, _, _} =
      provider!(c, c.conversation, fn turn ->
        if turn <= 2 do
          send(owner, {:held, turn, self()})
          receive do: (:release -> :ok)
        end

        {:text, "Done."}
      end)

    {:ok, b} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(b.id) end)
    backend = start_backend(c, a)
    wire = socket!(c, backend)
    assert %{"status" => "accepted"} = wire_send(wire, scope(a), "First")
    assert_receive {:held, 1, response}, 5000
    # Ordinary sends steer. A second independently launched turn proves the
    # queue waits for every live owner, not just the most recent one.
    assert {:ok, _} = Engine.start_chat_turn(a, "Parallel")

    assert %{"disposition" => "queued"} = wire_send(wire, scope(a), "Only A", "queue")

    entry = QueueState.entry(:sys.get_state(backend).queues, a.id)
    assert map_size(entry.monitors) == 2

    assert %{"status" => "accepted"} =
             wire_command(wire, scope(a), :conversation_open, %{
               "conversation_id" => b.id
             })

    before = workspace(backend, scope(b))
    send(response, :release)
    assert_receive {:held, 2, second_response}, 5000
    assert Conversations.get(a.id).queued == ["Only A"]
    refute "Only A" in prompts(a.id)
    send(second_response, :release)
    assert eventually(fn -> "Only A" in prompts(a.id) end)
    assert eventually(fn -> not Engine.chat_running?(a.id) end)
    assert Enum.count(prompts(a.id), &(&1 == "Only A")) == 1
    assert Conversations.get(a.id).queued == []
    assert prompts(b.id) == []
    assert Conversations.list_messages(b.id) == []
    after_workspace = workspace(backend, scope(b))
    fields = ~w(conversation_id runs agents queued_texts queued_count queue_revision queue_paused)
    assert Map.take(after_workspace, fields) == Map.take(before, fields)
    assert :sys.get_state(backend).opts[:conversation_id] == b.id
    messages = Conversations.list_messages(a.id)
    assert Enum.count(messages, &(&1.role == "user" and &1.content == "Only A")) == 1
    for {ref, pid} <- entry.monitors, do: send(backend, {:DOWN, ref, :process, pid, :normal})
    send(backend, {:drain_queue, a.id, entry.generation})
    send(backend, {:timeout, make_ref(), {:queue_retry, a.id, entry.generation}})
    _ = :sys.get_state(backend)
    assert Enum.count(prompts(a.id), &(&1 == "Only A")) == 1
    assert QueueState.entry(:sys.get_state(backend).queues, a.id) == nil
  end

  test "ordinary sends queue during compaction and drain A after navigation", c do
    owner = self()

    {a, _, _} =
      provider!(c, c.conversation, fn turn ->
        if turn == 1 do
          send(owner, {:compact_held, self()})
          receive do: (:release -> :ok)
        end

        {:text, "Summary."}
      end)

    {:ok, _} =
      Conversations.create_message(%{conversation_id: a.id, role: "user", content: "History"})

    {:ok, b} = Conversations.create(c.project.id)
    backend = start_backend(c, a)
    assert {:ok, _} = send_text(backend, scope(a), "/compact")
    assert_receive {:compact_held, response}, 5000

    assert {:ok, %{"value" => %{"disposition" => "queued"}}} =
             send_text(backend, scope(a), "After compact")

    assert {:ok, _} =
             command(backend, "open", scope(a), :conversation_open, %{"conversation_id" => b.id})

    send(response, :release)
    assert eventually(fn -> "After compact" in prompts(a.id) end)
    assert eventually(fn -> not Engine.chat_running?(a.id) end)
    assert Enum.count(prompts(a.id), &(&1 == "After compact")) == 1
    assert :sys.get_state(backend).opts[:conversation_id] == b.id
    assert Conversations.list_messages(b.id) == []
    assert prompts(b.id) == []
  end

  test "retry timers are scoped, stale messages are inert and recovery preserves FIFO", c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a, approval_mode: "read_only")
    # Deterministic engine admission fault after service admission. No
    # production fault selector or remote request is used.
    :sys.replace_state(backend, fn state ->
      %{state | opts: Keyword.put(state.opts, :approval_mode, "invalid")}
    end)

    {:ok, _} = Conversations.set_queued(Conversations.get!(a.id), ["retry one", "retry two"])
    assert {:ok, _} = command(backend, "resume", scope(a), :queue_resume, %{})

    assert eventually(fn ->
             match?(
               %{retries: 1, timer: timer} when is_reference(timer),
               QueueState.entry(:sys.get_state(backend).queues, a.id)
             )
           end)

    entry = QueueState.entry(:sys.get_state(backend).queues, a.id)
    assert Process.read_timer(entry.timer) in 1..250
    assert Conversations.get(a.id).queued == ["retry one", "retry two"]
    send(backend, {:timeout, make_ref(), {:queue_retry, a.id, entry.generation}})
    send(backend, {:timeout, entry.timer, {:queue_retry, a.id, entry.generation - 1}})
    state = :sys.get_state(backend)
    assert QueueState.entry(state.queues, a.id).timer == entry.timer
    assert QueueState.entry(state.queues, a.id).retries == 1

    :sys.replace_state(backend, fn state ->
      %{state | opts: Keyword.put(state.opts, :approval_mode, "read_only")}
    end)

    assert eventually(fn -> length(prompts(a.id)) == 2 and not Engine.chat_running?(a.id) end)
    messages = Conversations.list_messages(a.id) |> Enum.filter(&(&1.role == "user"))
    assert Enum.map(messages, & &1.content) == ["retry one", "retry two"]
    assert Conversations.get(a.id).queued == []
    assert Process.read_timer(entry.timer) == false
  end

  test "shutdown cancels a retained retry timer and old conversation monitors", c do
    owner = self()

    {a, _, _} =
      provider!(c, c.conversation, fn _ ->
        send(owner, {:shutdown_held, self()})
        receive do: (:release -> :ok)
        {:text, "Done."}
      end)

    {:ok, b} = Conversations.create(c.project.id)
    backend = start_backend(c, a)
    assert {:ok, _} = send_text(backend, scope(a), "Hold")
    assert_receive {:shutdown_held, response}, 5000
    assert {:ok, _} = send_text(backend, scope(a), "Wait", "queue")

    assert {:ok, _} =
             command(backend, "open", scope(a), :conversation_open, %{"conversation_id" => b.id})

    :sys.replace_state(backend, fn state ->
      %{state | opts: Keyword.put(state.opts, :approval_mode, "invalid")}
    end)

    {:ok, _} = Conversations.set_queued(Conversations.get!(b.id), ["Retry"])
    assert {:ok, _} = command(backend, "resume", scope(b), :queue_resume, %{})

    assert eventually(fn ->
             match?(
               %{timer: timer} when is_reference(timer),
               QueueState.entry(:sys.get_state(backend).queues, b.id)
             )
           end)

    state = :sys.get_state(backend)
    timer = QueueState.entry(state.queues, b.id).timer
    assert map_size(QueueState.entry(state.queues, a.id).monitors) == 1
    GenServer.stop(backend)
    assert Process.read_timer(timer) == false
    assert Process.info(backend, :monitors) == nil
    send(response, :release)
    assert eventually(fn -> not Engine.chat_running?(a.id) end)
    assert Conversations.get(a.id).queued == ["Wait"]
    assert Conversations.get(b.id).queued == ["Retry"]
  end

  test "eight retries exhaust without dropping text and report the existing notice on the wire",
       c do
    {a, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)
    backend = start_backend(c, a)
    {socket, nonce} = socket!(c, backend)
    s = scope(a)

    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 5000,
      params: %{
        "watch_ref" => "queue-exhaustion",
        "slot" => "shell",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      }
    }

    {:ok, body} = ServiceRequest.encode(watch, s)

    :ok =
      :gen_tcp.send(
        socket,
        Frame.encode!(%Message{
          version: 1,
          type: :request,
          request_id: Ecto.UUID.generate(),
          nonce: nonce,
          scope: s,
          sequence: nil,
          occurred_at: nil,
          body: body
        })
      )

    assert %Message{type: :event, body: %{"op" => "watch_ready"}} = frame(socket)

    :sys.replace_state(backend, fn state ->
      %{state | opts: Keyword.put(state.opts, :approval_mode, "invalid")}
    end)

    {:ok, _} = Conversations.set_queued(Conversations.get!(a.id), ["Retained"])
    assert {:ok, _} = command(backend, "resume", s, :queue_resume, %{})

    assert eventually(fn ->
             match?(
               %{retries: 1},
               QueueState.entry(:sys.get_state(backend).queues, a.id)
             )
           end)

    generation = QueueState.entry(:sys.get_state(backend).queues, a.id).generation
    toast = queue_toast(socket, 20)
    assert toast["body"]["text"] == "The queued prompt could not start."
    assert Conversations.get(a.id).queued == ["Retained"]
    assert prompts(a.id) == []
    assert QueueState.entry(:sys.get_state(backend).queues, a.id) == nil
    send(backend, {:drain_queue, a.id, generation})
    _ = :sys.get_state(backend)
    assert QueueState.entry(:sys.get_state(backend).queues, a.id) == nil
  end

  defp queue_toast(socket, remaining) when remaining > 0 do
    message = frame(socket)

    case message.body do
      %{"op" => "delta", "value" => %{"kind" => "toast", "body" => %{"title" => "Queue"}} = delta} ->
        delta

      _ ->
        queue_toast(socket, remaining - 1)
    end
  end

  defp socket!(c, backend) do
    File.chmod!(c.path, 0o700)
    path = Path.join(c.path, "q#{System.unique_integer([:positive])}.sock")
    nonce = String.duplicate("Q", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path,
       nonce: nonce,
       source_epoch: :sys.get_state(backend).opts[:source_epoch],
       backend: backend}
    )

    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(
        socket,
        Frame.encode!(%Message{
          version: 1,
          type: :hello,
          request_id: Ecto.UUID.generate(),
          nonce: nonce,
          scope: nil,
          sequence: nil,
          occurred_at: nil,
          body: ServiceHandshake.hello()
        })
      )

    assert frame(socket).type == :hello_ok
    {socket, nonce}
  end

  defp wire_send(wire, scope, text, action \\ "send"),
    do:
      wire_command(wire, scope, :dispatch_send, %{
        "action" => action,
        "text" => text,
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => []
      })

  defp wire_command({socket, nonce}, scope, op, params) do
    {:ok, body} =
      ServiceRequest.encode(
        %ServiceRequest{operation: op, timeout_ms: 5000, params: params},
        scope
      )

    :ok =
      :gen_tcp.send(
        socket,
        Frame.encode!(%Message{
          version: 1,
          type: :request,
          request_id: Ecto.UUID.generate(),
          nonce: nonce,
          scope: scope,
          sequence: nil,
          occurred_at: nil,
          body: body
        })
      )

    response = frame(socket)
    assert response.type == :response
    response.body["value"]
  end

  defp frame(socket) do
    {:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, 5000)
    {:ok, bytes} = :gen_tcp.recv(socket, length, 5000)
    {:ok, message} = Envelope.decode(bytes)
    message
  end

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
