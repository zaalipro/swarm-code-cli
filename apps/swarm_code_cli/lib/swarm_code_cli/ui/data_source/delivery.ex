defmodule SwarmCodeCLI.UI.DataSource.Delivery do
  @moduledoc "The closed asynchronous delivery envelope with validated presentation bodies."

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
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delta, AdmissionError}

  @type body ::
          DTO.ShellSnapshot.t()
          | DTO.WorkspaceSnapshot.t()
          | DTO.TranscriptWindow.t()
          | DTO.DetailWindow.t()
          | DTO.RunDetailSnapshot.t()
          | DTO.ActivitySnapshot.t()
          | DTO.PendingInteractionWindow.t()
          | DTO.PendingInteraction.t()
          | DTO.LibrarySnapshot.t()
          | DTO.ConversationList.t()
          | DTO.AgentDetail.t()
          | DTO.Outcome.t()
          | DTO.Connection.t()
          | Delta.t()
          | AdmissionError.t()
          | nil

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
      map_size(delivery) == 9 and is_integer(generation) and generation >= 0 and
        Context.valid_scope?(scope) and scope.generation == generation and valid_body?(kind, body) and
        correlated_body?(delivery) and
        correlated_kind?(
          kind,
          watch_ref,
          request_id,
          revision,
          sequence
        )

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

  defp correlated_body?(%{kind: :response, request_id: id, body: %{request_id: body_id}}),
    do: id == body_id

  defp correlated_body?(%{kind: :response, request_id: id, body: {:settings_failed, body_id, _}}),
    do: id == body_id

  defp correlated_body?(%{
         kind: :delta,
         revision: revision,
         sequence: sequence,
         body: %Delta{revision: body_revision, sequence: body_sequence}
       }),
       do: revision == body_revision and sequence == body_sequence

  defp correlated_body?(_), do: true

  defp valid_body?(kind, nil) when kind in [:resyncing, :closed], do: true
  defp valid_body?(:error, body), do: match?({:ok, _}, AdmissionError.validate(body))
  defp valid_body?(:delta, body), do: match?({:ok, _}, Delta.validate(body))

  defp valid_body?(kind, body) when kind in [:resyncing, :closed],
    do: match?({:ok, _}, DTO.Connection.validate(body))

  defp valid_body?(:watch_ready, body), do: page_body?(body)

  defp valid_body?(:response, body),
    do:
      match?({:ok, _}, DTO.DetailWindow.validate(body)) or page_body?(body) or
        match?({:ok, _}, DTO.LibrarySnapshot.validate(body)) or
        match?({:ok, _}, DTO.ConversationList.validate(body)) or
        match?({:ok, _}, DTO.AgentDetail.validate(body)) or
        match?({:ok, _}, DTO.Outcome.validate(body)) or
        match?({:ok, _}, DTO.PendingInteraction.validate(body)) or settings_body?(body)

  defp valid_body?(_, _), do: false

  # pass74 §3.4.6: a settings answer, or the typed failure of a settings request.
  defp settings_body?(%DTO.SettingsSnapshot{} = body),
    do: match?({:ok, _}, DTO.SettingsSnapshot.validate(body))

  defp settings_body?(%DTO.SettingsResult{} = body),
    do: match?({:ok, _}, DTO.SettingsResult.validate(body))

  defp settings_body?({:settings_failed, id, words}),
    do: Intent.valid_id?(id) and is_binary(words) and byte_size(words) <= 2_048

  defp settings_body?(_body), do: false

  defp page_body?(%module{} = body)
       when module in [
              DTO.ShellSnapshot,
              DTO.WorkspaceSnapshot,
              DTO.TranscriptWindow,
              DTO.RunDetailSnapshot,
              DTO.ActivitySnapshot,
              DTO.PendingInteractionWindow
            ],
       do: match?({:ok, _}, module.validate(body))

  defp page_body?(_), do: false

  defp correlated_kind?(:watch_ready, watch_ref, nil, revision, nil),
    do: Intent.valid_id?(watch_ref) and non_negative_integer?(revision)

  defp correlated_kind?(:delta, watch_ref, nil, revision, sequence),
    do:
      Intent.valid_id?(watch_ref) and non_negative_integer?(revision) and
        non_negative_integer?(sequence)

  defp correlated_kind?(kind, watch_ref, nil, nil, nil)
       when kind in [:resyncing, :error, :closed],
       do: Intent.valid_id?(watch_ref)

  defp correlated_kind?(:response, nil, request_id, nil, nil),
    do: Intent.valid_id?(request_id)

  defp correlated_kind?(_kind, _watch_ref, _request_id, _revision, _sequence), do: false

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
