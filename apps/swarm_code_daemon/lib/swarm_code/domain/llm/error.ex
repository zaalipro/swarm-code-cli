defmodule SwarmCode.Domain.LLM.Error do
  @moduledoc """
  What went wrong, as something upstream can branch on (spec 67 T30, G41–G42).

  Every LLM failure used to be a free string: `Operation` stringified it,
  `RunServer` wrote it into `nodes.error`, and the only consumer that ever
  needed to *decide* on one — the context-overflow retry — matched six English
  phrases. A kind is written beside the text now (`nodes.error_kind`,
  `runs.error_kind`), so the retry, the UI and any later policy read an atom.

  The kinds, in the order they are tried:

    * `:context_overflow` — the prompt does not fit the model's window
    * `:rate_limit`       — a 429 within a refilling window
    * `:usage_limit`      — a quota, a credit balance or a spend cap
    * `:overloaded`       — the provider's capacity, a 5xx, a 529
    * `:unauthorized`     — a 401/403, a bad or revoked key
    * `:refusal`          — the model declined the request
    * `:network`          — DNS, TCP, TLS, a dropped stream
    * `:timeout`          — the call's own deadline
    * `:provider`         — the provider rejected the request (a 400/404/422)
    * `:bug`              — SwarmCode's own crash

  `classify/3` is total: an unrecognised failure is `:provider`, which is the
  honest answer for "the provider said no and we do not know why".
  """

  @kinds ~w(context_overflow rate_limit usage_limit overloaded unauthorized refusal
            network timeout provider bug)a

  # spec 72 B2: orchestration stop reasons — not provider errors but reasons an
  # agent stopped that the UI and spawn_agent return text need to distinguish.
  @orchestration_stop_reasons ~w(done user_stopped parent_stopped
    turn_budget doom_loop spawn_timeout)a

  # spec 72 B3: human-readable labels for spawn_agent result text and the UI.
  # spec 72 B3 + F1: human-readable labels for stop reasons and provider error
  # kinds. The SwarmPane chip and spawn_agent return text both read from this
  # single map — no duplicated case statements.
  @stop_reason_labels %{
    "done" => nil,
    "user_stopped" => "stopped",
    "parent_stopped" => "parent stopped",
    "turn_budget" => "turn limit",
    "doom_loop" => "doom loop",
    "spawn_timeout" => "timed out",
    # Provider error kinds (for the UI chip):
    "timeout" => "timeout",
    "rate_limit" => "rate limit",
    "provider" => "provider error",
    "context_overflow" => "context full",
    "usage_limit" => "usage limit",
    "overloaded" => "overloaded",
    "network" => "network error",
    "bug" => "bug"
  }

  @type kind ::
          :context_overflow
          | :rate_limit
          | :usage_limit
          | :overloaded
          | :unauthorized
          | :refusal
          | :network
          | :timeout
          | :provider
          | :bug

  @doc "Every kind, in the order `classify/3` tries them."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "True when `value` is one of the kinds."
  @spec kind?(term()) :: boolean()
  def kind?(value), do: value in @kinds

  @doc "True when `value` is an orchestration stop reason."
  @spec stop_reason?(term()) :: boolean()
  def stop_reason?(value), do: value in @orchestration_stop_reasons

  @doc "True when `value` is any kind (provider error or stop reason)."
  @spec any_kind?(term()) :: boolean()
  def any_kind?(value), do: kind?(value) or stop_reason?(value)

  @doc "Human label for an orchestration stop reason; nil for :done and unknown kinds."
  @spec stop_reason_label(String.t() | atom() | nil) :: String.t() | nil
  def stop_reason_label(nil), do: nil
  def stop_reason_label(kind) when is_atom(kind), do: stop_reason_label(Atom.to_string(kind))
  def stop_reason_label(kind), do: Map.get(@stop_reason_labels, kind)

  @usage_phrases [
    "credit balance",
    "insufficient_quota",
    "insufficient quota",
    "quota exceeded",
    "usage limit",
    "spending limit",
    "billing",
    "payment required"
  ]

  @timeout_phrases ["gave up after", "timed out", "timeout", "deadline"]

  @network_phrases [
    "nxdomain",
    "econnrefused",
    "econnreset",
    "closed",
    "tls_alert",
    "socket",
    "network",
    "stream ended early",
    "request failed"
  ]

  @doc """
  The kind of a failure, from the HTTP status, the provider's own `error.type`
  (or the retry reason the transport used) and the message text.

  Any argument may be `nil`: the message alone is enough for the shapes that
  travel as text, which is every failure that reaches `RunServer`.
  """
  @spec classify(integer() | nil, String.t() | atom() | nil, term()) :: kind()
  def classify(status, error_type, message) do
    text = message |> to_string() |> String.downcase()
    type = error_type |> to_string() |> String.downcase()

    # spec 68 T15: bind by_type result once.
    type_kind = if(type != "", do: by_type(type))

    cond do
      SwarmCode.Domain.LLM.context_overflow?(text) -> :context_overflow
      type_kind != nil -> type_kind
      String.starts_with?(text, "crashed:") -> :bug
      any?(text, @usage_phrases) -> :usage_limit
      status && by_status(status, text) -> by_status(status, text)
      String.contains?(text, "declined this request") -> :refusal
      String.contains?(text, "rate limit") -> :rate_limit
      String.contains?(text, "overloaded") -> :overloaded
      String.contains?(text, "unauthorized") -> :unauthorized
      any?(text, @timeout_phrases) -> :timeout
      any?(text, @network_phrases) -> :network
      true -> :provider
    end
  end

  # Anthropic's `error.type` on an in-band event, and the reason string the
  # transport retry uses for the same failures ("network", "rate limit", …).
  defp by_type("rate_limit_error"), do: :rate_limit
  defp by_type("rate limit"), do: :rate_limit
  defp by_type("overloaded_error"), do: :overloaded
  defp by_type("api_error"), do: :overloaded
  defp by_type("server"), do: :overloaded
  defp by_type("authentication_error"), do: :unauthorized
  defp by_type("permission_error"), do: :unauthorized
  defp by_type("network"), do: :network
  defp by_type("deadline"), do: :timeout
  defp by_type("timeout"), do: :timeout
  defp by_type("billing_error"), do: :usage_limit
  defp by_type("refusal"), do: :refusal
  defp by_type("invalid_request_error"), do: :provider
  defp by_type("not_found_error"), do: :provider
  defp by_type(_other), do: nil

  defp by_status(status, _text) when status in [401, 403], do: :unauthorized
  defp by_status(429, _text), do: :rate_limit
  defp by_status(status, _text) when status in [408, 504], do: :timeout
  defp by_status(529, _text), do: :overloaded
  defp by_status(status, _text) when status >= 500, do: :overloaded
  defp by_status(status, _text) when status in [400, 404, 409, 413, 422], do: :provider
  defp by_status(_status, _text), do: nil

  defp any?(text, phrases), do: Enum.any?(phrases, &String.contains?(text, &1))

  @doc """
  The kind of whatever a provider (or a fake) returned, 2-tuple or 3-tuple.

  `{:error, kind, message}` keeps its kind; `{:error, message}` is classified
  from its text, which is the path `LLM.Fake` and every gateway that stringifies
  early take.
  """
  @spec of(term()) :: kind() | nil
  def of({:error, kind, _message}) when is_atom(kind), do: kind
  def of({:error, message}), do: classify(nil, nil, message)
  def of(_other), do: nil

  @doc "The message of a 2- or 3-tuple error."
  @spec message(term()) :: String.t()
  def message({:error, kind, message}) when is_atom(kind), do: to_string(message)
  def message({:error, message}), do: to_string(message)
  def message(other), do: to_string(inspect(other))
end
