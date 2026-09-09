defmodule SwarmCode.Domain.Search.Brave do
  @moduledoc "Brave Search (spec 24 §4.2)."
  @behaviour SwarmCode.Domain.Search.Provider

  alias SwarmCode.Domain.Search.Provider

  @name "Brave"
  @default "https://api.search.brave.com/res/v1"

  def default_base_url, do: Application.get_env(:swarm_code_daemon, :brave_base_url, @default)

  @impl true
  def search(cfg, query, opts) do
    # Brave has no domain filters; `site:` in the query is the documented way.
    query = query <> sites(opts[:include_domains]) <> minus_sites(opts[:exclude_domains])

    params =
      [q: query, count: opts[:max_results] || 5]
      |> put_freshness(opts[:recency_days])

    # spec 60 T10: no credentialed redirect across origins.
    result =
      Req.get(
        SwarmCode.Domain.LLM.HTTP.request(
          (cfg[:base_url] || default_base_url()) <> "/web/search"
        ),
        params: params,
        headers: [
          {"x-subscription-token", cfg[:api_key] || ""},
          {"accept", "application/json"}
        ],
        retry: false,
        receive_timeout: opts[:timeout] || 120_000
      )

    case result do
      {:ok, %{status: 200, body: %{"web" => %{"results" => results}}}} when is_list(results) ->
        {:ok,
         Enum.map(results, fn r ->
           Provider.result(%{
             title: r["title"],
             url: r["url"],
             content: r["description"],
             score: nil,
             published: r["age"]
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

  defp sites(nil), do: ""
  defp sites([]), do: ""
  defp sites(list), do: " (" <> Enum.map_join(list, " OR ", &("site:" <> &1)) <> ")"

  defp minus_sites(nil), do: ""
  defp minus_sites([]), do: ""
  defp minus_sites(list), do: " " <> Enum.map_join(list, " ", &("-site:" <> &1))

  # Brave takes a coarse bucket, not a day count.
  defp put_freshness(params, nil), do: params
  defp put_freshness(params, days) when days <= 1, do: Keyword.put(params, :freshness, "pd")
  defp put_freshness(params, days) when days <= 7, do: Keyword.put(params, :freshness, "pw")
  defp put_freshness(params, days) when days <= 31, do: Keyword.put(params, :freshness, "pm")
  defp put_freshness(params, days) when days <= 366, do: Keyword.put(params, :freshness, "py")
  defp put_freshness(params, _days), do: params
end
