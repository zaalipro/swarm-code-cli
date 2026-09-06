defmodule SwarmCode.Protocol.ServiceHandshakeTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{Error, ServiceHandshake}

  @source "33333333-3333-4333-8333-333333333333"
  @connection "44444444-4444-4444-8444-444444444444"

  test "hello has one closed version and client identity" do
    assert ServiceHandshake.hello() == %{
             "op" => "hello",
             "client" => "swarm-code-cli",
             "body_version" => 1
           }

    assert {:ok, :hello} = ServiceHandshake.decode_hello(ServiceHandshake.hello())
  end

  test "hello_ok decodes the closed capability set and bounded frame size" do
    body = %{
      "op" => "hello_ok",
      "body_version" => 1,
      "source_epoch" => @source,
      "connection_id" => @connection,
      "capabilities" => ["query", "watch", "dispatch.send", "run.stop"],
      "max_frame_bytes" => 1_048_576
    }

    assert {:ok, %{__struct__: ServiceHandshake.HelloOk} = hello_ok} =
             ServiceHandshake.decode_hello_ok(body)

    assert hello_ok.source_epoch == @source
    assert hello_ok.connection_id == @connection
    assert hello_ok.capabilities == [:query, :watch, :dispatch_send, :run_stop]
    assert {:ok, ^body} = ServiceHandshake.encode_hello_ok(hello_ok)
  end

  test "handshake codecs reject missing, extra, forged and unsupported fields with static errors" do
    hello = ServiceHandshake.hello()

    ok = %{
      "op" => "hello_ok",
      "body_version" => 1,
      "source_epoch" => @source,
      "connection_id" => @connection,
      "capabilities" => ["query"],
      "max_frame_bytes" => 1_048_576
    }

    for invalid <- [
          Map.delete(hello, "client"),
          Map.put(hello, "extra", true),
          Map.put(hello, "body_version", 2),
          Map.put(hello, "client", "desktop"),
          Map.put(hello, "body_version", 1.0),
          Map.delete(ok, "source_epoch"),
          Map.put(ok, "extra", true),
          Map.put(ok, "source_epoch", "not-an-id"),
          Map.put(ok, "connection_id", ""),
          Map.put(ok, "capabilities", ["query", "query"]),
          Map.put(ok, "capabilities", ["not-supported"]),
          Map.put(ok, "max_frame_bytes", 0),
          Map.put(ok, "max_frame_bytes", 1_048_577),
          Map.put(ok, "body_version", 2),
          Map.put(ok, "body_version", 1.0),
          Map.put(ok, "op", "hello")
        ] do
      result =
        if Map.has_key?(invalid, "source_epoch"),
          do: ServiceHandshake.decode_hello_ok(invalid),
          else: ServiceHandshake.decode_hello(invalid)

      assert {:error, %Error{code: :invalid_envelope}} = result
      assert inspect(result) =~ "invalid protocol envelope"
    end
  end

  test "encoding forged HelloOk structs is revalidated instead of serializing atoms" do
    valid =
      struct(ServiceHandshake.HelloOk,
        source_epoch: @source,
        connection_id: @connection,
        capabilities: [:query],
        max_frame_bytes: 1_048_576
      )

    for forged <- [
          %{valid | capabilities: [:query, :unknown]},
          %{valid | source_epoch: "UPPER"},
          %{valid | max_frame_bytes: 1_048_577},
          Map.put(valid, :extra, true)
        ] do
      assert {:error, %Error{code: :invalid_envelope}} = ServiceHandshake.encode_hello_ok(forged)
    end
  end
end
