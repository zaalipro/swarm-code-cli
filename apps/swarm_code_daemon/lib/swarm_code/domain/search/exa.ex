defmodule SwarmCode.Domain.Search.Exa do
  @moduledoc "Exa neural search (spec 24 §4.2)."
  @behaviour SwarmCode.Domain.Search.Provider

  alias SwarmCode.Domain.Search.{Body, Provider}

  @name "Exa"
  @default "https://api.exa.ai"

  def default_base_url, do: Application.get_env(:swarm_code_daemon, :exa_base_url, @default)

  @impl true
  def search(cfg, query, opts) do
    body =
      %{
        "query" => query,
        "numResults" => opts[:max_results] || 5,
        "contents" => %{"text" => %{"maxCharacters" => 1200}}
      }
      |> put_since(opts[:recency_days])
      |> put_list(opts[:include_domains], "includeDomains")
      |> put_list(opts[:exclude_domains], "excludeDomains")

    # spec 60 T10: no credentialed redirect across origins.
    result =
      Req.post(
        SwarmCode.Domain.LLM.HTTP.request((cfg[:base_url] || default_base_url()) <> "/search"),
        json: body,
        headers: [{"x-api-key", cfg[:api_key] || ""}],
        retry: false,
        receive_timeout: opts[:timeout] || 120_000,
        # spec 73 T90: bounded while reading, like the readers.
        into: Body.collector()
      )

    case result do
      {:ok, %{status: 200} = response} ->
        case Provider.decode_json(response) do
          {:ok, %{"results" => results}} when is_list(results) ->
            {:ok,
             Enum.map(results, fn r ->
               Provider.result(%{
                 title: r["title"],
                 url: r["url"],
                 content: r["text"] || r["summary"],
                 score: r["score"],
                 published: r["publishedDate"]
               })
             end)}

          _other ->
            {:ok, []}
        end

      {:ok, response} ->
        Provider.error(@name, response)

      {:error, reason} ->
        Provider.error(@name, reason)
    end
  end

  defp put_since(body, nil), do: body

  defp put_since(body, days) do
    since = Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()
    Map.put(body, "startPublishedDate", since <> "T00:00:00.000Z")
  end

  defp put_list(body, nil, _key), do: body
  defp put_list(body, [], _key), do: body
  defp put_list(body, list, key), do: Map.put(body, key, list)
end
