defmodule SwarmCodeCLI.UI.Settings.Sections.Providers do
  @moduledoc """
  The Providers section (spec §2.3, §2.23 *provider*, §4.14; frames F5, F6, F12).

  * The list page: a table `name · kind · key · models · last test`, the environment row
    when onboarding variables are set, `▸ Add a provider…` (a preset picker, §2.3's list in
    its order) and `▸ Fetch every provider's models`.
  * The draft page (`record: {"provider", "draft"}`): every field editable, the key pasted
    into the draft, `Ctrl-S` creates it with the preset's effort levels and tests it.
  * The record page: fields that save one by one (CAS on what was read), the key paste
    target (a first key saves then tests; a replacement is tested first), test, fetch with
    the difference and its apply, *use for new chats*, forget caps, delete with a
    replacement for every default the provider serves.
  * Sub-pages: `:models` (the list, windowed and filtered by the layer) and `:delete` (the
    replacement pickers). The effort levels sub-page is `Settings.EffortLevels`.

  Pure: rows and ops only.
  """

  alias SwarmCodeCLI.UI.Settings.{EffortLevels, ModelPicker}
  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @kind "provider"
  @draft "draft"

  @presets [
    %{
      id: "anthropic",
      name: "Anthropic",
      kind: "anthropic",
      base_url: "https://api.anthropic.com",
      effort_preset: "anthropic_adaptive",
      key?: true
    },
    %{
      id: "openai",
      name: "OpenAI",
      kind: "openai_compatible",
      base_url: "https://api.openai.com/v1",
      effort_preset: "openai",
      key?: true
    },
    %{
      id: "openrouter",
      name: "OpenRouter",
      kind: "openai_compatible",
      base_url: "https://openrouter.ai/api/v1",
      effort_preset: "openrouter",
      key?: true
    },
    %{
      id: "deepseek",
      name: "DeepSeek",
      kind: "openai_compatible",
      base_url: "https://api.deepseek.com/v1",
      effort_preset: "deepseek",
      key?: true
    },
    %{
      id: "llmotions",
      name: "llmotions",
      kind: "openai_compatible",
      base_url: "https://cli.llmotions.com/v1",
      effort_preset: nil,
      key?: true
    },
    %{
      id: "ollama",
      name: "Ollama",
      kind: "openai_compatible",
      base_url: "http://localhost:11434/v1",
      effort_preset: nil,
      key?: false
    },
    %{
      id: "lmstudio",
      name: "LM Studio",
      kind: "openai_compatible",
      base_url: "http://localhost:1234/v1",
      effort_preset: nil,
      key?: false
    },
    %{
      id: "other",
      name: "",
      kind: "openai_compatible",
      base_url: "",
      effort_preset: nil,
      key?: true
    }
  ]

  @onboarding_env ~w(SWARM_BASE_URL SWARM_MODEL SWARM_API_KEY OPENAI_API_KEY OPENAI_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_BASE_URL)

  @doc "The section id."
  def id, do: :providers

  @doc "The presets of `a`, in §2.3's order."
  def presets, do: @presets

  # ------------------------------------------------------------------ loads

  def loads(ctx) do
    case {R.page_record(ctx), R.page_sub(ctx)} do
      {nil, _} ->
        [{:records, "providers", %{}}]

      {{@kind, @draft}, _} ->
        [{:records, "providers", %{}}, {:records, "effort_presets", %{}}]

      {{@kind, id}, _} ->
        [{:record, @kind, id}, {:records, "providers", %{}}, {:records, "model_options", %{}}]
    end
  end

  def title(ctx) do
    case R.page_record(ctx) do
      {@kind, @draft} -> "New provider · unsaved · Ctrl-S creates it · Esc discards"
      {@kind, id} -> provider_name(ctx, id) || "Providers"
      _ -> "Providers"
    end
  end

  def counts(ctx),
    do: %{records: if(R.loaded?(ctx, "providers"), do: length(R.items(ctx, "providers")))}

  def attention(_ctx), do: []

  # --------------------------------------------------------------- list page

  def rows(ctx) do
    providers = R.items(ctx, "providers")
    draft = R.draft(ctx, @kind)

    list =
      cond do
        not R.loaded?(ctx, "providers") ->
          [R.info("loading", "…", :text_faint)]

        providers == [] ->
          [
            R.info(
              "empty",
              "No provider yet. a adds one from a preset: Anthropic, OpenAI, OpenRouter, DeepSeek, llmotions, Ollama, LM Studio."
            )
          ]

        true ->
          [header_row(ctx) | Enum.map(providers, &provider_row(ctx, &1))]
      end

    draft_rows =
      if draft do
        name = R.field(R.draft_fields(draft), "name")

        [
          R.row(
            id: "link:draft",
            kind: :link,
            label: "New provider",
            value: [{"#{blank(name, "unnamed")} · unsaved", :warning}],
            keys: [{"Enter", :open_row, "open the draft"}],
            target: {:draft}
          )
        ]
      else
        []
      end

    [R.heading("providers", "providers", [{"a", :key}, {" add", :text_faint}])] ++
      list ++
      draft_rows ++
      env_rows(ctx) ++ [R.heading("actions", "actions"), add_row(ctx), fetch_all_row(ctx)]
  end

  defp header_row(_ctx) do
    R.row(
      id: "info:columns",
      kind: :info,
      label: "",
      state: :readonly,
      columns: [
        {"name", :text_faint, 1},
        {"kind", :text_faint, 4},
        {"key", :text_faint, 2},
        {"models", :text_faint, 3},
        {"last test", :text_faint, 5}
      ]
    )
  end

  defp provider_row(ctx, rec) do
    id = R.record_id(rec)
    f = R.fields(rec)
    usable = R.field(f, "usable") == true

    R.row(
      id: "rec:provider:#{id}",
      kind: :record,
      label: R.field(f, "name"),
      value: key_words(ctx, f),
      marks: if(usable, do: [], else: [:attention]),
      columns: [
        {R.field(f, "name"), :text_primary, 1},
        {ModelPicker.kind_label(R.field(f, "kind")), :text_muted, 4},
        {R.secret_words(R.field(f, "api_key"), R.tier(ctx)) |> segments_text() |> key_or_local(f),
         :text_muted, 2},
        {R.count(R.field(f, "models_count") || 0, "model"), :text_muted, 3},
        {last_test_words(ctx, R.field(f, "last_test")), :text_faint, 5}
      ],
      keys: [
        {"Enter", :open_row, "open"},
        {"t", :test, "test the connection"},
        {"f", :fetch, "fetch models"}
      ],
      target: {:provider, id},
      detail:
        R.detail(
          title: R.field(f, "name"),
          scope: "global · shared with the desktop app",
          description:
            "#{ModelPicker.kind_label(R.field(f, "kind"))} at #{R.field(f, "base_url")}.",
          facts: [{"usable", if(usable, do: "yes", else: "no — no key and not a local server")}]
        )
    )
  end

  defp segments_text(segs), do: Enum.map_join(segs, "", &elem(&1, 0))

  defp key_or_local(text, f) do
    if R.field(R.field(f, "api_key"), "set") != true and R.field(f, "usable") == true,
      do: "no key · local",
      else: text
  end

  defp key_words(ctx, f) do
    R.secret_words(R.field(f, "api_key"), R.tier(ctx))
  end

  defp last_test_words(ctx, nil), do: "not tested this session" <> if(ctx, do: "", else: "")

  defp last_test_words(ctx, test) do
    at = R.hhmm(R.field(test, "at"))

    case R.field(test, "state") do
      "done" -> "#{R.glyph(ctx, :ok)} #{at}"
      _ -> "#{R.glyph(ctx, :error)} #{R.field(test, "message")}"
    end
  end

  defp env_rows(ctx) do
    facts = Map.get(ctx, :launch_facts) || %{}
    env = R.field(facts, "env") || %{}
    set = Enum.filter(@onboarding_env, &Map.has_key?(env, &1))

    if set == [] do
      []
    else
      [
        R.row(
          id: "info:environment",
          kind: :info,
          label: "from the environment",
          value: [{Enum.join(set, ", "), :text_muted}],
          lines: [
            [{"used only when no provider can answer; nothing is saved from them", :text_faint}]
          ],
          state: :readonly,
          target: {:link, :files_env},
          keys: [{"Enter", :open_row, "Files & environment"}]
        )
      ]
    end
  end

  defp add_row(_ctx) do
    R.row(
      id: "act:providers.add",
      kind: :action,
      label: "▸ Add a provider…",
      value: [{"from a preset · nothing is saved until Ctrl-S", :text_faint}],
      keys: [{"Enter", :open_row, "choose a preset"}, {"a", :add, "add"}],
      target: {:add}
    )
  end

  defp fetch_all_row(ctx) do
    task = R.task(ctx, "provider.fetch_all")

    {value, tag} =
      if task do
        R.task_words(ctx, task, "fetching every provider's models", fn s ->
          total = R.field(s, "total") || length(R.field(s, "providers") || [])
          "#{R.count(total, "provider")} · #{R.field(s, "changed") || 0} changed lists"
        end)
      else
        {[{"shows each difference before it changes a list", :text_faint}], []}
      end

    R.row(
      id: "act:providers.fetch_all",
      kind: :action,
      label: "▸ Fetch every provider's models",
      value: value,
      tag: tag,
      state: if(R.running?(task), do: :running, else: :normal),
      keys: [{"Enter", :open_row, "fetch"}] ++ cancel_key(task),
      target: {:fetch_all}
    )
  end

  defp cancel_key(task) do
    if R.running?(task) and R.field(elem(task, 1), "cancellable") != false,
      do: [{"c", :cancel_task, "stop"}],
      else: []
  end

  # ------------------------------------------------------------- record page

  def record_rows(ctx, @kind, @draft), do: draft_rows(ctx)

  def record_rows(ctx, @kind, id) do
    case {R.page_sub(ctx), provider(ctx, id)} do
      {_, nil} ->
        if R.loaded?(ctx, "providers"),
          do: [
            R.info(
              "gone",
              "This provider was deleted (elsewhere in this session). Esc goes back."
            )
          ],
          else: [R.info("loading", "…", :text_faint)]

      {:models, f} ->
        models_rows(ctx, id, f)

      {:effort_levels, _f} ->
        EffortLevels.rows(ctx, id)

      {:delete, f} ->
        delete_rows(ctx, id, f)

      {_, f} ->
        provider_rows(ctx, id, f)
    end
  end

  def record_rows(_ctx, _kind, _id), do: []

  def sub_rows(ctx, sub) do
    case R.page_record(ctx) do
      {@kind, id} ->
        record_rows(Map.put(ctx, :page, Map.put(R.current_page(ctx), :sub, sub)), @kind, id)

      _ ->
        []
    end
  end

  defp provider(ctx, id) do
    case R.record(ctx, @kind, id) do
      nil -> nil
      rec -> R.fields(rec)
    end
  end

  defp provider_name(ctx, id) do
    case provider(ctx, id) do
      nil -> nil
      f -> R.field(f, "name")
    end
  end

  defp provider_rows(ctx, id, f) do
    name = R.field(f, "name")
    anthropic = R.field(f, "kind") == "anthropic"

    [
      head_row(ctx, id, f),
      R.heading("connection", "connection"),
      field_row(ctx, id, f, "name", "Name", {:text, R.field(f, "name")}),
      kind_row(ctx, id, f),
      field_row(ctx, id, f, "base_url", "Base URL", {:text, R.field(f, "base_url")}),
      key_row(ctx, id, f),
      test_row(ctx, id, f),
      R.heading("models", "models"),
      default_model_row(ctx, id, f),
      models_summary_row(ctx, id, f)
    ] ++
      fetch_rows(ctx, id, f) ++
      [effort_row(ctx, id, f)] ++
      if(anthropic, do: [fallbacks_row(ctx, id, f)], else: []) ++
      use_for_chats_rows(ctx, id, f) ++
      forget_caps_rows(ctx, id, f) ++
      used_by_rows(ctx, f) ++
      [
        R.heading("danger", "danger"),
        R.row(
          id: "act:provider.delete",
          kind: :action,
          label: "▸ Delete this provider…",
          value: [{"asks first and shows what uses it", :text_faint}],
          tag: [{"D", :key}],
          keys: [{"D", :delete, "delete #{name}"}, {"Enter", :open_row, "delete…"}],
          target: {:delete, id}
        )
      ]
  end

  defp head_row(ctx, id, f) do
    used = R.field(f, "used_by") || %{}
    convs = R.field(used, "conversations") || 0
    test = R.field(f, "last_test")

    tag =
      case test && R.field(test, "state") do
        "done" ->
          [
            {R.glyph(ctx, :ok) <> " ", :success},
            {"answered #{R.hhmm(R.field(test, "at"))}", :text_muted}
          ]

        "failed" ->
          [{R.glyph(ctx, :error) <> " ", :error}, {"did not answer", :text_muted}]

        _ ->
          []
      end

    R.row(
      id: "info:head:#{id}",
      kind: :info,
      label: R.field(f, "name"),
      value: [
        {"#{ModelPicker.kind_label(R.field(f, "kind"))} · global · #{R.count(convs, "conversation")} use it",
         :text_faint}
      ],
      tag: tag,
      state: :readonly
    )
  end

  defp field_row(ctx, id, f, field, label, {:text, value}) do
    row_id = "fld:provider:#{id}:#{field}"

    R.row(
      id: row_id,
      kind: :field,
      key: "provider.#{field}",
      label: label,
      value: [{to_string(value || ""), :text_primary}],
      tag: [{"global", :text_muted}],
      lines: error_lines(ctx, row_id),
      marks: if(R.row_error(ctx, row_id), do: [:invalid], else: []),
      editor:
        {SwarmCodeCLI.UI.Settings.Editors.Text,
         %{value: value || "", max: if(field == "name", do: 120, else: 2_048)}},
      keys: [{"Enter", :open_row, "edit"}],
      target: {:field, id, field, R.field(f, field)},
      detail: field_detail(field, f)
    )
  end

  defp field_detail("base_url", f) do
    R.detail(
      title: "Base URL · #{R.field(f, "name")}",
      scope: "global · shared with the desktop app",
      key_line: "provider.base_url · providers.base_url",
      description:
        "Where SwarmCode sends this provider's requests. Local and private addresses are allowed. A change clears the last test result: it tested another URL.",
      facts: [{"applies", "next request"}]
    )
  end

  defp field_detail(field, f) do
    R.detail(
      title: "#{String.capitalize(field)} · #{R.field(f, "name")}",
      scope: "global · shared with the desktop app",
      key_line: "provider.#{field} · providers.#{field}",
      facts: [{"applies", "at once"}]
    )
  end

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      message -> [[{R.glyph(ctx, :error) <> " " <> message, :error}]]
    end
  end

  defp kind_row(ctx, id, f) do
    kind = R.field(f, "kind")
    row_id = "fld:provider:#{id}:kind"

    R.row(
      id: row_id,
      kind: :field,
      key: "provider.kind",
      label: "Kind",
      value: [{ModelPicker.kind_label(kind), :text_primary}],
      tag: [{"global", :text_muted}],
      lines: error_lines(ctx, row_id),
      editor:
        {SwarmCodeCLI.UI.Settings.Editors.Enum,
         %{
           choices: [
             %{value: "anthropic", label: "Anthropic", hint: nil},
             %{value: "openai_compatible", label: "OpenAI-compatible", hint: nil}
           ],
           value: kind
         }},
      keys: [{"Enter", :open_row, "change"}, {"←→", :step, "switch"}],
      target: {:field, id, "kind", kind}
    )
  end

  defp key_row(ctx, id, f) do
    key = R.field(f, "api_key")
    set = R.field(key, "set") == true
    row_id = "fld:provider:#{id}:api_key"
    task = R.task(ctx, "provider.set_key", %{"id" => id})

    lines =
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
          error_lines(ctx, row_id)
      end

    value =
      if set,
        do:
          R.secret_words(key, R.tier(ctx)) ++ [{" · stored in SwarmCode's database", :text_faint}],
        else:
          [{"not set", :text_ghost}] ++
            if(R.field(f, "usable") == true,
              do: [{" · a local server needs none", :text_faint}],
              else: []
            )

    R.row(
      id: row_id,
      kind: :field,
      key: "provider.api_key",
      label: "API key",
      value: value,
      tag: [{"global", :text_muted}],
      lines: lines,
      state: if(R.running?(task), do: :running, else: :normal),
      keys:
        [{"Enter", :open_row, if(set, do: "paste a new key", else: "paste the key")}] ++
          if(set, do: [{"x", :delete, "remove the key · asks first"}], else: []) ++
          [{"t", :test, "test the connection"}],
      target: {:key, id, set},
      detail:
        R.detail(
          title: "API key · #{R.field(f, "name")}",
          scope: "global · shared with the desktop app",
          key_line: "provider.api_key · secret",
          description:
            "The key SwarmCode sends to #{host(R.field(f, "base_url"))} with each request of this provider. It is never shown again, never written to a log, never in search results and never kept for undo.",
          facts: [
            {"state", if(set, do: "set", else: "not set")},
            {"stored", "stored in SwarmCode's database"},
            {"sent to", "#{host(R.field(f, "base_url"))} only"},
            {"shared", "with the desktop app"}
          ]
        )
    )
  end

  defp host(url) when is_binary(url), do: URI.parse(url).host || url
  defp host(_), do: "the provider"

  defp test_row(ctx, id, _f) do
    task = R.task(ctx, "provider.test", %{"id" => id})

    {value, tag} =
      if task do
        R.task_words(ctx, task, "testing the connection", fn s ->
          "listed #{R.count(R.field(s, "count") || 0, "model")} in #{R.field(s, "ms") || 0} ms"
        end)
      else
        {[{"lists the models with the saved values; writes nothing", :text_faint}], [{"t", :key}]}
      end

    R.row(
      id: "act:provider.test",
      kind: :action,
      label: "▸ Test connection",
      value: value,
      tag: tag,
      state: if(R.running?(task), do: :running, else: :normal),
      keys:
        [{"Enter", :open_row, "test"}, {"t", :test, "test the connection"}] ++ cancel_key(task),
      target: {:test, id}
    )
  end

  defp default_model_row(ctx, id, f) do
    model = R.field(f, "default_model")
    row_id = "fld:provider:#{id}:default_model"

    R.row(
      id: row_id,
      kind: :field,
      key: "provider.default_model",
      label: "Default model",
      value: if(model, do: [{model, :text_primary}], else: [{"none", :text_ghost}]),
      tag: [{"global", :text_muted}],
      lines: error_lines(ctx, row_id),
      editor:
        {ModelPicker,
         %{
           provider_id: id,
           nullable: true,
           null_label: "none",
           current: if(model, do: %{"provider_id" => id, "model" => model}),
           title: "Default model · #{R.field(f, "name")}"
         }},
      keys: [{"Enter", :open_row, "pick"}],
      target: {:field, id, "default_model", model}
    )
  end

  defp models_summary_row(ctx, id, f) do
    models = R.field(f, "models") || []
    fetched = R.field(f, "last_fetch")
    diff = pending_fetch(ctx, id, f)

    when_words =
      case fetched && R.field(fetched, "state") do
        "done" -> "fetched this session #{R.hhmm(R.field(fetched, "at"))}"
        _ -> "not fetched this session"
      end

    value =
      case diff do
        {_task_id, summary, _rows} ->
          after_count = length(models) + (R.field(summary, "added") || 0)

          [
            {"#{length(models)} → #{after_count}", :text_primary},
            {" after this fetch", :text_faint}
          ]

        nil ->
          [{"#{length(models)}", :text_primary}, {" · #{when_words}", :text_faint}]
      end

    R.row(
      id: "fld:provider:#{id}:models",
      kind: :field,
      key: "provider.models",
      label: "Models",
      value: value,
      tag:
        if(diff,
          do: [{"not applied", :warning}],
          else: [{"Enter", :key}, {" edit the list", :text_faint}]
        ),
      marks: if(diff, do: [:pending], else: []),
      lines: [[{Enum.join(Enum.take(models, 4), "  ") <> more(models, 4), :text_muted}]],
      keys: [{"Enter", :open_row, "edit the list"}, {"f", :fetch, "fetch models"}],
      target: {:open_sub, id, :models}
    )
  end

  defp more(list, n) when length(list) > n, do: "  +#{length(list) - n}"
  defp more(_list, _n), do: ""

  @doc """
  The fetch difference waiting to be applied, `{task_id, summary, rows}`, or nil: the last
  `provider.fetch_models` of this provider is done and it lists a model the record does not
  have yet (or would drop one a replace removes).
  """
  def pending_fetch(ctx, id, f) do
    with {task_id, task} <- R.task(ctx, "provider.fetch_models", %{"id" => id}),
         "done" <- to_string(R.field(task, "state")) do
      rows = R.task_rows(ctx, task_id)
      summary = R.task_summary(ctx, task_id) || R.field(task, "summary") || %{}
      models = R.field(f, "models") || []
      new = for r <- rows, R.field(r, "change") == "new", do: R.field(r, "model")
      gone = for r <- rows, R.field(r, "change") == "gone", do: R.field(r, "model")

      if Enum.any?(new, &(&1 not in models)) or (new == [] and Enum.any?(gone, &(&1 in models))),
        do: {task_id, summary, rows},
        else: nil
    else
      _ -> nil
    end
  end

  defp fetch_rows(ctx, id, f) do
    task = R.task(ctx, "provider.fetch_models", %{"id" => id})
    diff = pending_fetch(ctx, id, f)

    {value, tag} =
      if task do
        R.task_words(ctx, task, "fetching the model list", fn s ->
          "#{R.count(R.field(s, "listed") || 0, "model")} from #{host(R.field(f, "base_url"))} · #{R.field(s, "ms") || 0} ms"
        end)
      else
        {[{"shows the difference before it changes the list", :text_faint}], [{"f", :key}]}
      end

    action =
      R.row(
        id: "act:provider.fetch_models",
        kind: :action,
        label: "▸ Fetch models",
        value: value,
        tag: tag,
        state: if(R.running?(task), do: :running, else: :normal),
        keys:
          [{"Enter", :open_row, "fetch"}, {"f", :fetch, "fetch models"}] ++
            diff_keys(diff) ++ cancel_key(task),
        target: {:fetch, id}
      )

    [action | diff_rows(ctx, id, diff)]
  end

  defp diff_keys(nil), do: []

  defp diff_keys({_id, summary, _rows}) do
    if R.field(summary, "truncated") == true,
      do: [{"+", :add_key, "add the new ones only"}],
      else: [{"a", :add, "apply all"}, {"+", :add_key, "add the new ones only"}]
  end

  defp diff_rows(_ctx, _id, nil), do: []

  defp diff_rows(ctx, id, {task_id, summary, rows}) do
    changes =
      for r <- rows, R.field(r, "change") in ["new", "gone"] do
        model = R.field(r, "model")

        case R.field(r, "change") do
          "new" ->
            R.row(
              id: "item:diff:#{model}",
              kind: :list_item,
              label: "",
              indent: 2,
              value: [{"+ ", :success}, {model, :text_primary}, {"  new", :text_faint}],
              target: {:diff, id, task_id},
              keys: diff_keys({task_id, summary, rows})
            )

          "gone" ->
            n = R.field(r, "conversations") || 0
            use = if n > 0, do: " · #{R.count(n, "conversation")} use it", else: ""

            R.row(
              id: "item:diff:#{model}",
              kind: :list_item,
              label: "",
              indent: 2,
              value: [
                {R.glyph(ctx, :gone) <> " ", :error},
                {model, :text_primary},
                {"  not listed any more#{use}", :text_faint}
              ],
              target: {:diff, id, task_id},
              keys: diff_keys({task_id, summary, rows})
            )
        end
      end

    same = R.field(summary, "unchanged") || Enum.count(rows, &(R.field(&1, "change") == "same"))
    truncated = R.field(summary, "truncated") == true

    footer =
      if truncated,
        do: [
          {"+", :key},
          {" add the new ones only   ", :text_faint},
          {"Esc", :key},
          {" keep the old list", :text_faint}
        ],
        else: [
          {"a", :key},
          {" apply all   ", :text_faint},
          {"+", :key},
          {" add the new ones only   ", :text_faint},
          {"Esc", :key},
          {" keep the old list", :text_faint}
        ]

    trunc_line =
      if truncated,
        do: [
          R.info(
            "diff:truncated",
            "the list was longer than 2 000 (#{R.field(summary, "listed")} listed); only adding is offered",
            :warning
          )
        ],
        else: []

    changes ++
      [
        R.row(
          id: "info:diff:same",
          kind: :info,
          label: "",
          indent: 2,
          value: [{"#{same} unchanged", :text_faint}],
          lines: [footer],
          target: {:diff, id, task_id},
          keys: diff_keys({task_id, summary, rows})
        )
      ] ++
      trunc_line
  end

  defp effort_row(_ctx, id, f) do
    R.row(
      id: "fld:provider:#{id}:effort_levels",
      kind: :field,
      key: "provider.effort_levels",
      label: "Effort levels",
      value: [{EffortLevels.source_words(f), :text_muted}],
      tag: [{"Enter", :key}, {" open", :text_faint}],
      keys: [{"Enter", :open_row, "open"}],
      target: {:open_sub, id, :effort_levels}
    )
  end

  defp fallbacks_row(ctx, id, f) do
    on = R.field(f, "fallbacks") == true
    row_id = "fld:provider:#{id}:fallbacks"

    R.row(
      id: row_id,
      kind: :field,
      key: "provider.fallbacks",
      label: "Fallback on a refusal",
      value: [{if(on, do: "on", else: "off"), :text_primary}],
      tag: [{"global", :text_muted}],
      lines: error_lines(ctx, row_id),
      editor: {SwarmCodeCLI.UI.Settings.Editors.Toggle, %{value: on}},
      keys: [{"Space", :toggle, "switch"}],
      target: {:field, id, "fallbacks", on}
    )
  end

  defp use_for_chats_rows(ctx, id, f) do
    model = R.field(f, "default_model")
    current = R.value_of(ctx, "models.chat")

    already =
      is_map(current) and R.field(current, "provider_id") == id and
        R.field(current, "model") == model

    if R.field(f, "usable") == true and is_binary(model) and not already do
      [
        R.row(
          id: "act:provider.use_for_chats",
          kind: :action,
          label: "▸ Use #{R.field(f, "name")} · #{model} for new chats",
          value: [
            {"sets the chat and sub-agent models of new conversations · u undoes", :text_faint}
          ],
          keys: [{"Enter", :open_row, "use it"}],
          target: {:use_for_chats, id, model}
        )
      ]
    else
      []
    end
  end

  defp forget_caps_rows(_ctx, id, f) do
    caps = R.field(f, "caps") || %{}
    learned = for {k, v} <- caps, v == true, do: k

    if learned == [] do
      []
    else
      words =
        learned
        |> Enum.map(fn
          "effort_rejected" -> "it refused the effort parameter"
          "prefix_cache_rejected" -> "it refused prompt caching"
          "fallbacks_rejected" -> "it refused the refusal fallback"
          other -> other
        end)
        |> Enum.join(" · ")

      [
        R.row(
          id: "act:provider.forget_caps",
          kind: :action,
          label: "▸ Forget what this session learned",
          value: [{words, :text_faint}],
          keys: [{"Enter", :open_row, "forget"}],
          target: {:forget_caps, id}
        )
      ]
    end
  end

  defp used_by_rows(_ctx, f) do
    used = R.field(f, "used_by")

    if is_map(used) do
      parts =
        Enum.map(R.field(used, "defaults") || [], &default_words/1) ++
          Enum.map(R.field(used, "research") || [], &default_words/1) ++
          [R.count(R.field(used, "conversations") || 0, "conversation")] ++
          if((R.field(used, "scheduled_tasks") || 0) > 0,
            do: [R.count(R.field(used, "scheduled_tasks"), "scheduled task")],
            else: []
          )

      [
        R.heading("used by", "used by"),
        R.row(
          id: "info:used_by",
          kind: :info,
          label: "",
          value: [{Enum.join(parts, " · "), :text_muted}],
          state: :readonly
        )
      ]
    else
      []
    end
  end

  @default_words %{
    "models.chat" => "the chat default",
    "models.sub_agent" => "the sub-agent default",
    "models.scheduled" => "the scheduled default",
    "models.workflow" => "the workflow default",
    "models.implementer" => "the implementer default",
    "research.lead_model" => "the research lead",
    "research.worker_model" => "the research workers",
    "research.reporter_model" => "the research reporter"
  }

  @doc "A default the provider serves, in words."
  def default_words(key), do: Map.get(@default_words, key, key)

  # ---------------------------------------------------------- the models list

  defp models_rows(ctx, id, f) do
    models = R.field(f, "models") || []
    query = R.filter(ctx, {:providers, {@kind, id}, :models})

    shown =
      models
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} ->
        query in [nil, ""] or String.contains?(String.downcase(m), String.downcase(query))
      end)

    head =
      R.row(
        id: "info:models:head",
        kind: :info,
        label: "#{R.field(f, "name")} › Models",
        value: [{"#{length(models)} of 2 000 at most", :text_faint}],
        tag: [{"a", :key}, {" add · ", :text_faint}, {"/", :key}, {" filter", :text_faint}],
        state: :readonly
      )

    items =
      for {m, i} <- shown do
        R.row(
          id: "item:models:#{i}",
          kind: :list_item,
          label: m,
          value: if(m == R.field(f, "default_model"), do: [{"default", :text_faint}], else: []),
          editor: {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: m, max: 256}},
          keys: [
            {"Enter", :open_row, "edit"},
            {"x", :delete, "remove"},
            {"J", :move_down, "down"},
            {"K", :move_up, "up"}
          ],
          target: {:model_item, id, i, m}
        )
      end

    add =
      R.row(
        id: "act:models.add",
        kind: :action,
        label: "▸ Add a model",
        value: [{"type its id as the provider names it", :text_faint}],
        editor: {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: "", max: 256}},
        keys: [{"Enter", :open_row, "add"}, {"a", :add, "add"}],
        target: {:model_add, id}
      )

    empty =
      if models == [],
        do: [R.info("models:none", "No model yet · f fetches the list, a adds one")],
        else: []

    [head] ++ empty ++ items ++ [add]
  end

  # ------------------------------------------------------------- delete page

  defp delete_rows(ctx, id, f) do
    name = R.field(f, "name")
    used = R.field(f, "used_by") || %{}
    serves = (R.field(used, "defaults") || []) ++ (R.field(used, "research") || [])
    picks = replacements(ctx, id)
    others = Enum.reject(R.items(ctx, "providers"), &(R.record_id(&1) == id))
    convs = R.field(used, "conversations") || 0
    tasks = R.field(used, "scheduled_tasks") || 0
    ready = Enum.all?(serves, &Map.has_key?(picks, &1))

    [
      R.row(
        id: "info:delete:head",
        kind: :info,
        label: "Delete #{name}?",
        value: [{"not undoable", :warning}],
        state: :readonly
      ),
      R.info(
        "delete:conversations",
        "#{R.count(convs, "conversation")} use it · their messages stay; new turns use the replacement"
      ),
      R.info("delete:key", "its API key is deleted with it")
    ] ++
      if(tasks > 0,
        do: [R.info("delete:scheduled", R.count(tasks, "scheduled task") <> " name it")],
        else: []
      ) ++
      if(others == [],
        do: [
          R.info(
            "delete:only",
            "SwarmCode will have no model to talk to until you add one",
            :warning
          )
        ],
        else: []
      ) ++
      if(serves == [],
        do: [],
        else: [R.heading("replacements", "a replacement for every default it serves")]
      ) ++
      Enum.map(serves, fn key ->
        pick = Map.get(picks, key)

        R.row(
          id: "fld:replacement:#{key}",
          kind: :field,
          key: key,
          label: String.capitalize(default_words(key)),
          value:
            if(pick,
              do: ModelPicker.describe(pick, ctx, nil),
              else: [{"pick a replacement", :warning}]
            ),
          editor:
            {ModelPicker,
             %{current: pick, title: "Replace #{default_words(key)}", nullable: false}},
          keys: [{"Enter", :open_row, "pick"}],
          target: {:replacement, id, key}
        )
      end) ++
      [
        R.row(
          id: "act:delete:keep",
          kind: :action,
          label: "Keep #{name}",
          keys: [{"Esc", :back, "keep it"}],
          target: {:back}
        ),
        R.row(
          id: "act:delete:confirm",
          kind: :action,
          label: "D  Delete #{name}",
          value: if(ready, do: [], else: [{"pick every replacement first", :text_faint}]),
          state: if(ready, do: :normal, else: :disabled),
          keys: [{"D", :delete, "delete #{name}"}],
          target: {:delete_now, id}
        )
      ]
  end

  defp replacements(ctx, id) do
    ctx |> R.staged(@kind, id) |> Map.get("replacements", %{})
  end

  # ------------------------------------------------------------- the draft

  defp draft_rows(ctx) do
    draft = R.draft(ctx, @kind)
    f = R.draft_fields(draft)
    errors = R.draft_errors(draft)
    preset = Enum.find(@presets, &(&1.id == R.field(f, "preset")))

    err = fn field ->
      if m = Map.get(errors, field), do: [[{R.glyph(ctx, :error) <> " " <> m, :error}]], else: []
    end

    text_row = fn field, label, max ->
      R.row(
        id: "fld:provider:draft:#{field}",
        kind: :field,
        key: "provider.#{field}",
        label: label,
        value: [{to_string(R.field(f, field) || ""), :text_primary}],
        lines: err.(field),
        marks: if(Map.has_key?(errors, field), do: [:invalid], else: []),
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: R.field(f, field) || "", max: max}},
        keys: [{"Enter", :open_row, "edit"}],
        target: {:draft_field, field}
      )
    end

    key_set = R.draft_secret?(draft, "api_key")

    [
      R.row(
        id: "info:draft:head",
        kind: :info,
        label: "New provider",
        value: [{"unsaved · Ctrl-S creates it · Esc discards", :warning}],
        state: :readonly
      ),
      R.heading("connection", "connection"),
      text_row.("name", "Name", 120),
      R.row(
        id: "fld:provider:draft:kind",
        kind: :field,
        key: "provider.kind",
        label: "Kind",
        value: [
          {ModelPicker.kind_label(R.field(f, "kind") || "openai_compatible"), :text_primary}
        ],
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Enum,
           %{
             choices: [
               %{value: "anthropic", label: "Anthropic", hint: nil},
               %{value: "openai_compatible", label: "OpenAI-compatible", hint: nil}
             ],
             value: R.field(f, "kind") || "openai_compatible"
           }},
        keys: [{"Enter", :open_row, "change"}],
        target: {:draft_field, "kind"}
      ),
      text_row.("base_url", "Base URL", 2_048),
      R.row(
        id: "fld:provider:draft:api_key",
        kind: :field,
        key: "provider.api_key",
        label: "API key",
        value:
          if(key_set,
            do: [
              {if(R.tier(ctx) == :ascii, do: "********", else: "●●●●●●●●"), :text_muted},
              {" pasted · not shown", :text_primary}
            ],
            else: [
              {if(preset && !preset.key?, do: "not needed for a local server", else: "not set"),
               :text_ghost}
            ]
          ),
        lines: err.("api_key"),
        keys: [{"Enter", :open_row, "paste the key"}],
        target: {:draft_key}
      ),
      R.heading("models", "models"),
      text_row.("default_model", "Default model", 256),
      R.row(
        id: "fld:provider:draft:effort_levels",
        kind: :field,
        key: "provider.effort_levels",
        label: "Effort levels",
        value: [{draft_levels_words(preset), :text_muted}],
        state: :readonly,
        target: {:draft_levels}
      ),
      R.row(
        id: "act:provider.create",
        kind: :action,
        label: "▸ Create it",
        value: [{"Ctrl-S · saves it, stores the key and tests the connection", :text_faint}],
        keys: [{"Enter", :open_row, "create"}, {"Ctrl-S", :save, "create"}],
        target: {:create}
      )
    ]
  end

  defp draft_levels_words(nil), do: "built-in levels"
  defp draft_levels_words(%{effort_preset: nil}), do: "built-in levels"
  defp draft_levels_words(%{name: name}), do: "#{name} · from the preset"

  # -------------------------------------------------------------------- act

  @doc """
  The row letters (§4.3): `a` add (a preset picker on the list, apply all on a fetch
  difference, add on the models list), `+` add new models only, `t` test, `f` fetch, `x`
  remove the key / a model, `D` delete, `J`/`K` move a model, `s` save a refused key
  anyway, `Ctrl-S` create the draft, Enter on action rows.
  """
  def act(ctx, row, verb) do
    do_act(ctx, R.field(row, "target") || Map.get(row, :target), verb, row)
  end

  # the list page
  defp do_act(_ctx, {:add}, verb, _row) when verb in [:open_row, :add], do: [preset_picker()]
  defp do_act(_ctx, {:fetch_all}, :open_row, _row), do: [{:task, "provider.fetch_all", nil, %{}}]
  defp do_act(_ctx, {:fetch_all}, :fetch, _row), do: [{:task, "provider.fetch_all", nil, %{}}]

  defp do_act(_ctx, {:draft}, :open_row, _row),
    do: [{:open, R.new_page(:providers, {@kind, @draft})}]

  defp do_act(_ctx, {:link, section}, :open_row, _row), do: [{:section, section}]

  defp do_act(_ctx, {:provider, id}, :open_row, _row),
    do: [{:open, R.new_page(:providers, {@kind, id})}]

  defp do_act(_ctx, {:provider, id}, :test, _row),
    do: [{:task, "provider.test", %{"id" => id}, %{}}]

  defp do_act(_ctx, {:provider, id}, :fetch, _row),
    do: [{:task, "provider.fetch_models", %{"id" => id}, %{}}]

  defp do_act(ctx, {:provider, id}, :delete, _row), do: delete_ops(ctx, id)

  # the record page
  defp do_act(_ctx, {:test, id}, verb, _row) when verb in [:open_row, :test],
    do: [{:task, "provider.test", %{"id" => id}, %{}}]

  defp do_act(ctx, {:fetch, id}, :open_row, _row), do: fetch_ops(ctx, id)
  defp do_act(ctx, _target, :fetch, _row), do: page_id_ops(ctx, &fetch_ops(ctx, &1))

  defp do_act(ctx, _target, :test, _row),
    do: page_id_ops(ctx, &[{:task, "provider.test", %{"id" => &1}, %{}}])

  defp do_act(ctx, {:open_sub, id, sub}, :open_row, _row),
    do: [{:open, %{R.new_page(:providers, {@kind, id}, sub) | cursor: nil}}] |> keep_ctx(ctx)

  defp do_act(ctx, {:key, id, set?}, :open_row, _row), do: [{:paste, key_target(ctx, id, set?)}]
  defp do_act(ctx, {:key, id, true}, :delete, _row), do: clear_key_ops(ctx, id)
  defp do_act(ctx, {:key, id, _set?}, :alt, _row), do: save_anyway_ops(ctx, id)

  defp do_act(ctx, {:use_for_chats, id, model}, :open_row, _row),
    do: use_for_chats_ops(ctx, id, model)

  defp do_act(_ctx, {:forget_caps, id}, :open_row, _row),
    do: [
      {:command, "provider.forget_caps", %{"id" => id}, %{},
       %{toast: "Forgot what this session learned"}}
    ]

  defp do_act(ctx, {:delete, id}, verb, _row) when verb in [:open_row, :delete],
    do: delete_ops(ctx, id)

  defp do_act(ctx, _target, :delete, %{id: "act:provider.delete"}),
    do: page_id_ops(ctx, &delete_ops(ctx, &1))

  defp do_act(ctx, {:delete_now, id}, verb, _row) when verb in [:open_row, :delete],
    do: delete_now_ops(ctx, id)

  defp do_act(_ctx, {:back}, :open_row, _row), do: [:back]
  defp do_act(ctx, {:diff, id, task_id}, :add, _row), do: apply_ops(ctx, id, task_id, "replace")
  defp do_act(ctx, {:diff, id, task_id}, :add_key, _row), do: apply_ops(ctx, id, task_id, "add")

  defp do_act(ctx, {:fetch, id}, verb, _row) when verb in [:add, :add_key],
    do: apply_pending(ctx, id, verb)

  defp do_act(ctx, {:model_item, id, index, _m}, :delete, _row),
    do: models_ops(ctx, id, &List.delete_at(&1, index), "Removed a model")

  defp do_act(ctx, {:model_item, id, index, _m}, :move_down, _row),
    do: models_ops(ctx, id, &swap(&1, index, index + 1), "Moved a model")

  defp do_act(ctx, {:model_item, id, index, _m}, :move_up, _row),
    do: models_ops(ctx, id, &swap(&1, index, index - 1), "Moved a model")

  defp do_act(_ctx, {:model_item, _id, _i, _m}, :add, _row), do: [{:edit, "act:models.add"}]
  defp do_act(_ctx, {:model_add, _id}, :add, _row), do: [{:edit, "act:models.add"}]

  defp do_act(_ctx, {:replacement, _id, key}, :open_row, _row),
    do: [{:edit, "fld:replacement:#{key}"}]

  # the draft
  defp do_act(ctx, {:draft_key}, :open_row, _row), do: [{:paste, draft_key_target(ctx)}]

  defp do_act(ctx, _target, :save, _row),
    do: if(R.page_record(ctx) == {@kind, @draft}, do: create_ops(ctx), else: :default)

  defp do_act(ctx, {:create}, :open_row, _row), do: create_ops(ctx)

  defp do_act(ctx, _target, :add, _row) do
    if R.page_record(ctx) == nil, do: [preset_picker()], else: :default
  end

  defp do_act(_ctx, _target, _verb, _row), do: :default

  defp keep_ctx(ops, _ctx), do: ops

  defp page_id_ops(ctx, fun) do
    case R.page_record(ctx) do
      {@kind, @draft} -> :default
      {@kind, id} -> fun.(id)
      _ -> :default
    end
  end

  defp preset_picker do
    {:picker,
     R.picker(
       id: "provider.preset",
       title: "Add a provider",
       options:
         for p <- @presets do
           %{
             value: p.id,
             label: if(p.id == "other", do: "Other", else: p.name),
             hint: preset_hint(p)
           }
         end,
       on_pick: {:section, :providers, :preset}
     )}
  end

  defp preset_hint(%{id: "other"}), do: "a blank OpenAI-compatible provider"
  defp preset_hint(%{base_url: url, key?: false}), do: "#{url} · no key"
  defp preset_hint(%{base_url: url}), do: url

  defp fetch_ops(_ctx, id), do: [{:task, "provider.fetch_models", %{"id" => id}, %{}}]

  defp key_target(ctx, id, set?) do
    name = provider_name(ctx, id) || "Provider"

    %{
      row_id: "fld:provider:#{id}:api_key",
      action: "provider.set_key",
      target: %{"id" => id},
      attributes: %{"test_first" => set?},
      slot: "api_key",
      label: "#{name} API key",
      set?: set?,
      kind: @kind,
      expected: %{"key" => R.field(provider(ctx, id) || %{}, "api_key")},
      then: if(set?, do: [], else: [{:task, "provider.test", %{"id" => id}, %{}}])
    }
  end

  defp draft_key_target(_ctx) do
    %{
      row_id: "fld:provider:draft:api_key",
      action: nil,
      draft: @kind,
      target: nil,
      attributes: %{},
      slot: "api_key",
      label: "The new provider's API key",
      set?: false,
      kind: @kind
    }
  end

  defp save_anyway_ops(ctx, id) do
    case R.task(ctx, "provider.set_key", %{"id" => id}) do
      {_tid, t} = task when task != nil ->
        if R.field(t, "state") in ["failed", "timeout"] do
          [
            {:command, "provider.set_key", %{"id" => id}, %{"test_first" => false},
             %{
               secrets_from: :paste,
               expected: %{"key" => R.field(provider(ctx, id) || %{}, "api_key")},
               toast: "#{provider_name(ctx, id)} API key saved",
               then: [{:task, "provider.test", %{"id" => id}, %{}}]
             }}
          ]
        else
          :default
        end

      _ ->
        :default
    end
  end

  defp clear_key_ops(ctx, id) do
    f = provider(ctx, id) || %{}
    name = R.field(f, "name")

    [
      {:confirm,
       R.confirm(
         id: "provider.clear_key",
         title: "Remove #{name}'s API key?",
         lines: [
           "Requests to #{host(R.field(f, "base_url"))} will be refused until you paste a new key"
         ],
         safe: "Keep it",
         danger: "Remove the key",
         letter: "R",
         opener: "fld:provider:#{id}:api_key"
       ),
       then: [
         {:command, "provider.clear_key", %{"id" => id}, %{},
          %{
            expected: %{"key" => R.field(f, "api_key")},
            write_key: {:secret, @kind, id, "api_key"},
            undo: false,
            toast: "#{name} API key removed"
          }}
       ]}
    ]
  end

  defp use_for_chats_ops(_ctx, id, model) do
    pair = %{"provider_id" => id, "model" => model}
    [{:patch, "models.chat", pair}, {:patch, "models.sub_agent", pair}]
  end

  defp delete_ops(ctx, id) do
    f = provider(ctx, id) || %{}
    used = R.field(f, "used_by") || %{}
    serves = (R.field(used, "defaults") || []) ++ (R.field(used, "research") || [])

    if serves == [] do
      name = R.field(f, "name")
      convs = R.field(used, "conversations") || 0

      [
        {:confirm,
         R.confirm(
           id: "provider.delete",
           title: "Delete #{name}?",
           lines:
             [
               "#{R.count(convs, "conversation")} use it · their messages stay; new turns use the replacement",
               "its API key is deleted with it"
             ] ++
               if(length(R.items(ctx, "providers")) <= 1,
                 do: ["SwarmCode will have no model to talk to until you add one"],
                 else: []
               ),
           safe: "Keep #{name}",
           danger: "Delete #{name}",
           letter: "D",
           undoable?: false,
           opener: "act:provider.delete"
         ), then: delete_command(ctx, id, %{})}
      ]
    else
      [{:open, R.new_page(:providers, {@kind, id}, :delete)}]
    end
  end

  defp delete_now_ops(ctx, id) do
    f = provider(ctx, id) || %{}
    used = R.field(f, "used_by") || %{}
    serves = (R.field(used, "defaults") || []) ++ (R.field(used, "research") || [])
    picks = replacements(ctx, id)

    if Enum.all?(serves, &Map.has_key?(picks, &1)),
      do: delete_command(ctx, id, Map.take(picks, serves)) ++ [:back],
      else: [{:toast, "Pick a replacement for every default it serves first", :warning}]
  end

  defp delete_command(ctx, id, replacements) do
    f = provider(ctx, id) || %{}

    [
      {:command, "provider.delete", %{"id" => id}, %{"replacements" => replacements},
       %{
         expected: %{"updated_at" => R.field(f, "updated_at")},
         write_key: {:record, @kind, id, :delete},
         undo: false,
         toast: "Deleted #{R.field(f, "name")}",
         after: :back
       }}
    ]
  end

  defp apply_pending(ctx, id, verb) do
    case pending_fetch(ctx, id, provider(ctx, id) || %{}) do
      nil ->
        :default

      {task_id, _s, _r} ->
        apply_ops(ctx, id, task_id, if(verb == :add, do: "replace", else: "add"))
    end
  end

  defp apply_ops(ctx, id, task_id, mode) do
    f = provider(ctx, id) || %{}
    summary = R.task_summary(ctx, task_id) || %{}

    if mode == "replace" and R.field(summary, "truncated") == true do
      [{:toast, "the list was longer than 2 000; add new ones instead", :warning}]
    else
      [
        {:command, "provider.apply_models", %{"id" => id},
         %{"fetch_task_id" => task_id, "mode" => mode},
         %{
           expected: %{"fields" => %{"models" => R.field(f, "models") || []}},
           write_key: {:record, @kind, id, "models"},
           undo:
             {:command, "provider.update", %{"id" => id},
              %{"models" => R.field(f, "models") || []}, %{}},
           toast: if(mode == "add", do: "Added the new models", else: "Applied the fetched list")
         }}
      ]
    end
  end

  defp models_ops(ctx, id, fun, toast) do
    f = provider(ctx, id) || %{}
    old = R.field(f, "models") || []
    new = fun.(old)

    if new == old,
      do: [],
      else: [field_command(id, "models", new, old, toast)]
  end

  defp swap(list, i, j) when i >= 0 and j >= 0 and i < length(list) and j < length(list) do
    a = Enum.at(list, i)
    b = Enum.at(list, j)
    list |> List.replace_at(i, b) |> List.replace_at(j, a)
  end

  defp swap(list, _i, _j), do: list

  defp create_ops(ctx) do
    f = R.draft_fields(R.draft(ctx, @kind))
    preset = Enum.find(@presets, &(&1.id == R.field(f, "preset")))
    levels = preset_levels(ctx, preset)

    attrs = %{
      "name" => String.trim(to_string(R.field(f, "name") || "")),
      "kind" => R.field(f, "kind") || "openai_compatible",
      "base_url" => String.trim(to_string(R.field(f, "base_url") || "")),
      "models" => [],
      "default_model" => blank_nil(R.field(f, "default_model")),
      "fallbacks" => R.field(f, "kind") == "anthropic",
      "effort_levels" => levels
    }

    [
      {:command, "provider.create", nil, attrs,
       %{
         secrets_from: {:draft, @kind},
         write_key: {:record, @kind, @draft, :create},
         undo: false,
         toast: "Added #{attrs["name"]}",
         after:
           {:open_record, :providers, @kind, then: [{:task, "provider.test", :record_id, %{}}]}
       }}
    ]
  end

  defp preset_levels(_ctx, nil), do: nil
  defp preset_levels(_ctx, %{effort_preset: nil}), do: nil

  defp preset_levels(ctx, %{effort_preset: pid}) do
    ctx
    |> R.items("effort_presets")
    |> Enum.find(&(R.record_id(&1) == pid))
    |> case do
      nil -> nil
      rec -> R.field(R.fields(rec), "levels")
    end
  end

  defp blank_nil(nil), do: nil

  defp blank_nil(v),
    do: if(String.trim(to_string(v)) == "", do: nil, else: String.trim(to_string(v)))

  defp blank(nil, word), do: word
  defp blank("", word), do: word
  defp blank(v, _word), do: v

  # ----------------------------------------------------------------- commit

  @doc """
  A committed editor value (§3.7.6): a record field writes `provider.update` with CAS on
  the value read; a draft field goes into the draft; a picked preset starts a draft; a
  replacement is staged; a kind change asks first (§4.8).
  """
  def commit(ctx, row, value) do
    case Map.get(row, :target) do
      {:field, id, "kind", old} when value != old ->
        kind_change_ops(ctx, id, old, value)

      {:field, _id, _field, old} when value == old ->
        []

      {:field, id, field, old} ->
        [
          field_command(
            id,
            field,
            normalize(field, value),
            old,
            "#{label(field)} → #{display(value)}"
          )
        ]

      {:draft_field, field} ->
        [{:draft_put, @kind, %{field => value}}]

      {:replacement, id, key} ->
        [{:stage, {@kind, id}, %{"replacements" => Map.put(replacements(ctx, id), key, value)}}]

      {:model_item, id, index, _m} ->
        models_ops(
          ctx,
          id,
          &List.replace_at(&1, index, String.trim(to_string(value))),
          "Renamed a model"
        )

      {:model_add, id} ->
        add_model_ops(ctx, id, value)

      _ ->
        if Map.get(row, :id) == "picker:provider.preset", do: start_draft(value), else: :default
    end
  end

  @doc "Ops that open a draft from a preset id (the preset picker's `on_pick`)."
  def start_draft(preset_id) do
    case Enum.find(@presets, &(&1.id == preset_id)) do
      nil ->
        []

      p ->
        [
          {:draft_discard, @kind},
          {:draft_put, @kind,
           %{
             "preset" => p.id,
             "name" => p.name,
             "kind" => p.kind,
             "base_url" => p.base_url,
             "default_model" => nil
           }},
          {:open, R.new_page(:providers, {@kind, @draft})}
        ]
    end
  end

  defp add_model_ops(ctx, id, value) do
    model = String.trim(to_string(value || ""))
    old = R.field(provider(ctx, id) || %{}, "models") || []

    cond do
      model == "" -> [{:toast, "can't be blank", :error}]
      model in old -> [{:toast, "already in the list", :error}]
      length(old) >= 2_000 -> [{:toast, "2 000 models at most", :error}]
      true -> [field_command(id, "models", old ++ [model], old, "Added #{model}")]
    end
  end

  defp kind_change_ops(ctx, id, old, value) do
    name = provider_name(ctx, id)

    [
      {:confirm,
       R.confirm(
         id: "provider.kind",
         title: "Switch #{name} to #{ModelPicker.kind_label(value)}?",
         lines: [
           "The effort levels go back to the built-in ones for #{ModelPicker.kind_label(value)}."
         ],
         safe: "Cancel",
         danger: "Switch",
         letter: "S",
         opener: "fld:provider:#{id}:kind"
       ),
       then: [field_command(id, "kind", value, old, "Kind → #{ModelPicker.kind_label(value)}")]}
    ]
  end

  defp field_command(id, field, value, old, toast) do
    {:command, "provider.update", %{"id" => id}, %{field => value},
     %{
       expected: %{"fields" => %{field => old}},
       write_key: {:record, @kind, id, field},
       undo:
         {:command, "provider.update", %{"id" => id}, %{field => old},
          %{expected: %{"fields" => %{field => value}}}},
       toast: toast
     }}
  end

  defp normalize("default_model", %{} = pair), do: R.field(pair, "model")

  defp normalize("base_url", v) when is_binary(v),
    do: v |> String.trim() |> String.trim_trailing("/")

  defp normalize("name", v) when is_binary(v), do: String.trim(v)
  defp normalize(_field, v), do: v

  defp label("base_url"), do: "Base URL"
  defp label("default_model"), do: "Default model"
  defp label("fallbacks"), do: "Fallback on a refusal"
  defp label(field), do: String.capitalize(field)

  defp display(nil), do: "none"
  defp display(true), do: "on"
  defp display(false), do: "off"
  defp display(%{"model" => m}), do: m
  defp display(v), do: to_string(v)
end
