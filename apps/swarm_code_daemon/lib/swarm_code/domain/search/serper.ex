defmodule SwarmCode.Domain.Search.Serper do
  @moduledoc "Serper — Google SERP as JSON (spec 24 §4.2)."
  @behaviour SwarmCode.Domain.Search.Provider

  alias SwarmCode.Domain.Search.Provider

  @name "Serper"
  @default "https://google.serper.dev"

  def default_base_url, do: Application.get_env(:swarm_code_daemon, :serper_base_url, @default)

  @impl true
  def search(cfg, query, opts) do
    query = query <> sites(opts[:include_domains]) <> minus_sites(opts[:exclude_domains])

    body =
      %{"q" => query, "num" => opts[:max_results] || 5}
      |> put_tbs(opts[:recency_days])

    # spec 60 T10: no credentialed redirect across origins.
    result =
      Req.post(
        SwarmCode.Domain.LLM.HTTP.request((cfg[:base_url] || default_base_url()) <> "/search"),
        json: body,
        headers: [{"x-api-key", cfg[:api_key] || ""}, {"content-type", "application/json"}],
        retry: false,
        receive_timeout: opts[:timeout] || 120_000
      )

    case result do
      {:ok, %{status: 200, body: %{"organic" => results}}} when is_list(results) ->
        {:ok,
         Enum.map(results, fn r ->
           Provider.result(%{
             title: r["title"],
             url: r["link"],
             content: r["snippet"],
             score: nil,
             published: r["date"]
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

  # Google's own recency token.
  defp put_tbs(body, nil), do: body
  defp put_tbs(body, days) when days <= 1, do: Map.put(body, "tbs", "qdr:d")
  defp put_tbs(body, days) when days <= 7, do: Map.put(body, "tbs", "qdr:w")
  defp put_tbs(body, days) when days <= 31, do: Map.put(body, "tbs", "qdr:m")
  defp put_tbs(body, days) when days <= 366, do: Map.put(body, "tbs", "qdr:y")
  defp put_tbs(body, _days), do: body
end
