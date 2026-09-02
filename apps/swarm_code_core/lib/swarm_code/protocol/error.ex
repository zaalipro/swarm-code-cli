defmodule SwarmCode.Protocol.Error do
  @moduledoc """
  A small, closed set of local protocol/codec errors.

  Error messages are deliberately static.  In particular, callers must not put
  wire input or a parser's diagnostic (which can contain wire input) in this
  struct.
  """

  @enforce_keys [:code, :message]
  defstruct @enforce_keys

  @typedoc "The protocol errors defined by the v1 envelope and frame codecs."
  @type code ::
          :invalid_json
          | :json_too_large
          | :json_too_deep
          | :json_entry_limit
          | :invalid_envelope
          | :unsupported_protocol_version
          | :unknown_message_type
          | :unknown_scope_kind
          | :zero_length_frame
          | :frame_too_large
          | :frame_count_limit

  @type t :: %__MODULE__{code: code(), message: binary()}

  @doc "Build a protocol error using a compile-time-known code."
  @spec new(code()) :: t()
  def new(:invalid_json), do: error(:invalid_json, "invalid JSON")
  def new(:json_too_large), do: error(:json_too_large, "JSON exceeds maximum size")
  def new(:json_too_deep), do: error(:json_too_deep, "JSON nesting exceeds maximum depth")
  def new(:json_entry_limit), do: error(:json_entry_limit, "JSON entry limit exceeded")
  def new(:invalid_envelope), do: error(:invalid_envelope, "invalid protocol envelope")

  def new(:unsupported_protocol_version),
    do: error(:unsupported_protocol_version, "unsupported protocol version")

  def new(:unknown_message_type), do: error(:unknown_message_type, "unknown message type")
  def new(:unknown_scope_kind), do: error(:unknown_scope_kind, "unknown scope kind")
  def new(:zero_length_frame), do: error(:zero_length_frame, "zero-length frame")
  def new(:frame_too_large), do: error(:frame_too_large, "frame exceeds maximum size")
  def new(:frame_count_limit), do: error(:frame_count_limit, "frame count limit exceeded")

  defp error(code, message), do: %__MODULE__{code: code, message: message}
end
