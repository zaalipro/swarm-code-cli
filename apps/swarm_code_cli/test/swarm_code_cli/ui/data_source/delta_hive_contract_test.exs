defmodule SwarmCodeCLI.UI.DataSource.DeltaHiveContractTest do
  @moduledoc "change_upsert, change_remove and verdict_upsert decode, validate and correlate."
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire

  @run "33333333-3333-4333-8333-333333333333"
  @conversation "22222222-2222-4222-8222-222222222222"

  defp envelope(kind, entity_id, body),
    do: %{
      "kind" => kind,
      "entity_id" => entity_id,
      "run_id" => @run,
      "conversation_id" => @conversation,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => body,
      "sequence" => 12,
      "revision" => 2
    }

  test "change_upsert decodes a Change body correlated to its run" do
    wire = envelope("change_upsert", "change-1", Wire.change())

    assert {:ok, %Delta{kind: :change_upsert, body: %DTO.Change{id: "change-1"}} = delta} =
             Delta.decode(wire)

    assert {delta.entity_id, delta.run_id, delta.conversation_id} ==
             {"change-1", @run, @conversation}

    assert {:ok, ^delta} = Delta.validate(delta)

    # The run's conversation is how a conversation watch routes it; nil is tolerated.
    assert {:ok, _} = Delta.decode(Map.put(wire, "conversation_id", nil))

    for invalid <- [
          Map.put(wire, "entity_id", "other"),
          Map.put(wire, "run_id", @conversation),
          Map.put(wire, "attempt_id", "attempt-1"),
          Map.put(wire, "text", "x"),
          Map.put(wire, "channel", "text")
        ] do
      assert {:error, :invalid_delta} = Delta.decode(invalid)
    end

    # A missing or wrongly shaped body fails inside the schema decoder.
    assert {:error, _} = Delta.decode(Map.put(wire, "body", nil))
    assert {:error, _} = Delta.decode(Map.put(wire, "body", Wire.verdict()))
  end

  test "verdict_upsert decodes a Verdict body correlated to its run" do
    wire = envelope("verdict_upsert", "judge-1", Map.put(Wire.verdict(), "revision", 2))

    assert {:ok, %Delta{kind: :verdict_upsert, body: %DTO.Verdict{checks: checks}} = delta} =
             Delta.decode(wire)

    assert length(checks) == 4
    assert {:ok, ^delta} = Delta.validate(delta)

    assert {:error, :invalid_delta} = Delta.decode(Map.put(wire, "entity_id", "change-1"))
    assert {:error, _} = Delta.decode(Map.put(wire, "body", Wire.change()))
  end

  test "change_remove carries only identity and needs its run" do
    wire = envelope("change_remove", "change-1", nil)
    assert {:ok, %Delta{kind: :change_remove, body: nil} = delta} = Delta.decode(wire)
    assert {:ok, ^delta} = Delta.validate(delta)
    assert {:ok, _} = Delta.decode(Map.put(wire, "conversation_id", nil))

    for invalid <- [
          Map.put(wire, "run_id", nil),
          Map.put(wire, "entity_id", nil),
          Map.put(wire, "attempt_id", "attempt-1"),
          Map.put(wire, "text", "x")
        ] do
      assert {:error, :invalid_delta} = Delta.decode(invalid)
    end

    assert {:error, _} = Delta.decode(Map.put(wire, "body", Wire.change()))
  end

  test "runtime structs validate under the same correlation rules" do
    change = %DTO.Change{id: "change-1", run_id: @run, path: "a.ex", revision: 1}

    delta = %Delta{
      kind: :change_upsert,
      entity_id: "change-1",
      run_id: @run,
      conversation_id: @conversation,
      body: change,
      sequence: 1,
      revision: 1
    }

    assert {:ok, ^delta} = Delta.validate(delta)
    assert {:error, :invalid_delta} = Delta.validate(%{delta | run_id: "other"})
    assert {:error, :invalid_delta} = Delta.validate(%{delta | body: %{change | path: nil}})

    verdict = %DTO.Verdict{id: "judge-1", run_id: @run, revision: 1}

    assert {:ok, _} =
             Delta.validate(%{delta | kind: :verdict_upsert, entity_id: "judge-1", body: verdict})

    assert {:error, :invalid_delta} =
             Delta.validate(%{
               delta
               | kind: :verdict_upsert,
                 entity_id: "change-1",
                 body: verdict
             })
  end
end
