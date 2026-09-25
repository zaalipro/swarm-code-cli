defmodule SwarmCodeCLI.UI.Settings.Sections.SearchWeb do
  @moduledoc """
  The Search & web section (spec §2.5, §2.23 *search_provider*, F7's first page): the six
  search providers — engines in fallback order (`J K` move with `search.move`, `Space`
  switches one on or off), then the readers — the page reader (`web.reader`, with AT15's
  note when Firecrawl has no key), the web_fetch facts and a link to the tool timeout.

  A provider's page: enabled, the key (paste; a replacement is tested first; `x` removes
  it), the base URL (blank = the kind's default, shown faint), `▸ Test search` (`t`).
  Enabling a key-needing engine without a key opens the paste first. Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @kind "search_provider"

  @reader_choices [
    %{value: "web_fetch", label: "Plain fetch (strip HTML)", hint: nil},
    %{value: "jina", label: "Jina Reader", hint: nil},
    %{value: "firecrawl", label: "Firecrawl", hint: nil}
  ]

  @kind_notes %{
    "tavily" => "search built for agents · 1 000 free searches a month",
    "exa" => "neural search",
    "brave" => "an independent index",
    "serper" => "Google results",
    "jina" => "reads pages without a key, rate limited",
    "firecrawl" => "reads pages · needs a key"
  }

  def id, do: :search_web

  def loads(ctx) do
    case R.page_record(ctx) do
      {@kind, kind} ->
        [{:records, "search_providers", %{}}, {:record, @kind, kind}, {:values, [:search_web]}]

      _ ->
        [{:records, "search_providers", %{}}, {:values, [:search_web]}]
    end
  end

  def title(ctx) do
    case R.page_record(ctx) do
      {@kind, kind} -> label(kind)
      _ -> "Search & web"
    end
  end

  def counts(ctx),
    do:
      %{records: nil}
      |> Map.put(:records, if(R.loaded?(ctx, "search_providers"), do: enabled_count(ctx)))

  def attention(_ctx), do: []

  defp enabled_count(ctx),
    do: Enum.count(R.items(ctx, "search_providers"), &(R.field(R.fields(&1), "enabled") == true))

  @doc "The label of a search kind."
  def label("tavily"), do: "Tavily"
  def label("exa"), do: "Exa"
  def label("brave"), do: "Brave"
  def label("serper"), do: "Serper"
  def label("jina"), do: "Jina Reader"
  def label("firecrawl"), do: "Firecrawl"
  def label(other), do: to_string(other)

  # ------------------------------------------------------------- the page

  def rows(ctx) do
    providers = Enum.map(R.items(ctx, "search_providers"), &R.fields/1)
    engines = Enum.filter(providers, &(R.field(&1, "role") == "engine"))
    readers = Enum.filter(providers, &(R.field(&1, "role") == "reader"))

    list =
      cond do
        not R.loaded?(ctx, "search_providers") -> [R.info("loading", "…", :text_faint)]
        true -> Enum.with_index(engines, 1) |> Enum.map(fn {f, n} -> engine_row(ctx, f, n) end)
      end

    none_on =
      if R.loaded?(ctx, "search_providers") and
           not Enum.any?(engines, &(R.field(&1, "enabled") == true)),
         do: [
           R.info("search:none", "Agents cannot search the web: no search engine is on", :warning)
         ],
         else: []

    [
      R.heading("search providers", "search providers", [
        {"tried in this order · J K move · Space on/off", :text_faint}
      ])
    ] ++
      list ++
      none_on ++
      [R.heading("readers", "readers", [{"read one page for web_fetch · no order", :text_faint}])] ++
      Enum.map(readers, &reader_row(ctx, &1)) ++
      [
        R.heading("reading pages", "reading pages", [
          {"every agent's web_fetch, not only research", :text_faint}
        ]),
        reader_setting_row(ctx, readers)
      ] ++
      [
        R.row(
          id: "key:web.fetch_facts",
          kind: :setting,
          key: "web.fetch_facts",
          label: "web_fetch",
          value: [
            {"private and localhost pages are fetched directly, never through a reader",
             :text_muted}
          ],
          lines: [[{"pages over 4 MB are refused · 20 000 characters by default", :text_muted}]],
          state: :readonly
        ),
        R.row(
          id: "link:tool_timeout",
          kind: :link,
          label: "Tool timeout",
          value: [{"bounds web_search, web_fetch and search calls", :text_faint}],
          tag: [{"→ Agents & limits", :text_faint}],
          keys: [{"Enter", :open_row, "open"}],
          target: {:link, :agents_limits, "limits.tool_timeout"}
        )
      ]
  end

  defp engine_row(ctx, f, n) do
    kind = R.field(f, "kind")
    on = R.field(f, "enabled") == true
    tick = if on, do: R.glyph(ctx, :ticked), else: R.glyph(ctx, :unticked)

    R.row(
      id: "rec:search_provider:#{kind}",
      kind: :record,
      label: label(kind),
      value: [{"#{n} #{tick} ", :text_muted}] ++ key_segments(ctx, f),
      tag: last_test_segments(ctx, f),
      columns: [
        {"#{n}", :text_faint, 3},
        {tick, :text_primary, 1},
        {label(kind), :text_primary, 1},
        {text(key_segments(ctx, f)), :text_muted, 2}
      ],
      keys: [
        {"Space", :toggle, if(on, do: "turn off", else: "turn on")},
        {"J", :move_down, "later"},
        {"K", :move_up, "earlier"},
        {"t", :test, "test search"},
        {"Enter", :open_row, "open"}
      ],
      target: {:provider, kind}
    )
  end

  defp reader_row(ctx, f) do
    kind = R.field(f, "kind")

    R.row(
      id: "rec:search_provider:#{kind}",
      kind: :record,
      label: label(kind),
      value: key_segments(ctx, f) ++ [{" · #{@kind_notes[kind]}", :text_faint}],
      tag: last_test_segments(ctx, f),
      keys: [{"t", :test, "test reading"}, {"Enter", :open_row, "open"}],
      target: {:provider, kind}
    )
  end

  defp key_segments(ctx, f) do
    key = R.field(f, "api_key")

    cond do
      R.field(key, "set") == true -> [{"key ", :text_faint}] ++ R.secret_words(key, R.tier(ctx))
      R.field(f, "needs_key") == false -> [{"no key · optional", :text_faint}]
      true -> [{"no key", :text_ghost}]
    end
  end

  defp last_test_segments(ctx, f) do
    test = R.field(f, "last_test")
    reader = R.field(f, "role") == "reader"

    case test && R.field(test, "state") do
      "done" ->
        [
          {R.glyph(ctx, :ok) <> " ", :success},
          {"#{if reader, do: "read", else: "searched"} #{R.hhmm(R.field(test, "at"))}",
           :text_muted}
        ]

      "failed" ->
        [
          {R.glyph(ctx, :error) <> " ", :error},
          {to_string(R.field(test, "message")), :text_muted}
        ]

      _ ->
        [{"never tested", :text_faint}]
    end
  end

  defp text(segments), do: Enum.map_join(segments, "", &elem(&1, 0))

  defp reader_setting_row(ctx, readers) do
    value = R.value_of(ctx, "web.reader", "web_fetch")
    firecrawl = Enum.find(readers, &(R.field(&1, "kind") == "firecrawl"))
    no_key = firecrawl && R.field(R.field(firecrawl, "api_key"), "set") != true

    choices =
      Enum.map(@reader_choices, fn c ->
        if c.value == "firecrawl" and no_key,
          do: %{c | label: c.label <> " — no key, falls back"},
          else: c
      end)

    note =
      if value == "firecrawl" and no_key,
        do: [
          [{"! Page reader is Firecrawl but it has no key · pages use the plain fetch", :warning}]
        ],
        else: []

    R.row(
      id: "key:web.reader",
      kind: :setting,
      key: "web.reader",
      label: "Page reader",
      value: [
        {Enum.find_value(choices, to_string(value), &(&1.value == value && &1.label)),
         :text_primary}
      ],
      tag: [{if(value == "web_fetch", do: "default", else: "global"), :text_muted}],
      lines: note,
      marks: if(note != [], do: [:attention], else: []),
      editor: {SwarmCodeCLI.UI.Settings.Editors.Enum, %{choices: choices, value: value}},
      keys: [{"←→", :step, "switch"}, {"Enter", :open_row, "choose"}],
      target: {:setting, "web.reader"}
    )
  end

  # ------------------------------------------------------------ the record

  def record_rows(ctx, @kind, kind) do
    case Enum.find(R.items(ctx, "search_providers"), &(R.record_id(&1) == kind)) do
      nil ->
        if R.loaded?(ctx, "search_providers"),
          do: [R.info("gone", "No such search provider.")],
          else: [R.info("loading", "…", :text_faint)]

      rec ->
        provider_rows(ctx, kind, R.fields(rec))
    end
  end

  def record_rows(_ctx, _kind, _id), do: []

  def sub_rows(_ctx, _sub), do: []

  defp provider_rows(ctx, kind, f) do
    engine = R.field(f, "role") == "engine"
    on = R.field(f, "enabled") == true
    key = R.field(f, "api_key")
    set = R.field(key, "set") == true
    task = R.task(ctx, "search.set_key", %{"kind" => kind})
    order = if engine, do: position_words(ctx, kind), else: "a reader: no order"

    key_lines =
      cond do
        R.running?(task) ->
          [[{R.glyph(ctx, :running) <> " checking the new key…", :info}]]

        task && R.field(elem(task, 1), "state") in ["failed", "timeout"] ->
          [
            [{to_string(R.field(elem(task, 1), "message")), :error}],
            [
              {"s", :key},
              {" save it anyway · ", :text_faint},
              {"Esc", :key},
              {" keep the old key", :text_faint}
            ]
          ]

        true ->
          []
      end

    [
      R.row(
        id: "info:search:head",
        kind: :info,
        label: label(kind),
        value: [
          {"#{if engine, do: "search engine", else: "page reader"} · #{order} · global",
           :text_faint}
        ],
        state: :readonly
      ),
      R.row(
        id: "fld:search_provider:#{kind}:enabled",
        kind: :field,
        key: "search_provider.enabled",
        label: "Enabled",
        value: [{if(on, do: "on", else: "off"), :text_primary}],
        lines:
          if(engine,
            do: [],
            else: [
              [
                {"the Page reader setting decides which reader is used; this switch is not read",
                 :text_faint}
              ]
            ]
          ),
        tag: [{"global", :text_muted}],
        keys: [{"Space", :toggle, "switch"}],
        target: {:enabled, kind, on}
      ),
      R.row(
        id: "fld:search_provider:#{kind}:api_key",
        kind: :field,
        key: "search_provider.api_key",
        label: "API key",
        value:
          if(set,
            do:
              R.secret_words(key, R.tier(ctx)) ++
                [{" · stored in SwarmCode's database", :text_faint}],
            else: [
              {if(R.field(f, "needs_key") == false, do: "not set · optional", else: "not set"),
               :text_ghost}
            ]
          ),
        tag: [{"global", :text_muted}],
        lines: key_lines,
        state: if(R.running?(task), do: :running, else: :normal),
        keys:
          [{"Enter", :open_row, if(set, do: "paste a new key", else: "paste the key")}] ++
            if(set, do: [{"x", :delete, "remove the key · asks first"}], else: []),
        target: {:key, kind, set},
        detail:
          R.detail(
            title: "API key · #{label(kind)}",
            scope: "global · shared with the desktop app",
            key_line: "search_provider.api_key · secret",
            description:
              "The key SwarmCode sends to #{label(kind)} with each search. It is never shown again, never written to a log, never in search results and never kept for undo.",
            facts: [
              {"stored", "stored in SwarmCode's database"},
              {"sent to", sent_to(kind)},
              {"shared", "with the desktop app"}
            ]
          )
      ),
      R.row(
        id: "fld:search_provider:#{kind}:base_url",
        kind: :field,
        key: "search_provider.base_url",
        label: "Base URL",
        value:
          case R.field(f, "base_url") do
            nil ->
              [
                {to_string(R.field(f, "default_base_url")), :text_faint},
                {" · the default", :text_faint}
              ]

            url ->
              [{url, :text_primary}]
          end,
        tag: [{"global", :text_muted}],
        lines: error_lines(ctx, "fld:search_provider:#{kind}:base_url"),
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Text,
           %{value: R.field(f, "base_url") || "", max: 2_048}},
        keys: [{"Enter", :open_row, "edit"}, {"r", :reset, "back to the default"}],
        target: {:base_url, kind, R.field(f, "base_url")}
      ),
      test_row(ctx, kind, engine)
    ]
  end

  defp sent_to("tavily"), do: "api.tavily.com · in the request body"
  defp sent_to("brave"), do: "api.search.brave.com · as the X-Subscription-Token header"
  defp sent_to("serper"), do: "google.serper.dev · as the X-API-KEY header"
  defp sent_to("exa"), do: "api.exa.ai · as the x-api-key header"
  defp sent_to(kind), do: "#{label(kind)} · as a Bearer token"

  defp position_words(ctx, kind) do
    engines =
      for rec <- R.items(ctx, "search_providers"),
          R.field(R.fields(rec), "role") == "engine",
          do: R.record_id(rec)

    n = Enum.find_index(engines, &(&1 == kind))
    if n, do: "tried #{ordinal(n + 1)}", else: "an engine"
  end

  defp ordinal(1), do: "first"
  defp ordinal(2), do: "second"
  defp ordinal(3), do: "third"
  defp ordinal(4), do: "fourth"
  defp ordinal(n), do: "#{n}th"

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  defp test_row(ctx, kind, engine) do
    task = R.task(ctx, "search.test", %{"kind" => kind})

    start =
      if engine,
        do: "searching · uses 1 search from your #{label(kind)} plan",
        else: "reading example.com"

    {value, tag} =
      if task do
        R.task_words(ctx, task, start, fn s ->
          if engine,
            do: "#{R.count(R.field(s, "count") || 0, "result")} · #{R.field(s, "ms") || 0} ms",
            else: "read #{R.field(s, "read") || "example.com"} · #{R.field(s, "ms") || 0} ms"
        end)
      else
        words =
          if engine,
            do:
              "searches “swarmcode deep research test” · uses 1 search from your #{label(kind)} plan",
            else: "reads example.com"

        {[{words, :text_faint}], [{"t", :key}]}
      end

    R.row(
      id: "act:search.test",
      kind: :action,
      label: if(engine, do: "▸ Test search", else: "▸ Test reading"),
      value: value,
      tag: tag,
      state: if(R.running?(task), do: :running, else: :normal),
      keys:
        [{"Enter", :open_row, "test"}, {"t", :test, "test"}] ++
          if(R.running?(task), do: [{"c", :cancel_task, "stop"}], else: []),
      target: {:test, kind}
    )
  end

  # ------------------------------------------------------------------ act

  def act(ctx, row, verb) do
    case {Map.get(row, :target), verb} do
      {{:provider, kind}, :open_row} ->
        [{:open, R.new_page(:search_web, {@kind, kind})}]

      {{:provider, kind}, :toggle} ->
        toggle_ops(ctx, kind)

      {{:enabled, kind, _}, v} when v in [:toggle, :open_row] ->
        toggle_ops(ctx, kind)

      {{:provider, kind}, :move_down} ->
        move_ops(ctx, kind, 1)

      {{:provider, kind}, :move_up} ->
        move_ops(ctx, kind, -1)

      {{:provider, kind}, :test} ->
        [{:task, "search.test", %{"kind" => kind}, %{}}]

      {{:test, kind}, v} when v in [:open_row, :test] ->
        [{:task, "search.test", %{"kind" => kind}, %{}}]

      {_, :test} ->
        page_kind_ops(ctx, &[{:task, "search.test", %{"kind" => &1}, %{}}])

      {{:key, kind, set?}, :open_row} ->
        [{:paste, key_target(ctx, kind, set?, [])}]

      {{:key, kind, true}, :delete} ->
        clear_key_ops(ctx, kind)

      {{:key, kind, _}, :alt} ->
        save_anyway_ops(ctx, kind)

      {{:base_url, kind, old}, :reset} when old != nil ->
        update_ops(ctx, kind, "base_url", nil, old)

      {{:link, section, _key}, :open_row} ->
        [{:section, section}]

      _ ->
        :default
    end
  end

  defp page_kind_ops(ctx, fun) do
    case R.page_record(ctx) do
      {@kind, kind} -> fun.(kind)
      _ -> :default
    end
  end

  defp provider(ctx, kind) do
    case Enum.find(R.items(ctx, "search_providers"), &(R.record_id(&1) == kind)) do
      nil -> nil
      rec -> R.fields(rec)
    end
  end

  defp toggle_ops(ctx, kind) do
    f = provider(ctx, kind) || %{}
    on = R.field(f, "enabled") == true
    needs = R.field(f, "needs_key") != false
    set = R.field(R.field(f, "api_key"), "set") == true

    if not on and needs and not set do
      [
        {:toast, "#{label(kind)} needs a key first · paste it and it turns on", :info},
        {:paste,
         ctx
         |> key_target(kind, false, [
           {:command, "search.update", %{"kind" => kind}, %{"enabled" => true},
            %{
              expected: %{"fields" => %{"enabled" => false}},
              write_key: {:record, @kind, kind, "enabled"},
              toast: "#{label(kind)} on"
            }}
         ])
         # cli74 F14: the paste shows on the engine's own table row.
         |> Map.put(:row_id, "rec:#{@kind}:#{kind}")}
      ]
    else
      update_ops(ctx, kind, "enabled", not on, on)
    end
  end

  defp update_ops(_ctx, kind, field, value, old) do
    toast =
      case {field, value} do
        {"enabled", true} -> "#{label(kind)} on"
        {"enabled", false} -> "#{label(kind)} off"
        {"base_url", nil} -> "#{label(kind)} base URL back to the default"
        {"base_url", url} -> "#{label(kind)} base URL → #{url}"
      end

    [
      {:command, "search.update", %{"kind" => kind}, %{field => value},
       %{
         expected: %{"fields" => %{field => old}},
         write_key: {:record, @kind, kind, field},
         undo:
           {:command, "search.update", %{"kind" => kind}, %{field => old},
            %{expected: %{"fields" => %{field => value}}}},
         toast: toast
       }}
    ]
  end

  defp move_ops(ctx, kind, dir) do
    records = R.items(ctx, "search_providers")
    # cli74 F13: the service compares the whole order it reads (readers too).
    order = Enum.map(records, &R.record_id/1)

    engines =
      for rec <- records, R.field(R.fields(rec), "role") == "engine", do: R.record_id(rec)

    if kind in engines do
      [
        {:command, "search.move", %{"kind" => kind}, %{"dir" => dir},
         %{
           expected: %{"order" => order},
           write_key: {:record, @kind, :order, :order},
           undo: {:command, "search.move", %{"kind" => kind}, %{"dir" => -dir}, %{}}
         }}
      ]
    else
      [{:toast, "readers have no order", :info}]
    end
  end

  defp key_target(ctx, kind, set?, then) do
    f = provider(ctx, kind) || %{}

    %{
      row_id: "fld:search_provider:#{kind}:api_key",
      action: "search.set_key",
      target: %{"kind" => kind},
      attributes: %{"test_first" => set?},
      slot: "api_key",
      label: "#{label(kind)} API key",
      set?: set?,
      kind: @kind,
      expected: %{"key" => R.field(f, "api_key")},
      then: then
    }
  end

  defp clear_key_ops(ctx, kind) do
    f = provider(ctx, kind) || %{}
    off = R.field(f, "enabled") == true and R.field(f, "needs_key") != false

    [
      {:confirm,
       R.confirm(
         id: "search.clear_key",
         title: "Remove #{label(kind)}'s API key?",
         lines:
           ["#{label(kind)} will answer nothing until you paste a new key"] ++
             if(off, do: ["It is turned off with it."], else: []),
         safe: "Keep it",
         danger: "Remove the key",
         letter: "R",
         opener: "fld:search_provider:#{kind}:api_key"
       ),
       then: [
         {:command, "search.clear_key", %{"kind" => kind}, %{},
          %{
            expected: %{"key" => R.field(f, "api_key")},
            write_key: {:secret, @kind, kind, "api_key"},
            undo: false,
            toast: "#{label(kind)} API key removed"
          }}
       ]}
    ]
  end

  defp save_anyway_ops(ctx, kind) do
    case R.task(ctx, "search.set_key", %{"kind" => kind}) do
      {_id, t} ->
        if R.field(t, "state") in ["failed", "timeout"] do
          f = provider(ctx, kind) || %{}

          [
            {:command, "search.set_key", %{"kind" => kind}, %{"test_first" => false},
             %{
               secrets_from: :paste,
               expected: %{"key" => R.field(f, "api_key")},
               toast: "#{label(kind)} API key saved"
             }}
          ]
        else
          :default
        end

      nil ->
        :default
    end
  end

  # --------------------------------------------------------------- commit

  def commit(ctx, row, value) do
    case Map.get(row, :target) do
      {:base_url, kind, old} ->
        url = value |> to_string() |> String.trim() |> String.trim_trailing("/")
        url = if url == "", do: nil, else: url

        cond do
          url == old ->
            []

          url != nil and
              not (String.starts_with?(url, "http://") or String.starts_with?(url, "https://")) ->
            [{:row_error, row.id, "must start with http:// or https://"}]

          true ->
            update_ops(ctx, kind, "base_url", url, old)
        end

      _ ->
        :default
    end
  end
end
