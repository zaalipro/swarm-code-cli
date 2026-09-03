defmodule SwarmCodeCLI.UI.DataSource.Request do
  @moduledoc "A bounded, typed, generation-correlated DataSource request shell."

  alias SwarmCodeCLI.UI.{Intent, RequestResolver}
  alias SwarmCodeCLI.UI.RequestResolver.Context

  @enforce_keys [
    :request_id,
    :kind,
    :scope,
    :generation,
    :origin,
    :deadline,
    :expected_response
  ]
  defstruct @enforce_keys

  @type expected_response :: :outcome
  @type kind :: Intent.t()

  @type t :: %__MODULE__{
          request_id: binary(),
          kind: kind(),
          scope: SwarmCode.Protocol.Scope.t(),
          generation: non_neg_integer(),
          origin: RequestResolver.Context.origin(),
          deadline: non_neg_integer(),
          expected_response: expected_response()
        }

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_request}
  def validate(
        %__MODULE__{
          request_id: request_id,
          kind: kind,
          scope: scope,
          generation: generation,
          origin: origin,
          deadline: deadline,
          expected_response: expected_response
        } = request
      ) do
    valid? =
      map_size(request) == 8 and Intent.valid_id?(request_id) and Intent.valid?(kind) and
        Context.valid_scope?(scope) and is_integer(generation) and generation >= 0 and
        generation == scope.generation and Context.valid_origin?(origin) and
        is_integer(deadline) and deadline >= 0 and expected_response == :outcome

    if valid?, do: {:ok, request}, else: {:error, :invalid_request}
  end

  def validate(_request), do: {:error, :invalid_request}

  @spec validate!(term()) :: t()
  def validate!(request) do
    case validate(request) do
      {:ok, valid} -> valid
      {:error, :invalid_request} -> raise ArgumentError, "invalid data source request"
    end
  end
end
