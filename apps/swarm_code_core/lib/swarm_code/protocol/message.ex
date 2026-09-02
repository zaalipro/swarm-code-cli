defmodule SwarmCode.Protocol.Message do
  @moduledoc "The closed, version-one protocol message shape."

  alias SwarmCode.Protocol.Scope

  @enforce_keys [:version, :type, :request_id, :nonce, :scope, :sequence, :occurred_at, :body]
  defstruct @enforce_keys

  @type message_type ::
          :hello
          | :hello_ok
          | :request
          | :response
          | :event
          | :error
          | :snapshot_required
          | :ping
          | :pong

  @type t :: %__MODULE__{
          version: 1,
          type: message_type(),
          request_id: binary() | nil,
          nonce: binary(),
          scope: Scope.t() | nil,
          sequence: non_neg_integer() | nil,
          occurred_at: binary() | nil,
          body: %{optional(binary()) => term()}
        }
end
