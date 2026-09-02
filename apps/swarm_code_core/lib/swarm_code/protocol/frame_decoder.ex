defmodule SwarmCode.Protocol.FrameDecoder do
  @moduledoc """
  Incrementally decodes four-byte length-prefixed JSON envelopes.

  A push is all-or-nothing: decoded messages are returned only after every
  complete frame in that push has succeeded. On any error the caller must
  discard the decoder and close its connection. The default per-push count is
  64; callers may raise it to the finite safety ceiling of 1,024 when a
  coalesced batch requires it.
  """

  alias SwarmCode.Protocol.{ChunkBuffer, Envelope, Error, Message}

  @default_max_frame_bytes 1_048_576
  @default_max_frames_per_push 64
  # The option remains configurable above the default, while this finite
  # ceiling bounds per-push output and recursion under hostile coalescing.
  @maximum_frames_per_push 1_024
  @maximum_u32 4_294_967_295

  defstruct phase: nil,
            buffer: nil,
            buffered_bytes: nil,
            max_frame_bytes: nil,
            max_frames_per_push: nil

  @type phase :: :header | {:body, pos_integer()}

  # `buffered_bytes` is a compatibility projection of `buffer.bytes`; the
  # decoder never increments or decrements it independently.
  @type t :: %__MODULE__{
          phase: phase(),
          buffer: ChunkBuffer.t(),
          buffered_bytes: non_neg_integer(),
          max_frame_bytes: pos_integer(),
          max_frames_per_push: pos_integer()
        }

  @doc "Build a decoder; frame-count defaults to 64 and may be configured up to 1,024."
  @spec new(keyword()) :: t() | {:error, Error.t()}
  def new(options \\ []) do
    with {:ok, max_frame_bytes, max_frames_per_push} <- normalize_options(options) do
      %__MODULE__{
        phase: :header,
        buffer: ChunkBuffer.new(),
        buffered_bytes: 0,
        max_frame_bytes: max_frame_bytes,
        max_frames_per_push: max_frames_per_push
      }
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  @doc "Push one received binary and decode all of its complete frames atomically."
  @spec push(t(), binary()) :: {:ok, [Message.t()], t()} | {:error, Error.t()}
  def push(%__MODULE__{} = decoder, binary) when is_binary(binary) do
    with :ok <- validate_decoder(decoder),
         %ChunkBuffer{} = buffer <- ChunkBuffer.put(decoder.buffer, binary),
         buffered_bytes when is_integer(buffered_bytes) <- ChunkBuffer.byte_size(buffer) do
      decoder = %{
        decoder
        | buffer: buffer,
          buffered_bytes: buffered_bytes
      }

      decode_available(decoder, [], 0)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  def push(_decoder, _binary), do: {:error, Error.new(:invalid_envelope)}

  defp decode_available(
         %__MODULE__{phase: :header, buffered_bytes: buffered_bytes} = decoder,
         out,
         _count
       )
       when buffered_bytes < 4 do
    {:ok, Enum.reverse(out), decoder}
  end

  defp decode_available(%__MODULE__{phase: :header} = decoder, out, count) do
    with {:ok, header, decoder} <- take_bytes(decoder, 4),
         <<length::unsigned-big-32>> <- IO.iodata_to_binary(header),
         :ok <- validate_frame_length(length, decoder.max_frame_bytes) do
      decode_available(%{decoder | phase: {:body, length}}, out, count)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  end

  defp decode_available(
         %__MODULE__{phase: {:body, length}, buffered_bytes: buffered_bytes} = decoder,
         out,
         _count
       )
       when buffered_bytes < length do
    {:ok, Enum.reverse(out), decoder}
  end

  defp decode_available(
         %__MODULE__{phase: {:body, _length}, max_frames_per_push: limit},
         _out,
         count
       )
       when count >= limit do
    {:error, Error.new(:frame_count_limit)}
  end

  defp decode_available(%__MODULE__{phase: {:body, length}} = decoder, out, count) do
    with {:ok, body, decoder} <- take_bytes(decoder, length),
         {:ok, message} <- body |> IO.iodata_to_binary() |> Envelope.decode() do
      decode_available(%{decoder | phase: :header}, [message | out], count + 1)
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_json)}
    end
  end

  defp take_bytes(decoder, wanted) do
    case ChunkBuffer.take(decoder.buffer, wanted) do
      {:ok, parts, buffer} ->
        case ChunkBuffer.byte_size(buffer) do
          buffered_bytes when is_integer(buffered_bytes) ->
            {:ok, parts, %{decoder | buffer: buffer, buffered_bytes: buffered_bytes}}

          {:error, %Error{} = error} ->
            {:error, error}

          _other ->
            {:error, Error.new(:invalid_envelope)}
        end

      {:error, %Error{} = error} ->
        {:error, error}

      :more ->
        {:error, Error.new(:invalid_envelope)}

      _other ->
        {:error, Error.new(:invalid_envelope)}
    end
  end

  defp validate_frame_length(0, _max_frame_bytes),
    do: {:error, Error.new(:zero_length_frame)}

  defp validate_frame_length(length, max_frame_bytes) when length <= max_frame_bytes, do: :ok
  defp validate_frame_length(_length, _max_frame_bytes), do: {:error, Error.new(:frame_too_large)}

  defp normalize_options(options) when is_list(options) do
    reduce_options(
      options,
      @default_max_frame_bytes,
      @default_max_frames_per_push,
      false,
      false
    )
  end

  defp normalize_options(_options), do: {:error, Error.new(:invalid_envelope)}

  defp reduce_options([], max_frame_bytes, max_frames_per_push, _seen_frame?, _seen_count?) do
    {:ok, max_frame_bytes, max_frames_per_push}
  end

  defp reduce_options(
         [{:max_frame_bytes, value} | rest],
         _max_frame_bytes,
         max_frames_per_push,
         false,
         seen_count?
       )
       when is_integer(value) and value > 0 and value <= @maximum_u32 do
    reduce_options(rest, value, max_frames_per_push, true, seen_count?)
  end

  defp reduce_options(
         [{:max_frame_bytes, _value} | _rest],
         _max_frame_bytes,
         _max_frames_per_push,
         _seen_frame?,
         _seen_count?
       ) do
    {:error, Error.new(:frame_too_large)}
  end

  defp reduce_options(
         [{:max_frames_per_push, value} | rest],
         max_frame_bytes,
         _max_frames_per_push,
         seen_frame?,
         false
       )
       when is_integer(value) and value > 0 and value <= @maximum_frames_per_push do
    reduce_options(rest, max_frame_bytes, value, seen_frame?, true)
  end

  defp reduce_options(
         [{:max_frames_per_push, _value} | _rest],
         _max_frame_bytes,
         _max_frames_per_push,
         _seen_frame?,
         _seen_count?
       ) do
    {:error, Error.new(:frame_count_limit)}
  end

  defp reduce_options(
         _invalid,
         _max_frame_bytes,
         _max_frames_per_push,
         _seen_frame?,
         _seen_count?
       ) do
    {:error, Error.new(:invalid_envelope)}
  end

  defp validate_decoder(
         %__MODULE__{
           phase: phase,
           buffer: %ChunkBuffer{} = buffer,
           buffered_bytes: buffered_bytes,
           max_frame_bytes: max_frame_bytes,
           max_frames_per_push: max_frames_per_push
         } = decoder
       )
       when is_integer(buffered_bytes) and buffered_bytes >= 0 and is_integer(max_frame_bytes) and
              max_frame_bytes > 0 and
              max_frame_bytes <= @maximum_u32 and is_integer(max_frames_per_push) and
              max_frames_per_push > 0 and max_frames_per_push <= @maximum_frames_per_push do
    if exact_struct_shape?(decoder) do
      with ^buffered_bytes <- ChunkBuffer.byte_size(buffer),
           :ok <- validate_stable_phase(phase, buffered_bytes, max_frame_bytes) do
        :ok
      else
        {:error, %Error{} = error} -> {:error, error}
        _other -> {:error, Error.new(:invalid_envelope)}
      end
    else
      {:error, Error.new(:invalid_envelope)}
    end
  end

  defp validate_decoder(_decoder), do: {:error, Error.new(:invalid_envelope)}

  defp exact_struct_shape?(%__MODULE__{} = decoder) do
    map_size(decoder) == 6
  end

  defp validate_stable_phase(:header, buffered_bytes, _max_frame_bytes)
       when buffered_bytes < 4,
       do: :ok

  defp validate_stable_phase({:body, length}, buffered_bytes, max_frame_bytes)
       when is_integer(length) and length > 0 and length <= max_frame_bytes and
              buffered_bytes < length,
       do: :ok

  defp validate_stable_phase(_phase, _buffered_bytes, _max_frame_bytes),
    do: {:error, Error.new(:invalid_envelope)}
end
