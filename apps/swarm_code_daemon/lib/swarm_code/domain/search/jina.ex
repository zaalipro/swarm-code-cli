defmodule SwarmCode.Domain.Search.Jina do
  @moduledoc """
  Jina Reader — `r.jina.ai/<url>` returns a page as markdown (spec 24 §4.2).

  The only provider that works with no key at all, which makes it the sensible
  default reader for a fresh install.
  """
  @behaviour SwarmCode.Domain.Search.Provider

  alias SwarmCode.Domain.Search.{Body, Provider}

  @name "Jina"
  @default "https://r.jina.ai"

  def default_base_url, do: Application.get_env(:swarm_code_daemon, :jina_base_url, @default)

  @impl true
  def read(cfg, url, opts) do
    key = String.trim(cfg[:api_key] || "")

    headers =
      [{"accept", "text/plain"}] ++
        if key == "", do: [], else: [{"authorization", "Bearer " <> key}]

    # Spec 51 §7.4 (M7): the reader is handed the same bounded collector as
    # `web_fetch` — a 300 MB asset behind a URL is 4 MB here — and Req's
    # safe-GET retry, so one stale pooled connection is not a failed op.
    # spec 60 T10: no credentialed redirect across origins.
    result =
      Req.get(
        SwarmCode.Domain.LLM.HTTP.request((cfg[:base_url] || default_base_url()) <> "/" <> url),
        headers: headers,
        retry: :safe_transient,
        max_retries: 1,
        receive_timeout: opts[:timeout] || 120_000,
        into: Body.collector()
      )

    case result do
      {:ok, %{status: 200} = response} ->
        case Body.read(response) do
          {:ok, body} when body != "" -> {:ok, body}
          {:ok, _empty} -> {:error, "#{@name} returned nothing for #{url}"}
          {:skip, :type, ct} -> {:error, "#{@name} returned #{ct} for #{url}"}
          {:skip, :length, _ct} -> {:error, "#{@name} returned more than 4 MB for #{url}"}
        end

      {:ok, response} ->
        Provider.error(@name, response)

      {:error, reason} ->
        Provider.error(@name, reason)
    end
  end
end
