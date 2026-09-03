defmodule SwarmCodeCLI.UI.DataSource.AdmissionError do
  @moduledoc "A closed admission failure with content-independent diagnostic text."

  @enforce_keys [:code, :message]
  defstruct @enforce_keys

  @codes [
    :not_bound,
    :closed,
    :invalid_watch,
    :invalid_request,
    :duplicate_watch,
    :request_conflict,
    :capacity_exceeded,
    :deadline_expired,
    :source_unavailable,
    :not_allowed,
    :stale_revision,
    :invalid_origin,
    :invalid_intent
  ]

  @type code ::
          :not_bound
          | :closed
          | :invalid_watch
          | :invalid_request
          | :duplicate_watch
          | :request_conflict
          | :capacity_exceeded
          | :deadline_expired
          | :source_unavailable
          | :not_allowed
          | :stale_revision
          | :invalid_origin
          | :invalid_intent

  @type t :: %__MODULE__{code: code(), message: binary()}

  @spec new(code()) :: t()
  def new(:not_bound), do: error(:not_bound, "data source owner is not bound")
  def new(:closed), do: error(:closed, "data source is closed")
  def new(:invalid_watch), do: error(:invalid_watch, "invalid data source watch")
  def new(:invalid_request), do: error(:invalid_request, "invalid data source request")
  def new(:duplicate_watch), do: error(:duplicate_watch, "watch reference is already admitted")

  def new(:request_conflict),
    do: error(:request_conflict, "request reference is already admitted")

  def new(:capacity_exceeded),
    do: error(:capacity_exceeded, "data source admission capacity exceeded")

  def new(:deadline_expired), do: error(:deadline_expired, "request deadline has expired")
  def new(:source_unavailable), do: error(:source_unavailable, "data source is unavailable")
  def new(:not_allowed), do: error(:not_allowed, "request is not allowed")
  def new(:stale_revision), do: error(:stale_revision, "request revision is stale")
  def new(:invalid_origin), do: error(:invalid_origin, "request origin is invalid")
  def new(:invalid_intent), do: error(:invalid_intent, "request intent is invalid")

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_admission_error}
  def validate(%__MODULE__{code: code} = admission_error) when code in @codes do
    if map_size(admission_error) == 3 and admission_error == new(code),
      do: {:ok, admission_error},
      else: {:error, :invalid_admission_error}
  end

  def validate(_admission_error), do: {:error, :invalid_admission_error}

  defp error(code, message), do: %__MODULE__{code: code, message: message}
end
