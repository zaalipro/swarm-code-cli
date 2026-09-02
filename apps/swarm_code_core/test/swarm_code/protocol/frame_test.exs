defmodule SwarmCode.Protocol.FrameTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Protocol.{ChunkBuffer, Envelope, Error, Frame, FrameDecoder, Message}

  @default_max_frame_bytes 1_048_576
  @maximum_u32 4_294_967_295
  @nonce "7MEe1H2sfyDTvqPFUwR54awB9ZyiW9I9oXaBbmV5_sQ"

  test "encode prepends the unsigned JSON iodata length without flattening the envelope" do
    message = message("one")

    assert {:ok, [<<length::unsigned-big-32>>, json]} = Frame.encode(message)
    assert is_list(json)
    assert length == IO.iodata_length(json)
    assert {:ok, ^message} = json |> IO.iodata_to_binary() |> Envelope.decode()
  end

  test "encode and decode accept the exact default maximum and reject one byte more" do
    probe = message("")
    assert {:ok, probe_json} = Envelope.encode(probe)

    at_maximum =
      message(String.duplicate("x", @default_max_frame_bytes - IO.iodata_length(probe_json)))

    assert {:ok, maximum_json} = Envelope.encode(at_maximum)
    assert IO.iodata_length(maximum_json) == @default_max_frame_bytes

    assert {:ok, [<<@default_max_frame_bytes::unsigned-big-32>>, ^maximum_json] = frame} =
             Frame.encode(at_maximum)

    assert {:ok, [^at_maximum], %FrameDecoder{buffered_bytes: 0}} =
             FrameDecoder.push(FrameDecoder.new(), IO.iodata_to_binary(frame))

    over_maximum =
      message(String.duplicate("x", @default_max_frame_bytes - IO.iodata_length(probe_json) + 1))

    assert_error(Frame.encode(over_maximum), :frame_too_large)
  end

  test "an exact-maximum partial decoder remains valid after process transfer" do
    probe = message("")
    assert {:ok, probe_json} = Envelope.encode(probe)

    expected =
      message(String.duplicate("x", @default_max_frame_bytes - IO.iodata_length(probe_json)))

    frame = expected |> Frame.encode!() |> IO.iodata_to_binary()
    <<header::binary-size(4), body::binary>> = frame
    body_prefix_bytes = byte_size(body) - 1
    <<body_prefix::binary-size(body_prefix_bytes), body_tail::binary>> = body

    assert {:ok, [], decoder} = FrameDecoder.push(FrameDecoder.new(), header)

    decoder =
      body_prefix
      |> fixed_chunks(ChunkBuffer.block_bytes())
      |> Enum.reduce(decoder, fn chunk, decoder ->
        assert {:ok, [], decoder} = FrameDecoder.push(decoder, chunk)
        decoder
      end)

    assert decoder.buffered_bytes == @default_max_frame_bytes - 1

    assert ChunkBuffer.metadata_nodes(decoder.buffer) <=
             ceil_div(@default_max_frame_bytes, ChunkBuffer.block_bytes()) + 63

    caller = self()
    reference = make_ref()

    task =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {^reference, transferred, tail} ->
               send(caller, {reference, FrameDecoder.push(transferred, tail)})
           end
         end}
      )

    send(task, {reference, decoder, body_tail})

    assert_receive {^reference,
                    {:ok, [^expected], %FrameDecoder{phase: :header, buffered_bytes: 0}}},
                   5_000
  end

  test "encode returns typed errors and encode! raises only for programmer-invalid input" do
    assert_error(Frame.encode(:not_a_message), :invalid_envelope)

    assert_raise ArgumentError, fn ->
      Frame.encode!(:not_a_message)
    end
  end

  test "every split point across coalesced frames decodes exactly once" do
    first = message("one")
    second = message("two")
    bytes = IO.iodata_to_binary([Frame.encode!(first), Frame.encode!(second)])

    Enum.each(0..byte_size(bytes), fn split ->
      <<left::binary-size(split), right::binary>> = bytes
      decoder = FrameDecoder.new()

      assert {:ok, left_messages, decoder} = FrameDecoder.push(decoder, left)
      assert {:ok, right_messages, decoder} = FrameDecoder.push(decoder, right)
      assert left_messages ++ right_messages == [first, second]
      assert decoder.phase == :header
      assert decoder.buffered_bytes == 0
    end)
  end

  test "a seeded fragmented schedule preserves one hundred coalesced frames exactly" do
    messages = Enum.map(1..100, &message("message-#{&1}"))
    bytes = messages |> Enum.map(&Frame.encode!/1) |> IO.iodata_to_binary()
    chunks = seeded_chunks(bytes, {73_191, 19_871, 91_337})

    {decoded_reversed, decoder} =
      Enum.reduce(chunks, {[], FrameDecoder.new()}, fn chunk, {decoded_reversed, decoder} ->
        assert {:ok, decoded, decoder} = FrameDecoder.push(decoder, chunk)
        {Enum.reverse(decoded, decoded_reversed), decoder}
      end)

    assert Enum.reverse(decoded_reversed) == messages
    assert decoder.phase == :header
    assert decoder.buffered_bytes == 0
  end

  test "zero, oversized, malformed, and too-many frames fail closed" do
    assert_error(FrameDecoder.push(FrameDecoder.new(), <<0::32>>), :zero_length_frame)

    assert_error(
      FrameDecoder.push(FrameDecoder.new(max_frame_bytes: 8), <<9::32>>),
      :frame_too_large
    )

    assert_error(FrameDecoder.push(FrameDecoder.new(), <<1::32, ?{>>), :invalid_json)

    ping = Frame.encode!(message("x"))

    assert_error(
      FrameDecoder.push(
        FrameDecoder.new(),
        IO.iodata_to_binary([ping, <<1::32, ?{>>])
      ),
      :invalid_json
    )

    assert_error(
      FrameDecoder.push(
        FrameDecoder.new(max_frames_per_push: 2),
        IO.iodata_to_binary([ping, ping, ping])
      ),
      :frame_count_limit
    )

    assert {:ok, sixty_four, %FrameDecoder{buffered_bytes: 0}} =
             FrameDecoder.push(FrameDecoder.new(), IO.iodata_to_binary(List.duplicate(ping, 64)))

    assert length(sixty_four) == 64

    assert_error(
      FrameDecoder.push(FrameDecoder.new(), IO.iodata_to_binary(List.duplicate(ping, 65))),
      :frame_count_limit
    )

    sixty_five_decoder = FrameDecoder.new(max_frames_per_push: 65)

    assert {:ok, sixty_five, %FrameDecoder{buffered_bytes: 0}} =
             FrameDecoder.push(
               sixty_five_decoder,
               IO.iodata_to_binary(List.duplicate(ping, 65))
             )

    assert length(sixty_five) == 65

    assert_error(
      FrameDecoder.push(
        sixty_five_decoder,
        IO.iodata_to_binary(List.duplicate(ping, 66))
      ),
      :frame_count_limit
    )

    assert sixty_five_decoder.buffered_bytes == 0
    assert sixty_five_decoder.phase == :header
  end

  test "the frame count limit permits an incomplete next frame and resets per push" do
    first = message("one")
    second = message("two")
    third = message("three")
    third_frame = Frame.encode!(third) |> IO.iodata_to_binary()
    split = byte_size(third_frame) - 1
    <<third_prefix::binary-size(split), third_tail::binary>> = third_frame

    first_push =
      IO.iodata_to_binary([Frame.encode!(first), Frame.encode!(second), third_prefix])

    decoder = FrameDecoder.new(max_frames_per_push: 2)
    assert {:ok, [^first, ^second], decoder} = FrameDecoder.push(decoder, first_push)
    assert decoder.phase != :header
    assert {:ok, [^third], decoder} = FrameDecoder.push(decoder, third_tail)
    assert decoder.phase == :header
    assert decoder.buffered_bytes == 0
  end

  test "the configured ceiling handles 1,024 coalesced frames atomically" do
    expected = message("ceiling")
    ping = Frame.encode!(expected)
    decoder = FrameDecoder.new(max_frames_per_push: 1_024)

    assert {:ok, messages, %FrameDecoder{phase: :header, buffered_bytes: 0}} =
             FrameDecoder.push(decoder, IO.iodata_to_binary(List.duplicate(ping, 1_024)))

    assert length(messages) == 1_024
    assert Enum.all?(messages, &(&1 == expected))

    assert_error(
      FrameDecoder.push(decoder, IO.iodata_to_binary(List.duplicate(ping, 1_025))),
      :frame_count_limit
    )

    assert decoder.phase == :header
    assert decoder.buffered_bytes == 0
  end

  test "empty pushes are no-ops for new and partially filled decoders" do
    decoder = FrameDecoder.new()
    assert {:ok, [], ^decoder} = FrameDecoder.push(decoder, <<>>)

    assert {:ok, [], partial} = FrameDecoder.push(decoder, <<0, 0>>)
    assert partial.buffered_bytes == 2
    assert {:ok, [], ^partial} = FrameDecoder.push(partial, <<>>)
  end

  test "one-byte delivery bounds payload and metadata while decoding once" do
    expected = message(String.duplicate("x", 100_000))
    bytes = expected |> Frame.encode!() |> IO.iodata_to_binary()

    {decoded_reversed, decoder} =
      Enum.reduce(:binary.bin_to_list(bytes), {[], FrameDecoder.new()}, fn byte,
                                                                           {decoded_reversed,
                                                                            decoder} ->
        assert {:ok, decoded, decoder} = FrameDecoder.push(decoder, <<byte>>)
        assert decoder.buffered_bytes <= @default_max_frame_bytes
        assert decoder.buffered_bytes == decoder.buffer.bytes
        assert ChunkBuffer.metadata_nodes(decoder.buffer) <= ChunkBuffer.block_bytes() + 256
        {Enum.reverse(decoded, decoded_reversed), decoder}
      end)

    assert Enum.reverse(decoded_reversed) == [expected]
    assert decoder.buffered_bytes == 0
    assert ChunkBuffer.block_count(decoder.buffer) == 0
    assert ChunkBuffer.metadata_nodes(decoder.buffer) == 0
  end

  test "constructor validates positive bounded limits without creating runtime atoms" do
    assert %FrameDecoder{
             max_frame_bytes: @maximum_u32,
             max_frames_per_push: 1
           } = FrameDecoder.new(max_frame_bytes: @maximum_u32, max_frames_per_push: 1)

    assert %FrameDecoder{max_frames_per_push: 1_024} =
             FrameDecoder.new(max_frames_per_push: 1_024)

    assert_error(FrameDecoder.new(max_frames_per_push: 1_025), :frame_count_limit)

    for options <- [
          [max_frame_bytes: 0],
          [max_frame_bytes: -1],
          [max_frame_bytes: 1.0],
          [max_frame_bytes: @maximum_u32 + 1],
          [max_frames_per_push: 0],
          [max_frames_per_push: -1],
          [max_frames_per_push: 1.0],
          [max_frame_bytes: 8, max_frame_bytes: 9],
          [unknown: 1],
          [{"max_frame_bytes", 1}],
          :not_a_keyword,
          %{}
        ] do
      assert {:error, %Error{message: message}} = FrameDecoder.new(options)
      assert is_binary(message) and message != ""
    end

    _ = FrameDecoder.new([{"warmup-#{System.unique_integer([:positive])}", 1}])
    before = :erlang.system_info(:atom_count)

    Enum.each(1..1_000, fn number ->
      assert {:error, %Error{}} = FrameDecoder.new([{"untrusted-#{number}", 1}])
    end)

    assert :erlang.system_info(:atom_count) == before
  end

  test "invalid push inputs return typed errors instead of raising" do
    decoder = FrameDecoder.new()

    for input <- [nil, 1, [], %{}, {:not, :binary}] do
      assert {:error, %Error{}} = FrameDecoder.push(decoder, input)
    end

    for invalid_decoder <- [
          nil,
          %{},
          %{decoder | phase: {:body, 0}},
          %{decoder | buffered_bytes: 1}
        ] do
      assert {:error, %Error{}} = FrameDecoder.push(invalid_decoder, <<>>)
    end
  end

  test "decoder rejects forged buffer storage and unexpected struct shape" do
    decoder = FrameDecoder.new()

    forged_buffers = [
      %{decoder.buffer | queue: :queue.in(<<0::32>>, :queue.new()), bytes: 0},
      %{decoder.buffer | queue: :queue.new(), bytes: 1},
      %{decoder.buffer | pending: [:not_binary], pending_bytes: 0, bytes: 0},
      %{decoder.buffer | pending: ["x"], pending_bytes: 2, bytes: 1}
    ]

    for buffer <- forged_buffers,
        candidate <- [
          buffer,
          %{buffer | seal: nil},
          externally_resealed(buffer),
          externally_zero_arity_resealed(buffer)
        ] do
      forged = %{decoder | buffer: candidate, buffered_bytes: candidate.bytes}
      assert {:error, %Error{}} = FrameDecoder.push(forged, <<>>)
    end

    assert {:error, %Error{}} =
             decoder
             |> Map.put(:unexpected, true)
             |> FrameDecoder.push(<<>>)
  end

  defp message(value) do
    %Message{
      version: 1,
      type: :ping,
      request_id: nil,
      nonce: @nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: %{"value" => value}
    }
  end

  defp seeded_chunks(binary, seed) do
    :rand.seed(:exsss, seed)
    do_seeded_chunks(binary, [])
  end

  defp do_seeded_chunks(<<>>, chunks), do: Enum.reverse(chunks)

  defp do_seeded_chunks(binary, chunks) do
    size = min(byte_size(binary), :rand.uniform(97))
    <<chunk::binary-size(size), rest::binary>> = binary
    do_seeded_chunks(rest, [chunk | chunks])
  end

  defp fixed_chunks(binary, chunk_bytes), do: fixed_chunks(binary, chunk_bytes, [])

  defp fixed_chunks(<<>>, _chunk_bytes, chunks), do: Enum.reverse(chunks)

  defp fixed_chunks(binary, chunk_bytes, chunks) do
    size = min(byte_size(binary), chunk_bytes)
    <<chunk::binary-size(size), rest::binary>> = binary
    fixed_chunks(rest, chunk_bytes, [chunk | chunks])
  end

  defp externally_resealed(buffer) do
    %{buffer | seal: fn _queue, _pending, _bytes, _pending_bytes -> true end}
  end

  defp externally_zero_arity_resealed(buffer), do: %{buffer | seal: fn -> true end}

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code, message: message}} = result
    assert is_binary(message)
    assert message != ""
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)
end
