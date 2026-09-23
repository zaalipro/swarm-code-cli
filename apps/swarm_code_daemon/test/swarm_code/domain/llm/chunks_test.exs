defmodule SwarmCode.Domain.LLM.ChunksTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.LLM.Chunks

  test "appends many chunks in order and accounts bytes" do
    chunks = Enum.reduce(1..10_000, Chunks.new(), fn _, acc -> Chunks.append(acc, "x") end)
    expected = Enum.join(List.duplicate("x", 10_000))
    assert Chunks.to_string(chunks) == expected
    assert chunks.size == byte_size(expected)
  end

  test "round trips UTF-8 split between appends" do
    <<left::binary-size(1), right::binary>> = "é"
    chunks = Chunks.new() |> Chunks.append(left) |> Chunks.append(right)
    assert Chunks.to_string(chunks) == "é"
  end

  test "a new chunk list is empty" do
    assert Chunks.empty?(Chunks.new())
    refute Chunks.empty?(Chunks.new("hello"))
  end
end
