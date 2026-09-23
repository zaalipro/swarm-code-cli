defmodule SwarmCode.Domain.LLM do
  @moduledoc """
  Provider-neutral facade for streaming LLM calls.

  Transport failures are retried inside `SwarmCode.Domain.LLM.HTTP` (spec 11 §7.3);
  every retry is announced to the caller's `on_event` as
  `{:retry, attempt, of, reason}` so the op node can show `retrying 2/5 ·
  network`, and a retry that follows a half-streamed answer first emits
  `{:text_reset}` so the UI drops the partial text.
  """

  alias SwarmCode.Domain.LLM.Request
  alias SwarmCode.Domain.Providers.Provider

  def provider_module(kind) when is_binary(kind) do
    Application.get_env(:swarm_code_daemon, :llm_providers, %{})[kind]
  end

  def provider_module(_), do: nil

  @doc """
  Streams `request`.

  spec 67 T30 (G42): a failure is `{:error, kind, message}` from the two real
  providers — `kind` is one of `SwarmCode.Domain.LLM.Error.kinds/0` — and stays
  `{:error, message}` from anything that only produces text (`LLM.Fake`, an
  unknown provider kind). Every caller has to take both; `LLM.Error.of/1` and
  `LLM.Error.message/1` read either.
  """
  @spec stream(Request.t(), (term() -> any()) | nil) ::
          {:ok, term()} | {:error, atom(), String.t()} | {:error, String.t()}
  def stream(%Request{provider: p} = request, on_event) do
    on_event = on_event || fn _ -> :ok end

    case provider_module(p.kind) do
      nil -> {:error, :provider, "unknown provider kind: " <> p.kind}
      mod -> mod.stream(request, on_event)
    end
  end

  @doc """
  The `on_retry` callback the HTTP layer calls before it sleeps: it turns a
  retry into the two events every caller already understands.
  """
  @spec on_retry((term() -> any())) :: (pos_integer(), pos_integer(), String.t(), boolean() ->
                                          any())
  def on_retry(on_event) do
    on_event = on_event || fn _ -> :ok end

    fn attempt, of, reason, mid_stream? ->
      if mid_stream? do
        on_event.({:text_reset})
        on_event.({:reasoning_reset})
      end

      on_event.({:retry, attempt, of, reason})
    end
  end

  @doc """
  One attempt, no transport retries — the watchdog probe (spec 11 §7.4) must
  fail fast instead of sitting in a three-minute backoff.

  spec 67 T30: this one is deliberately 2-tuple only. Its caller
  (`Workflows.Runner.Watchdog`) matches `{:error, message}` and has no use for
  the kind.
  """
  @spec stream_once(Request.t(), (term() -> any()) | nil) :: {:ok, term()} | {:error, String.t()}
  def stream_once(%Request{} = request, on_event) do
    Process.put(SwarmCode.Domain.LLM.HTTP.no_retry_key(), true)

    case stream(request, on_event) do
      {:error, kind, message} when is_atom(kind) -> {:error, message}
      other -> other
    end
  after
    Process.delete(SwarmCode.Domain.LLM.HTTP.no_retry_key())
  end

  @doc """
  The last rate-limit snapshot this provider's responses carried (spec 67 T33):
  `%{used_percent: float, resets_at: DateTime.t() | nil, scope: String.t()}`,
  or `nil` when no response has named one yet.
  """
  @spec rate_limit(String.t() | nil) :: map() | nil
  def rate_limit(nil), do: nil
  def rate_limit(provider_id), do: SwarmCode.Domain.Cache.get({:rate_limit, provider_id})

  def list_models(%Provider{kind: kind} = provider) do
    case provider_module(kind) do
      nil -> {:error, "unknown provider kind: " <> kind}
      mod -> mod.list_models(provider)
    end
  end

  # spec 66 T14: the four shapes "this prompt does not fit" takes on the two
  # APIs SwarmCode speaks — Anthropic's `prompt is too long: N tokens > M
  # maximum` and `input length and max_tokens exceed context limit`, OpenAI's
  # `context_length_exceeded` code and its `maximum context length is N tokens`
  # sentence. Gateways pass the provider's own text through, so the phrase is a
  # more reliable signal than the status code.
  @context_overflow [
    "prompt is too long",
    "context_length_exceeded",
    "context length exceeded",
    "maximum context length",
    "exceed context limit",
    "exceeds the context limit"
  ]

  @doc """
  True when a failed call failed because the request did not fit the model's
  context window (spec 66 T14).

  The classification lives here rather than inside each provider because
  `Engine.Operation` stringifies whatever a provider returns before the agent
  ever sees it, so an `{:error, {:context_overflow, …}}` tuple could not survive
  the trip; the message text does.
  """
  @spec context_overflow?(term()) :: boolean()
  def context_overflow?(message) do
    text = message |> to_string() |> String.downcase()
    Enum.any?(@context_overflow, &String.contains?(text, &1))
  end
end
