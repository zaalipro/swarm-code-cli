defmodule SwarmCodeCLI.UI.DataSource.Delivery do
  @moduledoc "The closed asynchronous delivery envelope; typed bodies are added with the DTO task."

  alias SwarmCodeCLI.UI.Intent
  alias SwarmCodeCLI.UI.RequestResolver.Context

  @enforce_keys [
    :kind,
    :watch_ref,
    :request_id,
    :scope,
    :generation,
    :revision,
    :sequence,
    :body
  ]
  defstruct @enforce_keys

  @type kind :: :watch_ready | :delta | :response | :resyncing | :error | :closed
  @type body :: nil

  @type t :: %__MODULE__{
          kind: kind(),
          watch_ref: binary() | nil,
          request_id: binary() | nil,
          scope: SwarmCode.Protocol.Scope.t() | nil,
          generation: non_neg_integer(),
          revision: non_neg_integer() | nil,
          sequence: non_neg_integer() | nil,
          body: body()
        }

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_delivery}
  def validate(
        %__MODULE__{
          kind: kind,
          watch_ref: watch_ref,
          request_id: request_id,
          scope: scope,
          generation: generation,
          revision: revision,
          sequence: sequence,
          body: body
        } = delivery
      ) do
    valid? =
      map_size(delivery) == 9 and
        kind in [:watch_ready, :delta, :response, :resyncing, :error, :closed] and
        optional_id?(watch_ref) and optional_id?(request_id) and
        optional_scope?(scope, generation) and
        is_integer(generation) and generation >= 0 and optional_non_negative_integer?(revision) and
        optional_non_negative_integer?(sequence) and is_nil(body)

    if valid?, do: {:ok, delivery}, else: {:error, :invalid_delivery}
  end

  def validate(_delivery), do: {:error, :invalid_delivery}

  @spec validate!(term()) :: t()
  def validate!(delivery) do
    case validate(delivery) do
      {:ok, valid} -> valid
      {:error, :invalid_delivery} -> raise ArgumentError, "invalid data source delivery"
    end
  end

  defp optional_id?(nil), do: true
  defp optional_id?(id), do: Intent.valid_id?(id)

  defp optional_scope?(nil, _generation), do: true

  defp optional_scope?(scope, generation),
    do: Context.valid_scope?(scope) and scope.generation == generation

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: is_integer(value) and value >= 0
end
