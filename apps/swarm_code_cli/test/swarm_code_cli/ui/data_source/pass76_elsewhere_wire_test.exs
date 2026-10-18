defmodule SwarmCodeCLI.UI.DataSource.Pass76ElsewhereWireTest do
  @moduledoc """
  pass76 cli-quit-attention: the `elsewhere` fact (the live runs and waits of
  the session's other conversations) crosses real JSON through the daemon codec
  as a shell-watch delta and as the shell snapshot's optional field (an older
  daemon that omits it still decodes), and the read model keeps the newest.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope}
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.UI.ReadModel

  @conversation "22222222-2222-4222-8222-222222222222"
  @other "33333333-3333-4333-8333-333333333333"
  @nonce String.duplicate("A", 43)
  @global %Scope{kind: :global, id: nil, generation: 2}

  defp wait_wire(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "44444444-4444-4444-8444-444444444444",
        "run_id" => "55555555-5555-4555-8555-555555555555",
        "conversation_id" => @other,
        "kind" => "approval",
        "title" => "Refactor parser"
      },
      overrides
    )
  end

  defp elsewhere_wire(overrides \\ %{}),
    do: Map.merge(%{"live" => 2, "waiting" => [wait_wire()]}, overrides)

  defp delta_wire(body, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "elsewhere",
        "entity_id" => nil,
        "run_id" => nil,
        "conversation_id" => @conversation,
        "channel" => nil,
        "attempt_id" => nil,
        "text" => nil,
        "body" => body,
        "sequence" => 4,
        "revision" => 3
      },
      extra
    )
  end

  defp through_json(message) do
    {:ok, bytes} = Envelope.encode(message)
    {:ok, decoded} = Envelope.decode(IO.iodata_to_binary(bytes))
    decoded
  end

  defp event(sequence, body),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @global,
      sequence: sequence,
      occurred_at: "2026-10-08T00:00:00Z",
      body: body
    }

  defp shell_watch,
    do: %Watch{
      watch_ref: "watch-1",
      slot: :shell,
      scope: @global,
      generation: 2,
      page_size: 20,
      byte_limit: 262_144
    }

  test "the DTO decodes the daemon's map and refuses what the quit and the bell cannot use" do
    assert {:ok, %DTO.Elsewhere{live: 2, waiting: [%DTO.ElsewhereWait{} = wait]}} =
             DTO.Elsewhere.decode(elsewhere_wire())

    assert {wait.kind, wait.title, wait.conversation_id} == {:approval, "Refactor parser", @other}

    assert {:ok, %DTO.Elsewhere{live: 0, waiting: []}} =
             DTO.Elsewhere.decode(elsewhere_wire(%{"live" => 0, "waiting" => []}))

    assert {:ok, %DTO.ElsewhereWait{kind: :question}} =
             DTO.ElsewhereWait.decode(wait_wire(%{"kind" => "question"}))

    for bad <- [
          elsewhere_wire(%{"live" => -1}),
          elsewhere_wire(%{"live" => nil}),
          elsewhere_wire(%{"waiting" => List.duplicate(wait_wire(), 33)}),
          elsewhere_wire(%{"waiting" => [wait_wire(%{"kind" => "gate"})]}),
          elsewhere_wire(%{"waiting" => [Map.delete(wait_wire(), "title")]}),
          elsewhere_wire(%{"waiting" => [wait_wire(%{"conversation_id" => ""})]}),
          Map.put(elsewhere_wire(), "extra", 1)
        ] do
      assert {:error, _} = DTO.Elsewhere.decode(bad)
    end

    assert {:ok, _} =
             DTO.Elsewhere.decode(elsewhere_wire(%{"waiting" => List.duplicate(wait_wire(), 32)}))
  end

  test "an elsewhere delta crosses the shell watch; one about a run or an entity is refused" do
    message =
      event(4, %{
        "op" => "delta",
        "watch_ref" => "watch-1",
        "value" => delta_wire(elsewhere_wire())
      })

    assert {:ok,
            %Delivery{kind: :delta, body: %Delta{kind: :elsewhere, body: %DTO.Elsewhere{} = body}}} =
             Codec.event(through_json(message), shell_watch(), @nonce)

    assert body.live == 2

    for bad <- [
          delta_wire(elsewhere_wire(), %{"entity_id" => @conversation}),
          delta_wire(elsewhere_wire(), %{"run_id" => @conversation}),
          delta_wire(elsewhere_wire(), %{"attempt_id" => @conversation}),
          delta_wire(%{"live" => "2", "waiting" => []})
        ] do
      assert {:error, _} = Delta.decode(bad)
    end
  end

  test "the shell snapshot carries the fact, and an older daemon's snapshot omits it" do
    shell =
      Map.merge(Wire.page(), %{
        "runs" => [],
        "connection" => %{"state" => "connected", "source_epoch" => "epoch-1"},
        "counts" => %{
          "running" => 0,
          "waiting" => 0,
          "paused" => 0,
          "failed" => 0,
          "done" => 0,
          "unseen" => 0
        },
        "rate_limits" => []
      })

    ready = fn value ->
      event(9, %{
        "op" => "watch_ready",
        "watch_ref" => "watch-1",
        "revision" => 7,
        "body_kind" => "shell_snapshot",
        "value" => value
      })
    end

    assert {:ok, %Delivery{body: %DTO.ShellSnapshot{elsewhere: nil}}} =
             Codec.event(through_json(ready.(shell)), shell_watch(), @nonce)

    assert {:ok,
            %Delivery{
              body: %DTO.ShellSnapshot{elsewhere: %DTO.Elsewhere{live: 2, waiting: [_]}}
            }} =
             Codec.event(
               through_json(ready.(Map.put(shell, "elsewhere", elsewhere_wire()))),
               shell_watch(),
               @nonce
             )
  end

  test "the read model installs the snapshot's fact and replaces it with each delta" do
    {:ok, first} = DTO.Elsewhere.decode(elsewhere_wire())
    {:ok, second} = DTO.Elsewhere.decode(elsewhere_wire(%{"live" => 0, "waiting" => []}))

    snapshot = %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"},
      elsewhere: first
    }

    model = ReadModel.snapshot(%ReadModel{}, :shell, snapshot)
    assert model.elsewhere == first

    assert {:ok, %{elsewhere: ^second}, [], []} =
             ReadModel.delta(model, :shell, %Delta{kind: :elsewhere, body: second})

    # A snapshot that omits it leaves what was held; the workspace never sets it.
    model = ReadModel.snapshot(model, :shell, %{snapshot | elsewhere: nil})
    assert model.elsewhere == first

    assert %ReadModel{elsewhere: nil} =
             ReadModel.snapshot(%ReadModel{}, :workspace, %DTO.WorkspaceSnapshot{
               conversation_id: @conversation,
               allowed_actions: [:send, :queue],
               runs: [],
               interactions: [],
               transcript: %DTO.TranscriptWindow{items: []},
               runs_page: %DTO.PageInfo{},
               interactions_page: %DTO.PageInfo{}
             })
  end
end
