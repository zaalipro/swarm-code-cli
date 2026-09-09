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

  def stream(%Request{provider: p} = request, on_event) do
    on_event = on_event || fn _ -> :ok end

    case provider_module(p.kind) do
      nil -> {:error, "unknown provider kind: " <> p.kind}
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
  """
  @spec stream_once(Request.t(), (term() -> any()) | nil) :: {:ok, term()} | {:error, String.t()}
  def stream_once(%Request{} = request, on_event) do
    Process.put(SwarmCode.Domain.LLM.HTTP.no_retry_key(), true)
    stream(request, on_event)
  after
    Process.delete(SwarmCode.Domain.LLM.HTTP.no_retry_key())
  end

  def list_models(%Provider{kind: kind} = provider) do
    case provider_module(kind) do
      nil -> {:error, "unknown provider kind: " <> kind}
      mod -> mod.list_models(provider)
    end
  end
end
