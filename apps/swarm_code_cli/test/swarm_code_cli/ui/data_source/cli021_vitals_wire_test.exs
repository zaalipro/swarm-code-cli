defmodule SwarmCodeCLI.UI.DataSource.Cli021VitalsWireTest do
  @moduledoc """
  cli021 C2: the vitals DTOs cross real JSON through the daemon codec as a
  shell-watch delta and as the shell snapshot's optional field (an older daemon
  that omits it still decodes), the read model keeps the newest reading, and the
  fake source tells its clients too.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope}
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.UI.DataSource.Fake.{Session, Source}
  alias SwarmCodeCLI.UI.ReadModel

  @conversation "22222222-2222-4222-8222-222222222222"
  @nonce String.duplicate("A", 43)
  @global %Scope{kind: :global, id: nil, generation: 2}

  defp vitals_wire(overrides \\ %{}) do
    Map.merge(
      %{
        "conversation_id" => @conversation,
        "models" => [
          %{
            "slot" => "main",
            "model" => "deepseek-v4-pro",
            "tps" => 58,
            "live" => false,
            "ttft_ms" => 410,
            "at" => 1_791_453_600_000,
            "history" => [51, 55, 58]
          },
          %{
            "slot" => "worker",
            "model" => "ms/glm-5.2",
            "tps" => nil,
            "live" => false,
            "ttft_ms" => nil,
            "at" => nil,
            "history" => []
          }
        ],
        "beam_bytes" => 280_000_000,
        "os_rss_bytes" => 410_000_000,
        "children_rss_bytes" => nil,
        "machine_bytes" => 34_359_738_368,
        "sampled_at" => 1_791_453_601_000
      },
      overrides
    )
  end

  defp delta_wire(body, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "vitals",
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

  test "the DTO decodes the daemon's map and refuses what the panel cannot draw" do
    assert {:ok, %DTO.Vitals{models: [main, worker]} = vitals} = DTO.Vitals.decode(vitals_wire())
    assert {main.slot, main.tps, main.history, main.live} == {:main, 58, [51, 55, 58], false}
    assert {worker.slot, worker.tps, worker.at} == {:worker, nil, nil}
    assert {vitals.os_rss_bytes, vitals.children_rss_bytes} == {410_000_000, nil}

    one = hd(vitals_wire()["models"])
    assert {:error, _} = DTO.Vitals.decode(vitals_wire(%{"models" => List.duplicate(one, 9)}))
    assert {:error, _} = DTO.ModelSpeed.decode(%{one | "history" => Enum.to_list(1..13)})
    assert {:error, _} = DTO.ModelSpeed.decode(%{one | "slot" => "sidekick"})
    assert {:error, _} = DTO.ModelSpeed.decode(%{one | "tps" => -3})
    assert {:error, _} = DTO.Vitals.decode(vitals_wire(%{"beam_bytes" => nil}))
  end

  test "a vitals delta crosses the shell watch; one about nothing known is refused" do
    message =
      event(4, %{"op" => "delta", "watch_ref" => "watch-1", "value" => delta_wire(vitals_wire())})

    assert {:ok, %Delivery{kind: :delta, body: %Delta{kind: :vitals, body: %DTO.Vitals{} = body}}} =
             Codec.event(through_json(message), shell_watch(), @nonce)

    assert body.conversation_id == @conversation

    for bad <- [
          delta_wire(vitals_wire(), %{"entity_id" => @conversation}),
          delta_wire(vitals_wire(), %{"run_id" => @conversation}),
          delta_wire(vitals_wire(), %{"conversation_id" => "33333333-3333-4333-8333-333333333333"})
        ] do
      assert {:error, :invalid_delta} = Delta.decode(bad)
    end
  end

  test "the shell snapshot carries the vitals, and an older daemon's snapshot omits them" do
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

    assert {:ok, %Delivery{body: %DTO.ShellSnapshot{vitals: nil}}} =
             Codec.event(through_json(ready.(shell)), shell_watch(), @nonce)

    assert {:ok,
            %Delivery{body: %DTO.ShellSnapshot{vitals: %DTO.Vitals{beam_bytes: 280_000_000}}}} =
             Codec.event(
               through_json(ready.(Map.put(shell, "vitals", vitals_wire()))),
               shell_watch(),
               @nonce
             )
  end

  test "the read model keeps the newest reading and installs the snapshot's" do
    {:ok, older} = DTO.Vitals.decode(vitals_wire(%{"sampled_at" => 1_000}))
    {:ok, newer} = DTO.Vitals.decode(vitals_wire(%{"sampled_at" => 2_000}))
    delta = fn body -> %Delta{kind: :vitals, conversation_id: @conversation, body: body} end

    assert {:ok, %{vitals: ^newer} = model, [], []} =
             ReadModel.delta(%ReadModel{}, :shell, delta.(newer))

    assert {:ok, %{vitals: ^newer}, [], []} = ReadModel.delta(model, :shell, delta.(older))

    # another conversation's reading replaces it whatever its instant
    {:ok, other} = DTO.Vitals.decode(vitals_wire(%{"conversation_id" => nil, "sampled_at" => 10}))
    assert {:ok, %{vitals: ^other}, [], []} = ReadModel.delta(model, :shell, delta.(other))
  end

  test "the fake source tells its clients and serves the same facts in its snapshot" do
    ids = %{
      a: @conversation,
      b: "33333333-3333-4333-8333-333333333333",
      a2: @conversation,
      builder_4: @conversation
    }

    session = Session.initial(1_791_453_600_000, ids)
    assert %DTO.Vitals{models: [%{slot: :main}, %{slot: :worker, live: true}]} = session.vitals
    assert {:ok, _} = DTO.Vitals.validate(session.vitals)
    assert Session.valid?(session)
    assert Keyword.fetch!(Session.shell_fields(%{session: session}), :vitals) == session.vitals
  end

  test "the fake source broadcasts a vitals reading as a valid delta" do
    {:ok, script} =
      SwarmCodeCLI.UI.DataSource.Fake.Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    source =
      start_supervised!(
        {Source, script: script, source_epoch: "00000000-0000-4000-8000-0000000000ee"}
      )

    :ok = Source.attach(source, "client-1", self())
    {:ok, vitals} = DTO.Vitals.decode(vitals_wire())
    :ok = Source.vitals(source, vitals)

    assert_receive {:fake_source, "client-1", [%Delta{kind: :vitals} = delta]}
    assert {:ok, _} = Delta.validate(delta)
    assert delta.body == vitals
  end
end
