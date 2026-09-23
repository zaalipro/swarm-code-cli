defmodule SwarmCode.Domain.LLM.SSETest do
  use ExUnit.Case, async: true

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
    refute File.read!("lib/swarm_code/llm/sse.ex") =~ "data ++ ["
  end
end
