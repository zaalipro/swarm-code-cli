defmodule SwarmCode.Domain.LLM.SSE do
  @moduledoc "Incremental server-sent-events parser shared by the LLM clients."

  @type event :: %{event: String.t() | nil, data: String.t()}

  @doc """
  Appends `chunk` to `buffer`, returns every complete event and the unparsed rest.

      iex> SwarmCode.Domain.LLM.SSE.parse("", "event: x\\ndata: 1\\ndata: 2\\n\\ndata: tail")
      {[%{event: "x", data: "1\\n2"}], "data: tail"}
  """
  @spec parse(String.t(), String.t()) :: {[event], String.t()}
  def parse(buffer, chunk) do
    # `buffer` is the previous call's already-normalised rest. Only its last
    # bytes can still join the new chunk (a `\r` waiting for its `\n`, or a
    # first `\n` of a separator), so the unterminated head is never rescanned.
    keep = max(byte_size(buffer) - 3, 0)
    head = binary_part(buffer, 0, keep)
    tail = binary_part(buffer, keep, byte_size(buffer) - keep)
    piece = String.replace(tail <> chunk, "\r\n", "\n")

    case :binary.match(piece, "\n\n") do
      :nomatch ->
        {[], head <> piece}

      _found ->
        parts = String.split(head <> piece, "\n\n")
        {complete, [rest]} = Enum.split(parts, -1)
        events = complete |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1)
        {events, rest}
    end
  end

  # pass76 llm-sse-bound: a server that never ends an event would grow the
  # buffer without limit; 4 MiB is far above any real event (one tool-call
  # delta or one thinking block) and the call's whole-response ceiling is the
  # hard upper limit.
  @max_event_bytes 4_194_304

  @doc """
  The most bytes an unterminated event may hold: 4 MiB, never above
  `:llm_max_response_bytes`. App env `:llm_max_sse_event_bytes` lowers it (tests).
  """
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes do
    limit = Application.get_env(:swarm_code_daemon, :llm_max_sse_event_bytes, @max_event_bytes)
    min(limit, SwarmCode.Domain.LLM.HTTP.max_response_bytes())
  end

  @doc """
  Like `parse/2`, but an unterminated event past `max_event_bytes/0` gives
  `{:overflow, events, limit}` (the events completed before it) instead of a rest.
  """
  @spec parse_bounded(String.t(), String.t()) ::
          {:ok, [event], String.t()} | {:overflow, [event], pos_integer()}
  def parse_bounded(buffer, chunk) do
    {events, rest} = parse(buffer, chunk)
    limit = max_event_bytes()

    if byte_size(rest) > limit,
      do: {:overflow, events, limit},
      else: {:ok, events, rest}
  end

  @typedoc """
  An unterminated event kept as reversed fragments, their byte count and the
  last (at most) 3 bytes, which can still join the next chunk.
  """
  @opaque pending :: {[binary()], non_neg_integer(), binary()}

  @doc "The empty `pending/0` state."
  @spec new_pending() :: pending()
  def new_pending, do: {[], 0, ""}

  @doc """
  pass76 fix-m3-sse (M3-R1-003): `parse_bounded/2` without re-copying the
  growing unterminated event. Fragments are kept as a list with a byte count;
  only the new bytes plus the small boundary overlap are scanned, and the
  fragments are flattened once, when an event completes. Events and rest are
  byte-identical to `parse/2`'s.
  """
  @spec push(pending(), String.t()) ::
          {:ok, [event], pending()} | {:overflow, [event], pos_integer()}
  def push({parts, bytes, tail}, chunk) do
    piece = String.replace(tail <> chunk, "\r\n", "\n")

    case :binary.match(piece, "\n\n") do
      :nomatch ->
        bounded({[], settle(parts, bytes, piece)})

      _found ->
        blocks = [Enum.reverse(parts), piece] |> IO.iodata_to_binary() |> String.split("\n\n")
        {complete, [rest]} = Enum.split(blocks, -1)
        events = complete |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1)
        bounded({events, settle([], 0, rest)})
    end
  end

  defp settle(parts, bytes, piece) when byte_size(piece) > 3 do
    keep = byte_size(piece) - 3

    {[binary_part(piece, 0, keep) | parts], bytes + keep, binary_part(piece, keep, 3)}
  end

  defp settle(parts, bytes, piece), do: {parts, bytes, piece}

  defp bounded({events, {_parts, bytes, tail} = pending}) do
    limit = max_event_bytes()

    if bytes + byte_size(tail) > limit,
      do: {:overflow, events, limit},
      else: {:ok, events, pending}
  end

  defp parse_block(block) do
    # Data lines are collected newest-first and reversed once: an event with
    # thousands of `data:` lines used to copy the whole list per line.
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
