defmodule SwarmCode.Domain.Tools.WebSearch do
  @moduledoc "Search the web through whichever engines Settings has enabled (spec 24 §4.4)."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Search

  @impl true
  def name, do: "web_search"

  @impl true
  # Spec 54 §5 (54c H9): what a snippet is worth, and what it is not.
  def description,
    do:
      "Search the web and return the top results as title, URL and a short snippet. The " <>
        "snippets are the search engine's, not the pages themselves — they are enough to " <>
        "choose what to open and to back a minor fact, but a number, a date or a version " <>
        "worth reporting should come from web_fetch on the page. Several searches issued in " <>
        "one turn run in parallel."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search query"},
        "max_results" => %{"type" => "integer", "description" => "1-10 (default 5)"}
      },
      "required" => ["query"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "web search \"#{args["query"]}\""

  @impl true
  def run(args, ctx, progress) do
    if Search.configured?() do
      progress.(nil, "searching")

      # Spec 39 §1.4: only a research's searches take the research filters.
      case Search.search(args["query"],
             max_results: clamp(args["max_results"] || 5, 1, 10),
             timeout: SwarmCode.Domain.Tools.timeout(ctx),
             research: ctx[:run_kind] == "research"
           ) do
        {:ok, []} ->
          {:ok, "no results"}

        {:ok, results} ->
          progress.(100, "#{length(results)} results")

          {:ok,
           results
           |> Enum.with_index(1)
           |> Enum.map_join("\n\n", fn {r, i} ->
             "#{i}. #{r.title}\n   #{r.url}\n   #{String.slice(r.content, 0, 500)}"
           end)}

        {:error, msg} ->
          {:error, msg}
      end
    else
      {:error,
       "web_search is not configured: enable a search provider in Settings → Deep research"}
    end
  end

  defp clamp(value, min_v, max_v) when is_integer(value), do: value |> max(min_v) |> min(max_v)
  defp clamp(_value, min_v, _max_v), do: min_v
end
