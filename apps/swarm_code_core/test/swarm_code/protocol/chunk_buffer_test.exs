defmodule SwarmCode.Protocol.ChunkBufferTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Protocol.{ChunkBuffer, Error}

  test "puts and takes fragmented bytes in arrival order" do
    buffer =
      ChunkBuffer.new()
      |> ChunkBuffer.put("ab")
      |> ChunkBuffer.put(<<>>)
      |> ChunkBuffer.put("cdef")

    assert ChunkBuffer.byte_size(buffer) == 6
    assert :more = ChunkBuffer.take(buffer, 7)

    assert {:ok, first, buffer} = ChunkBuffer.take(buffer, 3)
    assert IO.iodata_to_binary(first) == "abc"
    assert ChunkBuffer.byte_size(buffer) == 3

    assert {:ok, second, buffer} = ChunkBuffer.take(buffer, 3)
    assert IO.iodata_to_binary(second) == "def"
    assert ChunkBuffer.byte_size(buffer) == 0
    assert ChunkBuffer.block_count(buffer) == 0
    assert ChunkBuffer.metadata_nodes(buffer) == 0
  end

  test "tiny fragments compact into bounded fixed batches" do
    byte_count = 100_000

    buffer =
      Enum.reduce(1..byte_count, ChunkBuffer.new(), fn _index, buffer ->
        ChunkBuffer.put(buffer, "x")
      end)

    assert ChunkBuffer.byte_size(buffer) == byte_count
    assert ChunkBuffer.block_count(buffer) <= div(byte_count - 1, ChunkBuffer.block_bytes()) + 1

    assert ChunkBuffer.metadata_nodes(buffer) <=
             ChunkBuffer.block_count(buffer) + 63

    assert {:ok, parts, empty} = ChunkBuffer.take(buffer, byte_count)
    assert IO.iodata_to_binary(parts) == String.duplicate("x", byte_count)
    assert ChunkBuffer.byte_size(empty) == 0
    assert ChunkBuffer.metadata_nodes(empty) == 0
  end

  test "interleaved tiny puts and takes cannot accumulate queue cells" do
    bytes = ChunkBuffer.block_bytes() * 8
    buffer = ChunkBuffer.put(ChunkBuffer.new(), String.duplicate("x", bytes))

    buffer =
      Enum.reduce(1..2_000, buffer, fn _index, buffer ->
        buffer = ChunkBuffer.put(buffer, "y")
        assert {:ok, ["x"], buffer} = ChunkBuffer.take(buffer, 1)
        buffer
      end)

    assert ChunkBuffer.byte_size(buffer) == bytes

    assert ChunkBuffer.metadata_nodes(buffer) <=
             ceil_div(bytes, ChunkBuffer.block_bytes()) + 63

    assert {:ok, parts, _empty} = ChunkBuffer.take(buffer, bytes)

    assert IO.iodata_to_binary(parts) ==
             String.duplicate("x", bytes - 2_000) <> String.duplicate("y", 2_000)
  end

  test "an exact compaction block leaves no empty metadata node" do
    buffer =
      Enum.reduce(1..ChunkBuffer.block_bytes(), ChunkBuffer.new(), fn _index, buffer ->
        ChunkBuffer.put(buffer, "x")
      end)

    assert ChunkBuffer.byte_size(buffer) == ChunkBuffer.block_bytes()
    assert ChunkBuffer.block_count(buffer) == 1
    assert ChunkBuffer.metadata_nodes(buffer) == 1

    assert {:ok, bytes, empty} = ChunkBuffer.take(buffer, ChunkBuffer.block_bytes())
    assert IO.iodata_to_binary(bytes) == String.duplicate("x", ChunkBuffer.block_bytes())
    assert ChunkBuffer.block_count(empty) == 0
    assert ChunkBuffer.metadata_nodes(empty) == 0
  end

  test "a tiny retained tail owns its bytes instead of pinning a large input" do
    source = String.duplicate("a", 131_072) <> "retained"
    wanted = byte_size(source) - byte_size("retained")
    buffer = ChunkBuffer.put(ChunkBuffer.new(), source)

    assert {:ok, prefix, buffer} = ChunkBuffer.take(buffer, wanted)
    assert IO.iodata_length(prefix) == wanted
    assert ChunkBuffer.byte_size(buffer) == byte_size("retained")
    assert ChunkBuffer.retained_byte_size(buffer) == byte_size("retained")

    assert {:ok, tail, empty} = ChunkBuffer.take(buffer, byte_size("retained"))
    assert IO.iodata_to_binary(tail) == "retained"
    assert ChunkBuffer.retained_byte_size(empty) == 0
  end

  test "every retained chunk owns its exact backing bytes" do
    source = String.duplicate("a", ChunkBuffer.block_bytes() + 1) <> "ignored"
    retained = binary_part(source, 0, ChunkBuffer.block_bytes() + 1)

    assert :binary.referenced_byte_size(retained) > byte_size(retained)

    buffer = ChunkBuffer.put(ChunkBuffer.new(), retained)
    assert ChunkBuffer.byte_size(buffer) == byte_size(retained)
    assert ChunkBuffer.retained_byte_size(buffer) == byte_size(retained)
  end

  test "public invalid inputs settle as typed errors" do
    buffer = ChunkBuffer.new()

    for invalid <- [nil, 1, [], %{}, {:not, :binary}] do
      assert {:error, %Error{}} = ChunkBuffer.put(buffer, invalid)
    end

    for invalid <- [-1, 1.0, nil, "1"] do
      assert {:error, %Error{}} = ChunkBuffer.take(buffer, invalid)
    end

    assert {:error, %Error{}} = ChunkBuffer.put(%{}, "bytes")
    assert {:error, %Error{}} = ChunkBuffer.take(%{}, 0)
  end

  test "forged storage, counts, members, and struct shape are rejected" do
    buffer = ChunkBuffer.new()

    forged_states =
      [
        %{buffer | queue: :queue.in(<<0::32>>, :queue.new()), bytes: 0},
        %{buffer | queue: :queue.new(), bytes: 1},
        %{buffer | pending: [:not_binary], pending_bytes: 0, bytes: 0},
        %{buffer | pending: ["x"], pending_bytes: 2, bytes: 1},
        %{buffer | pending: ["x"], pending_bytes: 1, bytes: 0},
        %{buffer | queue: :queue.in(:not_binary, :queue.new()), bytes: 1},
        %{buffer | queue: {:not, :a, :queue}, bytes: 0}
      ] ++ [Map.put(buffer, :unexpected, true)]

    for forged <- forged_states,
        candidate <- [
          forged,
          %{forged | seal: nil},
          externally_resealed(forged),
          externally_zero_arity_resealed(forged)
        ] do
      assert {:error, %Error{}} = ChunkBuffer.put(candidate, <<>>)
      assert {:error, %Error{}} = ChunkBuffer.take(candidate, 0)
      assert {:error, %Error{}} = ChunkBuffer.byte_size(candidate)
    end
  end

  test "content-equal sparse pending replacements are rejected" do
    content = String.duplicate("p", 100)
    buffer = ChunkBuffer.put(ChunkBuffer.new(), content)
    source = String.duplicate("s", 1_000_000) <> content
    sparse = binary_part(source, byte_size(source) - byte_size(content), byte_size(content))

    assert sparse == content
    assert :binary.referenced_byte_size(sparse) > byte_size(content)

    forged = %{buffer | pending: [sparse]}
    assert {:error, %Error{}} = ChunkBuffer.validate(forged)
    assert {:error, %Error{}} = ChunkBuffer.put(forged, <<>>)
    assert {:error, %Error{}} = ChunkBuffer.retained_byte_size(forged)
  end

  test "content-equal sparse queue replacements are rejected" do
    content = String.duplicate("q", ChunkBuffer.block_bytes())
    buffer = ChunkBuffer.put(ChunkBuffer.new(), content)
    source = String.duplicate("s", 1_000_000) <> content
    sparse = binary_part(source, byte_size(source) - byte_size(content), byte_size(content))
    queue = :queue.in(sparse, :queue.new())

    assert sparse == content
    assert :binary.referenced_byte_size(sparse) > byte_size(content)

    forged = %{buffer | queue: queue}
    assert {:error, %Error{}} = ChunkBuffer.validate(forged)
    assert {:error, %Error{}} = ChunkBuffer.take(forged, ChunkBuffer.block_bytes())
    assert {:error, %Error{}} = ChunkBuffer.retained_byte_size(forged)
  end

  test "altered projection validation is bounded by canonical payload size" do
    block = String.duplicate("b", ChunkBuffer.block_bytes())

    at_limit =
      Enum.reduce(1..1_024, ChunkBuffer.new(), fn _index, buffer ->
        ChunkBuffer.put(buffer, block)
      end)

    assert ChunkBuffer.block_count(at_limit) == 1_024
    assert :ok = at_limit |> replace_queue_storage() |> ChunkBuffer.validate()

    over_limit = ChunkBuffer.put(at_limit, block)
    assert ChunkBuffer.block_count(over_limit) == 1_025
    assert :ok = ChunkBuffer.validate(over_limit)
    assert :ok = over_limit |> replace_queue_storage() |> ChunkBuffer.validate()
  end

  defp externally_resealed(buffer) do
    %{buffer | seal: fn _queue, _pending, _bytes, _pending_bytes -> true end}
  end

  defp externally_zero_arity_resealed(buffer), do: %{buffer | seal: fn -> true end}

  defp replace_queue_storage(buffer) do
    {rear, front} = buffer.queue

    queue =
      {Enum.map(rear, &:binary.copy/1), Enum.map(front, &:binary.copy/1)}

    %{buffer | queue: queue}
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)
end
