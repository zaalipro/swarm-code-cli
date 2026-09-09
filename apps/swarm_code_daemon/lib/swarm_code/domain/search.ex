defmodule SwarmCode.Domain.Search do
  @moduledoc """
  Web search and page reading, over whatever the user configured (spec 24 §4.3).

  `search/2` walks the enabled engines in their configured order and returns the
  first one that answers with results; an error or an empty list moves on. The
  legacy `settings.tavily_api_key` is adopted into the Tavily row once at boot
  (`adopt_legacy_key/0`, spec 39 §1.4) and never read at search time.
  """
  import Ecto.Query, warn: false, except: [update: 2, update: 3]

  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Search.SearchProvider
  alias SwarmCode.Domain.Settings

  require Logger

  @engines %{
    "tavily" => SwarmCode.Domain.Search.Tavily,
    "exa" => SwarmCode.Domain.Search.Exa,
    "brave" => SwarmCode.Domain.Search.Brave,
    "serper" => SwarmCode.Domain.Search.Serper
  }

  @readers %{
    "jina" => SwarmCode.Domain.Search.Jina,
    "firecrawl" => SwarmCode.Domain.Search.Firecrawl
  }

  @doc "Kinds that search, in the order the settings page lists them."
  def engine_kinds, do: ~w(tavily exa brave serper)

  @doc "Kinds that turn a URL into text."
  def reader_kinds, do: ~w(jina firecrawl)

  @doc "The module behind a kind, or nil."
  def module(kind), do: Map.get(@engines, kind) || Map.get(@readers, kind)

  @doc "A human name for a kind."
  def label("tavily"), do: "Tavily"
  def label("exa"), do: "Exa"
  def label("brave"), do: "Brave"
  def label("serper"), do: "Serper (Google)"
  def label("firecrawl"), do: "Firecrawl"
  def label("jina"), do: "Jina Reader"
  def label(kind), do: to_string(kind)

  @doc "One line of help per kind, shown under its row."
  def hint("tavily"), do: "Agent-oriented search with page snippets."
  def hint("exa"), do: "Neural/semantic search built for agents."
  def hint("brave"), do: "An independent index with a cheap tier."
  def hint("serper"), do: "Real Google results as JSON."
  def hint("firecrawl"), do: "Reader: a URL as clean markdown."
  def hint("jina"), do: "Reader: works with no API key at all."
  def hint(_kind), do: ""

  # ------------------------------------------------------------------ rows

  @doc "Every configured row, ordered as the user arranged them."
  @spec list() :: [SearchProvider.t()]
  def list, do: Repo.all(from(p in SearchProvider, order_by: [asc: p.position, asc: p.kind]))

  @doc """
  One row per known kind, creating the missing ones as disabled placeholders so
  the settings page always has something to render.
  """
  @spec all() :: [SearchProvider.t()]
  def all do
    existing = Map.new(list(), &{&1.kind, &1})
    kinds = engine_kinds() ++ reader_kinds()

    kinds
    |> Enum.with_index()
    |> Enum.map(fn {kind, index} ->
      Map.get_lazy(existing, kind, fn ->
        {:ok, row} = upsert(kind, %{position: index})
        row
      end)
    end)
    |> Enum.sort_by(&{&1.position, Enum.find_index(kinds, fn k -> k == &1.kind end) || 99})
  end

  @spec get(String.t()) :: SearchProvider.t() | nil
  def get(kind), do: Repo.one(from(p in SearchProvider, where: p.kind == ^kind))

  @doc "Creates or updates the row for a kind."
  @spec upsert(String.t(), map()) :: {:ok, SearchProvider.t()} | {:error, Ecto.Changeset.t()}
  def upsert(kind, attrs) do
    row = get(kind) || %SearchProvider{}

    result =
      row
      |> SearchProvider.changeset(Map.merge(normalize(attrs), %{"kind" => kind}))
      |> Repo.insert_or_update()

    with {:ok, provider} <- result do
      SwarmCode.Domain.PubSub.broadcast(
        SwarmCode.Domain.PubSub,
        "search_providers",
        {:search_providers_updated}
      )

      {:ok, provider}
    end
  end

  @doc "Moves a row up or down in the fallback order."
  @spec move(String.t(), -1 | 1) :: :ok
  def move(kind, direction) do
    rows = all()

    case Enum.find_index(rows, &(&1.kind == kind)) do
      nil ->
        :ok

      index ->
        target = index + direction

        if target >= 0 and target < length(rows) do
          rows
          |> List.replace_at(index, Enum.at(rows, target))
          |> List.replace_at(target, Enum.at(rows, index))
          |> Enum.with_index()
          |> Enum.each(fn {row, position} -> upsert(row.kind, %{position: position}) end)
        end

        :ok
    end
  end

  defp normalize(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  def subscribe,
    do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "search_providers")

  # ------------------------------------------------------------------ search

  @doc "True when at least one engine can answer a query."
  @spec configured?() :: boolean()
  def configured?, do: engines() != []

  @doc """
  Runs `query` through the configured engines until one answers.

  `opts`: `:max_results`, `:recency_days`, `:include_domains`,
  `:exclude_domains`, `:timeout`, and `:research` — only a research search
  takes the recency and domain settings as defaults (spec 39 §1.4).
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def search(query, opts \\ []) do
    case engines() do
      [] ->
        {:error,
         "web_search is not configured: enable a search provider in Settings → Deep research"}

      configs ->
        try_each(configs, query, with_defaults(opts), nil)
    end
  end

  defp try_each([], _query, _opts, last),
    do: {:error, last || "no search provider returned anything"}

  defp try_each([cfg | rest], query, opts, last) do
    case cfg.module.search(cfg, query, opts) do
      {:ok, [_ | _] = results} ->
        {:ok, results}

      {:ok, []} ->
        try_each(rest, query, opts, last || "#{label(cfg.kind)} found nothing")

      {:error, reason} ->
        if rest != [], do: Logger.info("swarm_code search fell back past #{cfg.kind}: #{reason}")
        try_each(rest, query, opts, reason)
    end
  end

  @doc """
  A URL as text, through the configured reader; falls back to `{:error, …}` so
  `web_fetch` can use its own plain fetch instead.
  """
  @spec read(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def read(url, opts \\ []) do
    settings = settings()

    case reader(settings) do
      nil -> {:error, "no reader configured"}
      cfg -> cfg.module.read(cfg, url, with_defaults(opts, settings))
    end
  end

  @doc """
  One canned query against a single kind, for the Settings Test button.

  Spec 39 §2.7: `overrides` (`:api_key`, `:base_url`) are what the user has
  typed and not yet saved — non-blank values win over the row's — and both
  calls carry a 15 s timeout so a dead endpoint cannot hold the page.
  """
  @spec test(String.t(), map()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, String.t()}
  def test(kind, overrides \\ %{}) do
    row = get(kind) || %SearchProvider{kind: kind, api_key: ""}
    typed = typed(overrides)
    typed_key = Map.get(typed, :api_key) || row.api_key
    cfg = config(struct(row, typed))
    started = System.monotonic_time(:millisecond)

    outcome =
      cond do
        is_nil(cfg) ->
          {:error, "#{label(kind)} has no module"}

        kind in reader_kinds() ->
          cfg.module.read(cfg, "https://example.com", timeout: 15_000)

        true ->
          cfg.module.search(cfg, "swarmcode deep research test",
            max_results: 3,
            timeout: 15_000
          )
      end

    ms = System.monotonic_time(:millisecond) - started

    case outcome do
      {:ok, results} when is_list(results) -> {:ok, length(results), ms}
      {:ok, text} when is_binary(text) -> {:ok, 1, ms}
      # spec 60 T13: the typed key never comes back out in the Settings flash.
      {:error, reason} -> {:error, SwarmCode.Domain.LLM.HTTP.redact(reason, [typed_key || ""])}
    end
  end

  defp typed(overrides) do
    for {key, value} <- overrides,
        key in [:api_key, :base_url],
        is_binary(value) and String.trim(value) != "",
        into: %{},
        do: {key, String.trim(value)}
  end

  # ------------------------------------------------------------------ config

  # Enabled engines in order. Spec 39 §1.4 (F6): no legacy fallback — an
  # unticked Tavily row means Tavily is off.
  defp engines do
    for row <- list(), row.enabled, row.kind in engine_kinds(), cfg = config(row), do: cfg
  end

  @doc """
  Spec 39 §1.4: the legacy `settings.tavily_api_key` becomes the Tavily row's
  key, once. Idempotent; a row that already has a key is left alone.
  """
  @spec adopt_legacy_key() :: :ok
  def adopt_legacy_key do
    key = settings().tavily_api_key

    if is_binary(key) and String.trim(key) != "" do
      row = get("tavily") || %SearchProvider{kind: "tavily", api_key: ""}

      if String.trim(row.api_key || "") == "",
        do: {:ok, _} = upsert("tavily", %{api_key: key, enabled: row.enabled or row.id == nil})

      {:ok, _} = Settings.update(%{tavily_api_key: nil})
    end

    :ok
  end

  defp reader(settings) do
    case settings.research_reader do
      kind when kind in ["jina", "firecrawl"] ->
        row = get(kind) || %SearchProvider{kind: kind, api_key: ""}
        if kind == "jina" or String.trim(row.api_key || "") != "", do: config(row)

      _other ->
        nil
    end
  end

  defp config(%SearchProvider{} = row) do
    case module(row.kind) do
      nil -> nil
      mod -> %{kind: row.kind, api_key: row.api_key, base_url: row.base_url, module: mod}
    end
  end

  # Spec 39 §1.4: the recency and domain settings are *research* settings —
  # a chat turn's web_search gets the open web unless the caller says otherwise.
  defp with_defaults(opts, settings \\ nil) do
    s = settings || settings()
    research? = Keyword.get(opts, :research, false)

    [
      max_results: opts[:max_results] || 5,
      recency_days: Keyword.get(opts, :recency_days, if(research?, do: s.research_recency_days)),
      include_domains:
        opts[:include_domains] || if(research?, do: s.research_include_domains || [], else: []),
      exclude_domains:
        opts[:exclude_domains] || if(research?, do: s.research_exclude_domains || [], else: []),
      timeout: opts[:timeout] || 120_000
    ]
  end

  defp settings, do: Settings.get()
end
