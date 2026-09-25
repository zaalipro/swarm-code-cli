defmodule SwarmCode.Daemon.Service.Settings.Error do
  @moduledoc "A settings request that did not happen, with the words the row shows (§3.3.1)."

  defexception code: :unavailable, message: "Couldn't read settings right now.", field_errors: []

  @type code :: :invalid | :not_found | :conflict | :unavailable | :busy | :unsupported
  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          field_errors: [%{target: String.t(), message: String.t()}]
        }

  @doc "An error with a code and its words."
  @spec new(code(), String.t(), list()) :: t()
  def new(code, message, field_errors \\ []),
    do: %__MODULE__{code: code, message: message, field_errors: field_errors}

  @doc "The words when a handler or module failed unexpectedly."
  @spec unavailable() :: t()
  def unavailable, do: new(:unavailable, "Couldn't read settings right now.")

  @doc "The words when a part of settings is missing from this build."
  @spec unsupported() :: t()
  def unsupported, do: new(:unsupported, "This part of settings is not available in this build.")
end
