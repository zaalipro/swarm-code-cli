defmodule SwarmCode.Daemon.Service.R1019SlashRootsTest do
  @moduledoc """
  Review 1019 RC-7 / RC-8, end to end on the synced engine: a chat turn a slash
  command starts (`/plan`, a custom command, `/goal`, `/btw`) carries the same
  options as a plain prompt. The session's extra read-only folders
  (`--add-dir`) reach it, sent directly or queued, and so does the session
  overlay, so a `/btw` turn chained behind an automatic compaction keeps the
  session's model.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Domain.{Conversations, Engine, Providers}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup_all do
    world = setup_world("slash-roots")
    shared = Path.join(world.path, "shared")
    File.mkdir_p!(shared)
    File.write!(Path.join(shared, "notes.txt"), "marker-from-the-shared-folder\n")
    commands = Path.join(world.root, ".swarm_code/commands")
    File.mkdir_p!(commands)
    File.write!(Path.join(commands, "readit.md"), "Read $ARGUMENTS and say what it holds.\n")
    Map.put(world, :shared, shared)
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)

    on_exit(fn ->
      Engine.stop_all(conv.id)
      SessionConfiguration.clear_override()
    end)

    %{conversation: conv}
  end

  # The /goal flow makes a request ahead of the agent's first (seen as the agent
  # being answered at turn 2), so the first two answers are the tool call and
  # every later one is text.
  defp read_then_text(path) do
    fn
      turn when turn <= 2 -> {:tool, "read_file", %{"path" => path}}
      _ -> {:text, "Read it."}
    end
  end

  defp read_result(conversation_id) do
    conversation_id
    |> Conversations.list_runs()
    |> Enum.filter(&(&1.kind == "chat"))
    |> Enum.find_value(fn run ->
      case Enum.find(
             Conversations.list_nodes(run.id),
             &(&1.kind == "op" and &1.op_type == "read_file" and &1.status == "done")
           ) do
        nil -> nil
        op -> Conversations.get_node(op.id).result
      end
    end)
  end

  defp assert_reads_shared(c, text, opts \\ []) do
    {conv, _, _} =
      provider!(c, c.conversation, read_then_text(Path.join(c.shared, "notes.txt")))

    backend = start_backend(c, conv, extra_read_roots: [c.shared])

    if opts[:queued] do
      {:ok, _} = Conversations.set_queued(Conversations.get!(conv.id), [text])
      send(backend, {:drain_queue, conv.id})
    else
      assert {:ok, %{"value" => %{"status" => "accepted"}}} = send_text(backend, scope(conv), text)
    end

    assert eventually(fn -> read_result(conv.id) != nil end)
    assert read_result(conv.id) =~ "marker-from-the-shared-folder"
  end

  test "/plan reads an absolute path under a launch folder", c do
    assert_reads_shared(c, "/plan read the shared notes")
  end

  test "a custom command reads an absolute path under a launch folder", c do
    assert_reads_shared(c, "/readit the shared notes")
  end

  test "a queued /plan reads an absolute path under a launch folder", c do
    assert_reads_shared(c, "/plan read the shared notes", queued: true)
  end

  test "a /goal chat turn reads an absolute path under a launch folder", c do
    assert_reads_shared(c, "/goal read the shared notes")
  end

  test "a /btw turn chained behind a compaction keeps the session model", c do
    test = self()

    server =
      HTTP.start(fn socket, request, _turn ->
        body = Jason.decode!(request.body)
        last = body |> Map.fetch!("messages") |> List.last() |> Jason.encode!()

        kind =
          cond do
            String.contains?(last, "Compact this conversation") -> :compact
            String.contains?(last, "and then what") -> :btw
            true -> :first
          end

        send(test, {:model_request, kind, body["model"]})

        HTTP.stream(socket, [
          HTTP.sse(%{
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "ok"}, "finish_reason" => "stop"}
            ]
          })
        ])
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "btw-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["stored-model", "session-model"],
        default_model: "stored-model"
      })

    {:ok, conv} =
      Conversations.update(c.conversation, %{
        chat_provider_id: provider.id,
        chat_model: "stored-model"
      })

    Application.put_env(:swarm_code_daemon, :session_model_override, %{
      provider_id: provider.id,
      model: "session-model",
      source: :flag
    })

    backend = start_backend(c, conv)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             send_text(backend, scope(conv), "hello there")

    assert_receive {:model_request, :first, "session-model"}, 15_000

    assert eventually(fn ->
             Enum.any?(Conversations.list_runs(conv.id), &(&1.status == "done"))
           end)

    :ok = Conversations.mark_compact_due(conv.id)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             send_text(backend, scope(conv), "/btw and then what")

    assert_receive {:model_request, :compact, _model}, 15_000
    assert_receive {:model_request, :btw, "session-model"}, 15_000
    assert Conversations.get!(conv.id).chat_model == "stored-model"
  end
end
