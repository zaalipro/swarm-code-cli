defmodule SwarmCode.Domain.MCP.SSEFramer do
  @moduledoc """
  Incremental server-sent-events framing for MCP HTTP responses (spec 74
  EFFICIENCY-57).

  The collector called `LLM.SSE.parse(buffer, chunk)`, which normalises and
  splits `buffer <> chunk` whole on every chunk. A `tools/call` result is one
  event, so a 10 MB result in 16 KB chunks rescanned the growing buffer 640
  times (760 ms measured). Here the unfinished event is reversed iodata with a
  byte count; each chunk is normalised and searched once — plus the last byte
  of what came before, for a separator split across chunks — and an event is
  joined once, when it completes.

  The events equal `LLM.SSE.parse("", whole_body)`: `\\r\\n` becomes `\\n`
  (a chunk's trailing `\\r` waits for the next chunk, so a pair split across
  chunks is replaced like in the whole body), blocks end at `\\n\\n`, and each
  block is read with the same `data:`/`event:` rules.
  """

  alias SwarmCode.Domain.LLM.SSE

  defstruct parts: [], bytes: 0, last: nil, cr: false

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The unfinished event's size in bytes."
  @spec pending_bytes(t()) :: non_neg_integer()
  def pending_bytes(%__MODULE__{bytes: bytes}), do: bytes

  @doc "Feeds one chunk; returns the events it completed and the new state."
  @spec feed(t(), binary()) :: {[SSE.event()], t()}
  def feed(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    chunk = if state.cr, do: "\r" <> chunk, else: chunk

    {chunk, cr} =
      if byte_size(chunk) > 0 and :binary.last(chunk) == ?\r,
        do: {binary_part(chunk, 0, byte_size(chunk) - 1), true},
        else: {chunk, false}

    piece = String.replace(chunk, "\r\n", "\n")
    frame(%{state | cr: cr}, piece, [])
  end

  # A separator that starts on the last byte of the unfinished event.
  defp frame(%{last: ?\n} = state, <<?\n, rest::binary>>, events) do
    tail = IO.iodata_to_binary(Enum.reverse(state.parts))
    event = parse_block(binary_part(tail, 0, byte_size(tail) - 1))
    frame(%{state | parts: [], bytes: 0, last: nil}, rest, add(events, event))
  end

  defp frame(state, piece, events) do
    case :binary.split(piece, "\n\n") do
      [unfinished] ->
        state =
          if unfinished == <<>>,
            do: state,
            else: %{
              state
              | parts: [unfinished | state.parts],
                bytes: state.bytes + byte_size(unfinished),
                last: :binary.last(unfinished)
            }

        {Enum.reverse(events), state}

      [head, rest] ->
        event = block(state.parts, head)
        frame(%{state | parts: [], bytes: 0, last: nil}, rest, add(events, event))
    end
  end

  defp add(events, nil), do: events
  defp add(events, event), do: [event | events]

  defp block(parts, head), do: parse_block(IO.iodata_to_binary(Enum.reverse([head | parts])))

  # `LLM.SSE`'s block rules, on one complete block.
  defp parse_block(block) do
    {event, data} =
      block
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {event, data} ->
        cond do
          String.starts_with?(line, "data:") -> {event, [strip(line, "data:") | data]}
          String.starts_with?(line, "event:") -> {strip(line, "event:"), data}
          true -> {event, data}
        end
      end)

    if data == [], do: nil, else: %{event: event, data: data |> Enum.reverse() |> Enum.join("\n")}
  end

  defp strip(line, prefix) do
    line |> String.replace_prefix(prefix, "") |> String.replace_prefix(" ", "")
  end
end
