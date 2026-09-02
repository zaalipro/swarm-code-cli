defmodule SwarmCode.Protocol.Frame do
  @moduledoc "Length-prefix encoding for bounded v1 JSON envelopes."

  alias SwarmCode.Protocol.{Envelope, Error, Message}

  @default_max_frame_bytes 1_048_576

  @doc "Encode a message as a four-byte unsigned length followed by JSON iodata."
  @spec encode(Message.t()) :: {:ok, iodata()} | {:error, Error.t()}
  def encode(message) do
    with {:ok, json} <- Envelope.encode(message),
         length = IO.iodata_length(json),
         :ok <- validate_length(length) do
      {:ok, [<<length::unsigned-big-32>>, json]}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_envelope)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_envelope)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_envelope)}
  end

  @doc "Encode a programmer-supplied message, raising when it is invalid."
  @spec encode!(Message.t()) :: iodata()
  def encode!(message) do
    case encode(message) do
      {:ok, frame} -> frame
      {:error, %Error{message: message}} -> raise ArgumentError, message
      _other -> raise ArgumentError, "invalid protocol frame"
    end
  end

  defp validate_length(length) when length > 0 and length <= @default_max_frame_bytes, do: :ok
  defp validate_length(_length), do: {:error, Error.new(:frame_too_large)}
end
