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
        correlated_kind_origin?(kind, origin) and
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

  defp correlated_kind_origin?(
         {:dispatch, _operation, _text, _target, _attachments},
         {:draft, _key}
       ),
       do: true

  defp correlated_kind_origin?({:steer, _run_id, _node_id, _text, _attachments}, {:draft, _key}),
    do: true

  defp correlated_kind_origin?({:run_control, _operation, run_id}, {:run, run_id}), do: true

  defp correlated_kind_origin?(
         {:retry_run, run_id, revision},
         {:run_revision, run_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:stop_agent, run_id, agent_id, revision},
         {:agent, run_id, agent_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:answer_question, _run_id, _node_id, interaction_id, revision, _option_ids},
         {:interaction, interaction_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:resolve_approval, _run_id, _node_id, interaction_id, revision, _decision},
         {:interaction, interaction_id, revision}
       ),
       do: true

  defp correlated_kind_origin?(
         {:mark_seen, kind, id, revision},
         {:seen, kind, id, revision}
       ),
       do: true

  defp correlated_kind_origin?(_kind, _origin), do: false
end
