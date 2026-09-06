defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.DecoderTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Decoder
  defp packet(body), do: <<byte_size(body)::32, body::binary>>

  test "every split preserves complete ordered records and retains only incomplete suffix" do
    ready = packet(<<1, 16, 7::64, 80::16, 24::16, 7>>)
    input = packet(<<1, 17, 7::64, 9::64, 1, 0, 0, 3::16, "界">>)
    both = ready <> input

    for at <- 0..byte_size(both) do
      <<head::binary-size(at), tail::binary>> = both
      assert {:ok, a, d} = Decoder.push(Decoder.new(), head)
      assert {:ok, b, d} = Decoder.push(d, tail)
      assert length(a ++ b) == 2
      assert List.last(a ++ b) == {:input, 7, 9, {:text_fragment, :press, "界", []}}
      assert Decoder.buffered_bytes(d) == 0
      refute inspect(d) =~ "界"
    end
  end

  test "largest response parses byte and chunk boundaries without repeated whole-body copying" do
    paste = String.duplicate("界", 87_381) <> "x"
    bytes = packet(<<1, 17, 7::64, 9::64, 2, byte_size(paste)::32, paste::binary>>)
    chunks = for <<chunk::binary-size(4096) <- bytes>>, do: chunk
    used = length(chunks) * 4096
    chunks = chunks ++ [binary_part(bytes, used, byte_size(bytes) - used)]

    {events, d} =
      Enum.reduce(chunks, {[], Decoder.new()}, fn chunk, {events, d} ->
        assert {:ok, next, d} = Decoder.push(d, chunk)
        assert Decoder.buffered_bytes(d) <= 262_167
        {events ++ next, d}
      end)

    assert events == [{:input, 7, 9, {:paste, paste}}]
    assert Decoder.buffered_bytes(d) == 0
  end

  test "length, burst and record errors fail atomically" do
    for bytes <- [
          <<0::32>>,
          <<262_168::32>>,
          <<0xFFFF_FFFF::32>>,
          packet(<<1, 99>>),
          String.duplicate("x", 262_172)
        ] do
      assert {:error, :invalid_record} = Decoder.push(Decoder.new(), bytes)
    end

    valid = packet(<<1, 21, 7::64, 1>>)
    assert {:error, :invalid_record} = Decoder.push(Decoder.new(), valid <> packet(<<1, 99>>))
    assert {:error, :invalid_record} = Decoder.push(Decoder.new(), String.duplicate(valid, 17))
    assert {:error, :invalid_record} = Decoder.push(%{}, valid)
  end
end
