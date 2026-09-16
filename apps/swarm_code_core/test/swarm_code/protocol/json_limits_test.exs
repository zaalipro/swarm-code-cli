defmodule SwarmCode.Protocol.JsonLimitsTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{Error, JsonLimits}

  test "preflight rejects nesting and entry bombs while ignoring string contents" do
    too_deep = String.duplicate("[", 17) <> String.duplicate("]", 17)
    assert_error(JsonLimits.validate(too_deep), :json_too_deep)

    bomb = "[" <> Enum.map_join(1..65_537, ",", fn _ -> "0" end) <> "]"
    assert_error(JsonLimits.validate(bomb), :json_entry_limit)

    assert :ok =
             JsonLimits.validate(~s({"literal":"[[[[,,:,:]]]]","escaped":"\\\"{"}))
  end

  test "byte, depth, and aggregate entry limits honor exact boundaries" do
    assert :ok = JsonLimits.validate("null", max_bytes: 4, max_depth: 0, max_entries: 0)
    assert_error(JsonLimits.validate("null", max_bytes: 3), :json_too_large)

    at_depth = String.duplicate("[", 16) <> "0" <> String.duplicate("]", 16)
    over_depth = "[" <> at_depth <> "]"
    assert :ok = JsonLimits.validate(at_depth)
    assert_error(JsonLimits.validate(over_depth), :json_too_deep)

    at_entries = "[" <> Enum.map_join(1..65_536, ",", fn _ -> "0" end) <> "]"
    over_entries = "[" <> Enum.map_join(1..65_537, ",", fn _ -> "0" end) <> "]"
    assert :ok = JsonLimits.validate(at_entries)
    assert_error(JsonLimits.validate(over_entries), :json_entry_limit)
  end

  test "the shared default byte cap runs before structural scanning or decoding" do
    oversized_and_deep =
      String.duplicate("[", 17) <>
        String.duplicate(" ", 1_048_576) <>
        String.duplicate("]", 17)

    assert_error(JsonLimits.validate(oversized_and_deep), :json_too_large)

    exactly_maximum = "0" <> String.duplicate(" ", 1_048_575)
    assert :ok = JsonLimits.validate(exactly_maximum)
  end

  test "malformed lexical state and malformed JSON return one static error shape" do
    malformed = [
      "",
      "[",
      "]",
      "{]",
      ~s("unfinished),
      ~s("unfinished\\),
      ~s({"bad escape":"\\q"}),
      <<?", 255, ?">>
    ]

    for document <- malformed do
      assert_error(JsonLimits.validate(document), :invalid_json)
    end
  end

  test "decode rejects duplicate keys at every object level and returns copied string-key maps" do
    for document <- [
          ~s({"x":1,"x":2}),
          ~s({"nested":{"x":1,"x":2}}),
          ~s([{"x":1,"x":2}])
        ] do
      assert_error(JsonLimits.decode(document), :invalid_json)
    end

    retained = String.duplicate("r", 100)
    padding = String.duplicate("p", 100_000)
    document = Jason.encode!(%{"retained" => retained, "padding" => padding})

    assert {:ok, decoded} = JsonLimits.decode(document)
    assert decoded == %{"retained" => retained, "padding" => padding}
    assert Enum.all?(Map.keys(decoded), &is_binary/1)
    assert :binary.referenced_byte_size(decoded["retained"]) == byte_size(retained)
  end

  test "custom limits perform an exact recursive post-decode count" do
    assert {:ok, [[true], false]} =
             JsonLimits.decode(~s([[true],false]), max_entries: 3)

    assert_error(
      JsonLimits.decode(~s([[true],false]), max_entries: 2),
      :json_entry_limit
    )
  end

  test "validate delegates to decode and discards the value" do
    document = ~s({"one":[1,true,null,"four"]})
    assert {:ok, %{"one" => [1, true, nil, "four"]}} = JsonLimits.decode(document)
    assert :ok = JsonLimits.validate(document)

    duplicate = ~s({"one":1,"one":2})
    assert_error(JsonLimits.decode(duplicate), :invalid_json)
    assert_error(JsonLimits.validate(duplicate), :invalid_json)
  end

  test "public invalid inputs and options return typed errors rather than raising" do
    for input <- [nil, 1, [], %{}, {:not, :binary}] do
      assert_error(JsonLimits.decode(input), :invalid_json)
      assert_error(JsonLimits.validate(input), :invalid_json)
    end

    for options <- [
          [max_bytes: -1],
          [max_bytes: 1.0],
          [max_depth: -1],
          [max_entries: -1],
          [unknown: 1],
          :not_a_keyword
        ] do
      assert_error(JsonLimits.decode("null", options), :invalid_json)
      assert_error(JsonLimits.validate("null", options), :invalid_json)
    end
  end

  test "errors never contain attacker-controlled JSON or Jason diagnostics" do
    secret = "DO-NOT-ECHO-#{System.unique_integer([:positive])}"

    assert {:error, %Error{message: message}} = JsonLimits.decode("{\"#{secret}\":")
    refute String.contains?(message, secret)
    refute String.contains?(message, "position")
  end

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code, message: message}} = result
    assert is_binary(message)
    assert message != ""
  end
end
