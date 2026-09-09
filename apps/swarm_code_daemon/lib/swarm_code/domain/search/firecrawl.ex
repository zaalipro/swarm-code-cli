defmodule SwarmCode.Domain.Search.Firecrawl do
  @moduledoc "Firecrawl — a URL as clean markdown (spec 24 §4.2)."
  @behaviour SwarmCode.Domain.Search.Provider

  alias SwarmCode.Domain.Search.{Body, Provider}

  @name "Firecrawl"
  @default "https://api.firecrawl.dev/v1"

  def default_base_url, do: Application.get_env(:swarm_code_daemon, :firecrawl_base_url, @default)

  @impl true
  def read(cfg, url, opts) do
    # Spec 51 §7.4 (M7): the same bounded collector as Jina and `web_fetch`.
    # `:safe_transient` only retries GET and HEAD, and this is a POST — a scrape
    # is idempotent and costs one credit, so `:transient` (one extra attempt) is
    # the right trade for a connection the pool had already lost. A streamed
    # response is never decoded, so the JSON is decoded here.
    # spec 60 T10: no credentialed redirect across origins.
    result =
      Req.post(
        SwarmCode.Domain.LLM.HTTP.request((cfg[:base_url] || default_base_url()) <> "/scrape"),
        json: %{"url" => url, "formats" => ["markdown"], "onlyMainContent" => true},
        headers: [{"authorization", "Bearer " <> (cfg[:api_key] || "")}],
        retry: :transient,
        max_retries: 1,
        receive_timeout: opts[:timeout] || 120_000,
        into: Body.collector()
      )

    case result do
      {:ok, %{status: 200} = response} ->
        case markdown(response) do
          {:ok, markdown} -> {:ok, markdown}
          :error -> {:error, "#{@name} returned no markdown for #{url}"}
        end

      {:ok, response} ->
        Provider.error(@name, response)

      {:error, reason} ->
        Provider.error(@name, reason)
    end
  end

  defp markdown(response) do
    with {:ok, body} <- Body.read(response),
         {:ok, %{"data" => %{"markdown" => markdown}}} <- Jason.decode(body),
         true <- is_binary(markdown) and markdown != "" do
      {:ok, markdown}
    else
      _ -> :error
    end
  end
end
