defmodule SwarmCode.Domain.Search.Tavily do
  @moduledoc "Tavily Search (spec 24 §4.2)."
  @behaviour SwarmCode.Domain.Search.Provider

  alias SwarmCode.Domain.Search.Provider

  @name "Tavily"

  def default_base_url,
    do: Application.get_env(:swarm_code_daemon, :tavily_base_url, "https://api.tavily.com")

  @impl true
  def search(cfg, query, opts) do
    body =
      %{
        "query" => query,
        "max_results" => opts[:max_results] || 5,
        "search_depth" => "basic",
        "include_answer" => false
      }
      |> put_if(opts[:recency_days], "days")
      |> put_list(opts[:include_domains], "include_domains")
      |> put_list(opts[:exclude_domains], "exclude_domains")

    # spec 60 T10: no credentialed redirect across origins.
    result =
      Req.post(
        SwarmCode.Domain.LLM.HTTP.request((cfg[:base_url] || default_base_url()) <> "/search"),
        json: body,
        headers: [{"authorization", "Bearer " <> (cfg[:api_key] || "")}],
        retry: false,
        receive_timeout: opts[:timeout] || 120_000
      )

    case result do
      {:ok, %{status: 200, body: %{"results" => results}}} when is_list(results) ->
        {:ok,
         Enum.map(results, fn r ->
           Provider.result(%{
             title: r["title"],
             url: r["url"],
             content: r["content"],
             score: r["score"],
             published: r["published_date"]
           })
         end)}

      {:ok, %{status: 200}} ->
        {:ok, []}

      {:ok, response} ->
        Provider.error(@name, response)

      {:error, reason} ->
        Provider.error(@name, reason)
    end
  end

  defp put_if(body, nil, _key), do: body
  defp put_if(body, value, key), do: Map.put(body, key, value)

  defp put_list(body, nil, _key), do: body
  defp put_list(body, [], _key), do: body
  defp put_list(body, list, key), do: Map.put(body, key, list)
end
