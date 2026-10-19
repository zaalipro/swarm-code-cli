defmodule SwarmCode.Daemon.StartupError do
  @moduledoc false

  # The schema refusals share the code `:schema_incompatible`; `cause` tells the
  # one a caller must tell apart (`Schema.Refusal.database_mode/1`). It is a
  # closed atom set, also the directory protocol's, never a sentence. Every
  # other error has none.
  @causes [:database_mode]

  @enforce_keys [:code, :retryable, :message, :action]
  defexception [:code, :retryable, :message, :action, cause: nil]

  @type cause :: :database_mode
  @type t :: %__MODULE__{
          code: atom(),
          retryable: boolean(),
          message: String.t(),
          action: String.t(),
          cause: cause() | nil
        }

  @doc "The closed set of `cause` values."
  @spec causes() :: [cause()]
  def causes, do: @causes

  @spec new(atom(), boolean(), String.t(), String.t(), cause() | nil) :: t()
  def new(code, retryable, message, action, cause \\ nil)
      when is_atom(code) and is_boolean(retryable) and is_binary(message) and is_binary(action) and
             (is_nil(cause) or cause in @causes) do
    %__MODULE__{code: code, retryable: retryable, message: message, action: action, cause: cause}
  end
end
