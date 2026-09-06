defmodule SwarmCode.LLM do
  @moduledoc """
  Provider-neutral facade for streaming LLM calls.

  Transport failures are retried inside `SwarmCode.LLM.HTTP` (spec 11 §7.3);
  every retry is announced to the caller's `on_event` as
  `{:retry, attempt, of, reason}` so the op node can show `retrying 2/5 ·
  network`, and a retry that follows a half-streamed answer first emits
  `{:text_reset}` so the UI drops the partial text.
  """

  alias SwarmCode.LLM.Request
  alias SwarmCode.Providers.Provider

  def provider_module("openai"), do: SwarmCode.LLM.OpenAI
  def provider_module("anthropic"), do: SwarmCode.LLM.Anthropic
  def provider_module(_), do: nil

  def stream(%Request{provider: %Provider{} = p} = request, on_event) do
    on_event = on_event || fn _ -> :ok end
    model = request.model || p.default_model

    cond do
      is_nil(provider_module(p.kind)) ->
        {:error, "unknown provider kind"}

      not is_binary(model) or String.trim(model) == "" ->
        {:error, "a model must be configured"}

      not is_integer(request.deadline_ms) or request.deadline_ms <= 0 ->
        {:error, "deadline_ms must be positive"}

      true ->
        dispatch_stream(p.kind, %{request | model: model}, on_event)
    end
  end

  def stream(%Request{}, _on_event), do: {:error, "a provider must be configured"}

  defp dispatch_stream("openai", request, event), do: SwarmCode.LLM.OpenAI.stream(request, event)

  defp dispatch_stream("anthropic", request, event),
    do: SwarmCode.LLM.Anthropic.stream(request, event)

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
  """
  @spec stream_once(Request.t(), (term() -> any()) | nil) :: {:ok, term()} | {:error, String.t()}
  def stream_once(%Request{} = request, on_event) do
    Process.put(SwarmCode.LLM.HTTP.no_retry_key(), true)
    stream(request, on_event)
  after
    Process.delete(SwarmCode.LLM.HTTP.no_retry_key())
  end

  def list_models(%Provider{kind: "openai"} = p), do: SwarmCode.LLM.OpenAI.list_models(p)
  def list_models(%Provider{kind: "anthropic"} = p), do: SwarmCode.LLM.Anthropic.list_models(p)
  def list_models(%Provider{}), do: {:error, "unknown provider kind"}
end
