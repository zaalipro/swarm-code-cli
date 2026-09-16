defmodule SwarmCode.Protocol.EnvelopeTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Protocol.{Envelope, Error, Message, Scope}

  @nonce "7MEe1H2sfyDTvqPFUwR54awB9ZyiW9I9oXaBbmV5_sQ"
  @request_id "0198cda0-77c8-7d65-b7a4-f465638cc131"
  @scope_id "0198cda0-77c8-7d65-b7a4-f465638cc132"
  @occurred_at "2026-09-01T12:34:56.123456Z"

  test "a typed event round-trips through genuine iodata while runtime keys stay binaries" do
    message =
      message(:event,
        scope: %Scope{kind: :run, id: @scope_id, generation: 4},
        sequence: 91,
        occurred_at: @occurred_at,
        body: %{
          "event" => "assistant_text",
          "delta" => "exact bytes",
          "nested" => [%{"binary_key" => true}]
        }
      )

    assert {:ok, encoded} = Envelope.encode(message)
    assert is_list(encoded)
    assert {:ok, decoded} = encoded |> IO.iodata_to_binary() |> Envelope.decode()
    assert decoded == message
    assert [%{"binary_key" => true}] = decoded.body["nested"]
    assert Enum.all?(Map.keys(decoded.body), &is_binary/1)
  end

  test "encoding emits the exact v1 outer and scope key sets" do
    message =
      message(:event,
        scope: %Scope{kind: :project, id: @scope_id, generation: 0},
        sequence: 0,
        occurred_at: @occurred_at
      )

    assert {:ok, encoded} = Envelope.encode(message)
    assert {:ok, document} = Jason.decode(encoded)

    assert Enum.sort(Map.keys(document)) ==
             ~w(body nonce occurred_at request_id scope sequence type v)

    assert Enum.sort(Map.keys(document["scope"])) == ~w(generation id kind)
  end

  test "every closed message type and scope kind round-trips" do
    for type <- ~w(hello hello_ok request response error)a do
      assert_round_trip(message(type, request_id: @request_id))
    end

    assert_round_trip(
      message(:event,
        scope: %Scope{kind: :run, id: @scope_id, generation: 1},
        sequence: 0,
        occurred_at: @occurred_at
      )
    )

    assert_round_trip(
      message(:snapshot_required,
        scope: %Scope{kind: :conversation, id: @scope_id, generation: 2}
      )
    )

    for type <- ~w(ping pong)a do
      assert_round_trip(message(type))
    end

    for kind <- ~w(project conversation run research workflow schedule)a do
      assert_round_trip(message(:ping, scope: %Scope{kind: kind, id: @scope_id, generation: 3}))
    end

    assert_round_trip(message(:ping, scope: %Scope{kind: :global, id: nil, generation: 3}))
  end

  test "unknown types and extra envelope fields are rejected without atom creation" do
    valid = wire_message("warm-up-#{System.unique_integer([:positive])}")
    _ = Envelope.decode(Jason.encode!(valid))
    before = :erlang.system_info(:atom_count)

    Enum.each(1..1_000, fn n ->
      assert {:error, %Error{code: :unknown_message_type}} =
               Envelope.decode(
                 Jason.encode!(%{valid | "type" => "untrusted-#{n}-#{:rand.uniform()}"})
               )
    end)

    assert :erlang.system_info(:atom_count) == before

    assert_error(
      Envelope.decode(Jason.encode!(Map.put(valid, "admin", true))),
      :invalid_envelope
    )
  end

  test "shape and type precedence is deterministic" do
    assert_error(
      wire_message("not-closed")
      |> Map.put("v", 99)
      |> Map.put("unexpected", true)
      |> Jason.encode!()
      |> Envelope.decode(),
      :invalid_envelope
    )

    assert_error(
      wire_message("not-closed")
      |> Map.put("v", 99)
      |> Jason.encode!()
      |> Envelope.decode(),
      :unknown_message_type
    )

    assert_error(
      wire_message("ping")
      |> Map.put("v", 99)
      |> Jason.encode!()
      |> Envelope.decode(),
      :unsupported_protocol_version
    )
  end

  test "event invariants require scope, sequence, and occurrence time" do
    valid =
      wire_message("event")
      |> Map.put("scope", wire_scope("run", @scope_id, 0))
      |> Map.put("sequence", 0)
      |> Map.put("occurred_at", @occurred_at)

    for field <- ~w(scope sequence occurred_at) do
      assert_error(
        valid |> Map.put(field, nil) |> Jason.encode!() |> Envelope.decode(),
        :invalid_envelope
      )
    end
  end

  test "request-correlated message types require canonical lowercase UUID request IDs" do
    for type <- ~w(hello hello_ok request response error) do
      valid = wire_message(type) |> Map.put("request_id", @request_id)
      assert {:ok, %Message{request_id: @request_id}} = Envelope.decode(Jason.encode!(valid))

      for request_id <- [nil, String.upcase(@request_id), "not-a-uuid", 1] do
        assert_error(
          valid |> Map.put("request_id", request_id) |> Jason.encode!() |> Envelope.decode(),
          :invalid_envelope
        )
      end
    end
  end

  test "snapshot_required requires a valid scope" do
    base = wire_message("snapshot_required")

    assert_error(Envelope.decode(Jason.encode!(base)), :invalid_envelope)

    assert {:ok, %Message{scope: %Scope{kind: :run}}} =
             base
             |> Map.put("scope", wire_scope("run", @scope_id, 0))
             |> Jason.encode!()
             |> Envelope.decode()
  end

  test "scope shape and closed kind precedence are deterministic and atom-safe" do
    base = wire_message("ping")

    assert_error(
      base
      |> Map.put("scope", Map.put(wire_scope("unknown", @scope_id, 0), "extra", true))
      |> Jason.encode!()
      |> Envelope.decode(),
      :invalid_envelope
    )

    warm =
      base
      |> Map.put("scope", wire_scope("warm", @scope_id, -1))
      |> Jason.encode!()

    _ = Envelope.decode(warm)
    before = :erlang.system_info(:atom_count)

    Enum.each(1..1_000, fn n ->
      unknown_scope = wire_scope("scope-#{n}-#{:rand.uniform()}", @scope_id, -1)

      assert_error(
        base |> Map.put("scope", unknown_scope) |> Jason.encode!() |> Envelope.decode(),
        :unknown_scope_kind
      )
    end)

    assert :erlang.system_info(:atom_count) == before
  end

  test "global scopes require nil IDs and all other scopes require lowercase UUIDs" do
    base = wire_message("ping")

    assert {:ok, %Message{scope: %Scope{kind: :global, id: nil}}} =
             base
             |> Map.put("scope", wire_scope("global", nil, 0))
             |> Jason.encode!()
             |> Envelope.decode()

    for invalid_id <- [@scope_id, "", 1] do
      assert_error(
        base
        |> Map.put("scope", wire_scope("global", invalid_id, 0))
        |> Jason.encode!()
        |> Envelope.decode(),
        :invalid_envelope
      )
    end

    for kind <- ~w(project conversation run research workflow schedule),
        invalid_id <- [nil, String.upcase(@scope_id), "not-a-uuid"] do
      assert_error(
        base
        |> Map.put("scope", wire_scope(kind, invalid_id, 0))
        |> Jason.encode!()
        |> Envelope.decode(),
        :invalid_envelope
      )
    end
  end

  test "every optional nonnil field is validated even for ping" do
    base = wire_message("ping")

    invalid_fields = [
      {"request_id", "invalid"},
      {"sequence", -1},
      {"sequence", 1.0},
      {"occurred_at", "not-a-timestamp"},
      {"scope", wire_scope("run", @scope_id, -1)}
    ]

    for {field, value} <- invalid_fields do
      assert_error(
        base |> Map.put(field, value) |> Jason.encode!() |> Envelope.decode(),
        :invalid_envelope
      )
    end

    offset_timestamp = "2026-09-01T16:34:56.123456+04:00"

    assert {:ok, %Message{occurred_at: ^offset_timestamp}} =
             base
             |> Map.merge(%{
               "request_id" => @request_id,
               "sequence" => 0,
               "occurred_at" => offset_timestamp
             })
             |> Jason.encode!()
             |> Envelope.decode()
  end

  test "the prescribed noncanonical nonce alias is accepted without re-encode equality" do
    alias_nonce = String.duplicate("a", 43)
    assert {:ok, bytes} = Base.url_decode64(alias_nonce, padding: false)
    refute Base.url_encode64(bytes, padding: false) == alias_nonce

    assert {:ok, %Message{nonce: ^alias_nonce}} =
             wire_message("ping")
             |> Map.put("nonce", alias_nonce)
             |> Jason.encode!()
             |> Envelope.decode()
  end

  test "nonces must be exactly 43 base64url characters decoding to 32 bytes" do
    base = wire_message("ping")

    for nonce <- [
          nil,
          1,
          String.duplicate("a", 42),
          String.duplicate("a", 44),
          String.duplicate("*", 43),
          Base.url_encode64(:crypto.strong_rand_bytes(31), padding: false)
        ] do
      assert_error(
        base |> Map.put("nonce", nonce) |> Jason.encode!() |> Envelope.decode(),
        :invalid_envelope
      )
    end
  end

  test "body must be an object and decoded strings have copy semantics" do
    base = wire_message("ping")

    for body <- [nil, [], "text", 1, true] do
      assert_error(
        base |> Map.put("body", body) |> Jason.encode!() |> Envelope.decode(),
        :invalid_envelope
      )
    end

    retained = String.duplicate("r", 100)
    padding = String.duplicate("p", 100_000)

    assert {:ok, decoded} =
             base
             |> Map.put("body", %{"retained" => retained, "padding" => padding})
             |> Jason.encode!()
             |> Envelope.decode()

    assert :binary.referenced_byte_size(decoded.body["retained"]) == byte_size(retained)
  end

  test "encode rejects values outside the pure JSON domain without raising" do
    invalid_utf8 = <<255>>

    invalid_bodies = [
      %{atom_key: "value"},
      %{"value" => :atom},
      %{"value" => {:tuple, 1}},
      %{"value" => [1 | 2]},
      %{"value" => %URI{scheme: "https"}},
      %{"value" => invalid_utf8},
      %{"nested" => [%{1 => "nonbinary key"}]}
    ]

    for body <- invalid_bodies do
      assert_error(Envelope.encode(message(:ping, body: body)), :invalid_envelope)
    end

    for invalid <- [nil, %{}, "message", 1] do
      assert_error(Envelope.encode(invalid), :invalid_envelope)
    end
  end

  test "encode validates the same field rules as decode" do
    invalid_messages = [
      message(:unknown),
      message(:ping, version: 2),
      message(:request, request_id: nil),
      message(:event, scope: nil, sequence: nil, occurred_at: nil),
      message(:snapshot_required, scope: nil),
      message(:ping, request_id: "invalid"),
      message(:ping, nonce: "invalid"),
      message(:ping, sequence: -1),
      message(:ping, occurred_at: "invalid"),
      message(:ping, scope: %Scope{kind: :global, id: @scope_id, generation: 0})
    ]

    for invalid <- invalid_messages do
      assert {:error, %Error{}} = Envelope.encode(invalid)
    end
  end

  test "outbound encoding enforces complete-envelope depth and lexical entry limits" do
    shallow = nested_arrays(14, 0)

    shallow_message = message(:ping, body: %{"nested" => shallow})
    assert {:ok, encoded} = Envelope.encode(shallow_message)
    assert {:ok, ^shallow_message} = encoded |> IO.iodata_to_binary() |> Envelope.decode()

    too_deep = nested_arrays(15, 0)

    assert_error(
      Envelope.encode(message(:ping, body: %{"nested" => too_deep})),
      :json_too_deep
    )

    at_entry_limit = Enum.map(1..65_518, fn _ -> 0 end)
    at_entry_message = message(:ping, body: %{"items" => at_entry_limit})
    assert {:ok, encoded} = Envelope.encode(at_entry_message)
    assert {:ok, ^at_entry_message} = encoded |> IO.iodata_to_binary() |> Envelope.decode()

    over_entry_limit = Enum.map(1..65_519, fn _ -> 0 end)

    assert_error(
      Envelope.encode(message(:ping, body: %{"items" => over_entry_limit})),
      :json_entry_limit
    )
  end

  test "outbound structural checks stop at bounds before inspecting unbounded tails" do
    too_deep_with_invalid_tail = nested_arrays(15, %URI{scheme: "https"})

    assert_error(
      Envelope.encode(message(:ping, body: %{"nested" => too_deep_with_invalid_tail})),
      :json_too_deep
    )

    too_wide_with_invalid_tail =
      Enum.map(1..65_533, fn
        65_533 -> %URI{scheme: "https"}
        _ -> 0
      end)

    assert_error(
      Envelope.encode(message(:ping, body: %{"items" => too_wide_with_invalid_tail})),
      :json_entry_limit
    )

    # The struct itself would be outside the depth budget. Structural rejection
    # must win before the pure-domain struct check gets a chance to inspect it.
    at_depth_with_invalid_struct = nested_arrays(14, %URI{scheme: "https"})

    assert_error(
      Envelope.encode(message(:ping, body: %{"nested" => at_depth_with_invalid_struct})),
      :json_too_deep
    )
  end

  test "integer token bounds are symmetric and every successful boundary value decodes" do
    positive_max = String.duplicate("9", 1_024) |> String.to_integer()
    negative_max = String.duplicate("9", 1_023) |> String.to_integer() |> Kernel.-()
    positive_over = String.duplicate("9", 1_025) |> String.to_integer()
    negative_over = String.duplicate("9", 1_024) |> String.to_integer() |> Kernel.-()

    for integer <- [positive_max, negative_max] do
      message = message(:ping, body: %{"number" => integer})
      assert {:ok, encoded} = Envelope.encode(message)
      assert {:ok, ^message} = encoded |> IO.iodata_to_binary() |> Envelope.decode()
    end

    for integer <- [positive_over, negative_over] do
      assert_error(
        Envelope.encode(message(:ping, body: %{"number" => integer})),
        :invalid_envelope
      )
    end
  end

  test "duplicate keys at the envelope, scope, and body levels are invalid JSON" do
    base = Jason.encode!(wire_message("ping"))
    duplicate_outer = String.replace(base, ~s("v":1), ~s("v":1,"v":1))

    duplicate_scope =
      wire_message("ping")
      |> Map.put("scope", wire_scope("run", @scope_id, 0))
      |> Jason.encode!()
      |> String.replace(~s("generation":0), ~s("generation":0,"generation":0))

    duplicate_body = String.replace(base, ~s("body":{}), ~s("body":{"x":1,"x":2}))

    for document <- [duplicate_outer, duplicate_scope, duplicate_body] do
      assert_error(Envelope.decode(document), :invalid_json)
    end
  end

  test "public APIs return static typed errors and never echo raw input" do
    secret = "DO-NOT-ECHO-#{System.unique_integer([:positive])}"

    for input <- [nil, 1, [], %{}, {:not, :json}] do
      assert {:error, %Error{message: message}} = Envelope.decode(input)
      refute String.contains?(message, inspect(input))
    end

    assert {:error, %Error{message: message}} = Envelope.decode("{\"#{secret}\":")
    refute String.contains?(message, secret)

    assert Enum.all?(
             ~w(invalid_json json_too_large json_too_deep json_entry_limit invalid_envelope unsupported_protocol_version unknown_message_type unknown_scope_kind)a,
             fn code ->
               %Error{code: ^code, message: error_message} = Error.new(code)
               is_binary(error_message) and error_message != ""
             end
           )
  end

  defp message(type, overrides \\ []) do
    struct!(
      Message,
      Keyword.merge(
        [
          version: 1,
          type: type,
          request_id: nil,
          nonce: @nonce,
          scope: nil,
          sequence: nil,
          occurred_at: nil,
          body: %{}
        ],
        overrides
      )
    )
  end

  defp wire_message(type) do
    %{
      "v" => 1,
      "type" => type,
      "request_id" => nil,
      "nonce" => @nonce,
      "scope" => nil,
      "sequence" => nil,
      "occurred_at" => nil,
      "body" => %{}
    }
  end

  defp wire_scope(kind, id, generation) do
    %{"kind" => kind, "id" => id, "generation" => generation}
  end

  defp nested_arrays(0, value), do: value
  defp nested_arrays(depth, value), do: [nested_arrays(depth - 1, value)]

  defp assert_round_trip(message) do
    assert {:ok, encoded} = Envelope.encode(message)
    assert {:ok, ^message} = encoded |> IO.iodata_to_binary() |> Envelope.decode()
  end

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code, message: message}} = result
    assert is_binary(message)
    assert message != ""
  end
end
