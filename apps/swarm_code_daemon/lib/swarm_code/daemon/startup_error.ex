defmodule SwarmCode.Daemon.StartupError do
  @moduledoc false

  @enforce_keys [:code, :retryable, :message, :action]
  defexception @enforce_keys

  @type t :: %__MODULE__{
          code: atom(),
          retryable: boolean(),
          message: String.t(),
          action: String.t()
        }

  @spec new(atom(), boolean(), String.t(), String.t()) :: t()
  def new(code, retryable, message, action)
      when is_atom(code) and is_boolean(retryable) and is_binary(message) and is_binary(action) do
    %__MODULE__{code: code, retryable: retryable, message: message, action: action}
  end
end
