defmodule SwarmCode.Settings.Registry.Web do
  @moduledoc false
  # §2.5 Search & web: the page reader and the web_fetch facts. The search
  # providers themselves are records (§2.23 search_provider).
  import SwarmCode.Settings.Registry.Build

  @entries [
    global("web.reader", :search_web, "Page reader for web_fetch",
      description:
        "Every agent's web_fetch, not only research. An unconfigured reader falls back to the plain fetch.",
      storage: {:setting, :research_reader},
      type: :enum,
      choices:
        choices([
          {"web_fetch", "Plain fetch (strip HTML)"},
          {"jina", "Jina Reader"},
          {"firecrawl", "Firecrawl"}
        ]),
      default: "web_fetch",
      applies: :next_request,
      shared: true,
      synonyms: ["reader", "page reader"],
      parity: "D§2b"
    ),
    fact("web.fetch_facts", :search_web, "web_fetch facts", :web_fetch,
      description:
        "Private and localhost pages are fetched directly, never through a reader · pages over 4 MB are refused · 20 000 characters by default.",
      parity: "I§3"
    )
  ]

  def entries, do: @entries
end
