defmodule SwarmCode.Domain.LLM.SSETest do
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.LLM.SSE

  test "parses a full event" do
    assert {[%{event: nil, data: "hello"}], ""} = SSE.parse("", "data: hello\n\n")
  end

  test "parses two events in one chunk" do
    assert {[%{data: "a"}, %{data: "b"}], ""} = SSE.parse("", "data: a\n\ndata: b\n\n")
  end

  test "keeps a partial event in the buffer" do
    assert {[%{data: "a"}], rest} = SSE.parse("", "data: a\n\ndata: b")
    assert rest == "data: b"
    assert {[%{data: "b"}], ""} = SSE.parse(rest, "\n\n")
  end

  test "captures the event line" do
    assert {[%{event: "ping", data: "{}"}], ""} = SSE.parse("", "event: ping\ndata: {}\n\n")
  end

  test "ignores comment lines" do
    assert {[%{data: "x"}], ""} = SSE.parse("", ": keep-alive\ndata: x\n\n")
  end

  test "handles CRLF input" do
    assert {[%{data: "x"}], ""} = SSE.parse("", "data: x\r\n\r\n")
  end

  test "joins multiple data lines" do
    assert {[%{event: "x", data: "1\n2"}], "data: tail"} =
             SSE.parse("", "event: x\ndata: 1\ndata: 2\n\ndata: tail")
  end

  # Spec 30 §4: ten thousand data lines are assembled by prepending and one
  # reverse, and come back in exactly the order they arrived.
  test "assembles ten thousand data lines in order" do
    lines = Enum.map_join(1..10_000, fn i -> "data: #{i}\n" end)
    assert {[%{data: data}], ""} = SSE.parse("", lines <> "\n")
    assert data == Enum.map_join(1..10_000, "\n", &Integer.to_string/1)
  end

  test "no data line is appended to the tail of the accumulator" do
    # cli020 L1: the CLI's copy of the parser is the synced one (the desktop
    # path held the frozen live copy, now removed).
    refute File.read!("lib/swarm_code/domain/llm/sse.ex") =~ "data ++ ["
  end

  describe "pass76 llm-sse-bound" do
    setup do
      previous = Application.fetch_env(:swarm_code_daemon, :llm_max_sse_event_bytes)
      Application.put_env(:swarm_code_daemon, :llm_max_sse_event_bytes, 64)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:swarm_code_daemon, :llm_max_sse_event_bytes, old)
          :error -> Application.delete_env(:swarm_code_daemon, :llm_max_sse_event_bytes)
        end
      end)
    end

    test "an unterminated event past the ceiling overflows" do
      assert {:ok, [], rest} = SSE.parse_bounded("", "data: " <> String.duplicate("x", 40))
      assert {:overflow, [], 64} = SSE.parse_bounded(rest, String.duplicate("y", 40))
    end

    test "events completed before the overflow are still returned" do
      chunk = "data: a\n\ndata: " <> String.duplicate("z", 80)
      assert {:overflow, [%{data: "a"}], 64} = SSE.parse_bounded("", chunk)
    end

    test "a long event that terminates under the ceiling is unchanged" do
      assert {:ok, [%{data: data}], ""} =
               SSE.parse_bounded("", "data: #{String.duplicate("k", 50)}\n\n")

      assert byte_size(data) == 50
    end

    test "the ceiling never exceeds the response ceiling" do
      previous = Application.fetch_env(:swarm_code_daemon, :llm_max_response_bytes)
      Application.put_env(:swarm_code_daemon, :llm_max_response_bytes, 16)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:swarm_code_daemon, :llm_max_response_bytes, old)
          :error -> Application.delete_env(:swarm_code_daemon, :llm_max_response_bytes)
        end
      end)

      assert SSE.max_event_bytes() == 16
    end

    test "byte-by-byte feeding equals the whole-body parse, CRLF split included" do
      Application.put_env(:swarm_code_daemon, :llm_max_sse_event_bytes, 4_194_304)
      body = "event: a\r\ndata: 1\r\n\r\n: ping\r\n\r\ndata: 2\ndata: 3\n\ndata: tail"
      {whole, whole_rest} = SSE.parse("", body)

      {events, rest} =
        for <<byte <- body>>, reduce: {[], ""} do
          {events, buffer} ->
            {new, buffer} = SSE.parse(buffer, <<byte>>)
            {events ++ new, buffer}
        end

      assert events == whole
      assert rest == whole_rest
    end
  end

  describe "pass76 fix-m3-sse push/2" do
    @stream "event: a\r\ndata: 1\r\n\r\n: keep\ndata: two\ndata: lines\n\n" <>
              "data: \u00e9\u00e9\r\n\r\ndata: tail"

    defp old_events(chunks) do
      {events, rest, _} =
        Enum.reduce(chunks, {[], "", nil}, fn chunk, {acc, buf, _} ->
          {evs, rest} = SSE.parse(buf, chunk)
          {acc ++ evs, rest, nil}
        end)

      {events, rest}
    end

    defp new_events(chunks) do
      {events, pending} =
        Enum.reduce(chunks, {[], SSE.new_pending()}, fn chunk, {acc, pending} ->
          assert {:ok, evs, pending} = SSE.push(pending, chunk)
          {acc ++ evs, pending}
        end)

      # The rest is whatever a closing blank line would reveal.
      {:ok, last, _} = SSE.push(pending, "\n\n")
      {events, last}
    end

    defp chunked(binary, size) when byte_size(binary) <= size, do: [binary]

    defp chunked(binary, size),
      do: [
        binary_part(binary, 0, size)
        | chunked(binary_part(binary, size, byte_size(binary) - size), size)
      ]

    test "matches parse/2 for every chunk size and a split between CR and LF" do
      for size <- [1, 2, 3, 4, 5, 7, 11, 64, 1_000] do
        chunks = chunked(@stream, size)
        {old, old_rest} = old_events(chunks)
        {new, last} = new_events(chunks)
        assert new == old
        assert [%{data: "tail"}] = last
        assert old_rest == "data: tail"
      end
    end

    test "accumulates a long unterminated event without losing a byte" do
      body = String.duplicate("abcdefghij", 2_000)

      pending =
        Enum.reduce(chunked("data: " <> body, 7), SSE.new_pending(), fn chunk, pending ->
          assert {:ok, [], pending} = SSE.push(pending, chunk)
          pending
        end)

      assert {:ok, [%{data: ^body}], _} = SSE.push(pending, "\n\n")
    end

    test "overflows past the ceiling like parse_bounded/2" do
      previous = Application.fetch_env(:swarm_code_daemon, :llm_max_sse_event_bytes)
      Application.put_env(:swarm_code_daemon, :llm_max_sse_event_bytes, 64)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:swarm_code_daemon, :llm_max_sse_event_bytes, old)
          :error -> Application.delete_env(:swarm_code_daemon, :llm_max_sse_event_bytes)
        end
      end)

      assert {:ok, [], pending} =
               SSE.push(SSE.new_pending(), "data: " <> String.duplicate("x", 40))

      assert {:overflow, [], 64} = SSE.push(pending, String.duplicate("y", 40))

      assert {:overflow, [%{data: "a"}], 64} =
               SSE.push(SSE.new_pending(), "data: a\n\ndata: " <> String.duplicate("z", 80))
    end
  end
end
