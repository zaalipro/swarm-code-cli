defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Decoder do
  @moduledoc "Incremental response framing with bounded retained bytes and atomic per-push admission."
  alias SwarmCode.Protocol.ChunkBuffer
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Wire
  @derive {Inspect, only: [:phase]}
  defstruct phase: :header, buffer: nil
  @max_body 262_167
  @max_push 1_048_576
  @max_records 16

  def new, do: %__MODULE__{buffer: ChunkBuffer.new()}
  def buffered_bytes(%__MODULE__{buffer: buffer}), do: ChunkBuffer.byte_size(buffer)

  def push(%__MODULE__{} = state, bytes)
      when is_binary(bytes) and byte_size(bytes) <= @max_push do
    if valid?(state), do: consume(state, bytes, [], 0), else: invalid()
  rescue
    _ -> invalid()
  end

  def push(_, _), do: invalid()

  defp valid?(%__MODULE__{phase: phase} = state) when map_size(state) == 3 do
    case {phase, buffered_bytes(state)} do
      {:header, n} when is_integer(n) and n in 0..3 ->
        true

      {{:body, length}, n}
      when length in 2..@max_body and is_integer(n) and n >= 0 and n < length ->
        true

      _ ->
        false
    end
  end

  defp valid?(_), do: false

  defp consume(state, <<>>, out, _), do: {:ok, Enum.reverse(out), state}
  defp consume(_, _, _, @max_records), do: invalid()

  defp consume(state, bytes, out, count) do
    wanted =
      case state.phase do
        :header -> 4
        {:body, n} -> n
      end

    available = buffered_bytes(state)
    take = min(wanted - available, byte_size(bytes))
    <<part::binary-size(take), rest::binary>> = bytes
    buffer = ChunkBuffer.put(state.buffer, part)
    next = %{state | buffer: buffer}

    if available + take == wanted do
      {:ok, parts, _empty} = ChunkBuffer.take(buffer, wanted)
      finish(next.phase, IO.iodata_to_binary(parts), rest, out, count)
    else
      {:ok, Enum.reverse(out), next}
    end
  end

  defp finish(:header, <<length::32>>, rest, out, count) when length in 2..@max_body,
    do: consume(%{new() | phase: {:body, length}}, rest, out, count)

  defp finish(:header, _, _, _, _), do: invalid()

  defp finish({:body, _}, body, rest, out, count) do
    case Wire.decode(body) do
      {:ok, record} -> consume(new(), rest, [record | out], count + 1)
      _ -> invalid()
    end
  end

  defp invalid, do: {:error, :invalid_record}
end
