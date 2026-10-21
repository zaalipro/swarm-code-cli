defmodule SwarmCode.Daemon.Service.R1019CompactOverlayTest do
  @moduledoc """
  Pass 77 C-BUG-12, end to end on the synced engine: a chat turn chained behind
  an automatic compaction reloads the conversation from the database, and the
  `:conversation_overlay` the CLI passes (`PersistedBackend` sends
  `&SessionConfiguration.overlay/1`, pinned in `r1019_chat_opts_test.exs`) is
  applied to that reloaded row, so the turn runs on the session's model, not
  the stored one. The run's end also reaches the CLI's notifications topic
  through the engine's notifier port (D-ARCH-11, `config :engine_notifier`).
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCode.Domain.Engine.Events
  alias SwarmCode.Test.C020Backend, as: Fixture
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup do
    test = self()
    world = Fixture.setup_world("compact-overlay")
    {:ok, conversation} = Conversations.create(world.project.id)
    on_exit(fn -> Engine.stop_all(conversation.id) end)
    Events.subscribe(conversation.id)

    server =
      HTTP.start(fn socket, request, _turn ->
        body = Jason.decode!(request.body)
        last = body |> Map.fetch!("messages") |> List.last()
        compactor? = String.contains?(Jason.encode!(last), "Compact this conversation")
        send(test, {:model_request, if(compactor?, do: :compact, else: :turn), body["model"]})
        answer(socket, if(compactor?, do: "## Goal\nsummary", else: "the turn"))
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      SwarmCode.Domain.Providers.create(%{
        name: "overlay-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["stored-model", "session-model"],
        default_model: "stored-model"
      })

    {:ok, conversation} =
      Conversations.update(conversation, %{
        chat_provider_id: provider.id,
        chat_model: "stored-model"
      })

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

  test "the chained turn runs on the overlaid model", c do
    overlay = fn conversation -> %{conversation | chat_model: "session-model"} end
    SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "notifications")

    assert {:ok, _compaction_id} =
             Engine.start_chat_turn(c.conversation, "and then?", [],
               conversation_overlay: overlay
             )

    assert_receive {:model_request, :turn, "session-model"}, 15_000
    assert_receive {:run_updated, %{kind: "chat", status: "done"}}, 15_000
    # The stored row keeps its own model: the overlay is session memory only.
    assert Conversations.get!(c.conversation.id).chat_model == "stored-model"
    assert_receive {:notification, :finished, _text}, 15_000
  end
end
