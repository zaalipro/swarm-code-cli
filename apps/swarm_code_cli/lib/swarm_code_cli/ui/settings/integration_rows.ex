defmodule SwarmCodeCLI.UI.Settings.IntegrationRows do
  @moduledoc """
  Shared, pure helpers of the integration sections (U2): reading the layer's data out of a
  section context, building rows and the words every integration page uses (secrets, times,
  sizes, task states).

  Every accessor tolerates a context that lacks the key (`Map.get` defaults), so a section
  renders an honest empty or loading page instead of crashing when data has not arrived.
  """

  @type ctx :: map()
  @type segment :: {String.t(), atom()}

  # ------------------------------------------------------------ the context

  @doc "The settings layer the context was built from (`%Layer{}` or a map), or `%{}`."
  def layer(ctx) do
    Map.get(ctx, :layer) || get_in_map(ctx, [:state_view, :settings]) || %{}
  end

  @doc "The page on screen (`%Page{}`: `section`, `record`, `sub`), or a section page map."
  def current_page(ctx) do
    Map.get(ctx, :page) ||
      case Map.get(layer(ctx), :stack) do
        [page | _] -> page
        _ -> %{section: nil, record: nil, sub: nil, cursor: nil, scroll: 0}
      end
  end

  @doc "The record the page shows, `{kind, id}`, or nil."
  def page_record(ctx), do: Map.get(current_page(ctx), :record)

  @doc "The sub-page the page shows, or nil."
  def page_sub(ctx), do: Map.get(current_page(ctx), :sub)

  @doc "A page (§3.7.1 `%Page{}` fields) for an `{:open, page}` op."
  def new_page(section, record \\ nil, sub \\ nil),
    do: %{section: section, record: record, sub: sub, cursor: nil, scroll: 0}

  @doc "A detail (§3.7.2 `%Detail{}` fields)."
  def detail(attrs) do
    Map.merge(
      %{
        title: "",
        scope: nil,
        key_line: nil,
        description: "",
        facts: [],
        layers: [],
        checks: [],
        results: [],
        actions: [],
        notes: []
      },
      Map.new(attrs)
    )
  end

  @doc "A confirmation (§3.7.2 `%Confirm{}` fields)."
  def confirm(attrs) do
    Map.merge(
      %{
        id: nil,
        title: "",
        lines: [],
        safe: "Cancel",
        danger: "",
        letter: nil,
        undoable?: true,
        typed: nil,
        counting?: false,
        focus: :safe,
        input: "",
        opener: nil
      },
      Map.new(attrs)
    )
  end

  @doc "A picker (§3.7.8 `%Picker{}` fields)."
  def picker(attrs) do
    Map.merge(
      %{
        id: nil,
        title: "",
        options: [],
        cursor: 0,
        query: "",
        current: nil,
        on_pick: nil,
        opener: nil,
        filter?: true
      },
      Map.new(attrs)
    )
  end

  @doc "The layer's data (`%Data{}`), or `%{}`."
  def data(ctx), do: Map.get(ctx, :data) || Map.get(layer(ctx), :data) || %{}

  @doc "The page project's id: the picker choice, else the session's project."
  def project_id(ctx) do
    Map.get(layer(ctx), :page_project_id) || Map.get(ctx, :page_project_id) ||
      project_field(Map.get(ctx, :project), "id")
  end

  @doc "A project record's fields by id, from `records:projects`."
  def project(ctx, id) do
    ctx
    |> items("projects")
    |> Enum.find(&(field(&1, "id") == id or record_id(&1) == id))
    |> case do
      nil ->
        if project_field(Map.get(ctx, :project), "id") == id,
          do: Map.get(ctx, :project),
          else: nil

      rec ->
        rec
    end
  end

  @doc "The page project's name (`this project` when unknown)."
  def project_name(ctx) do
    case project(ctx, project_id(ctx)) do
      nil -> "this project"
      p -> field(p, "name") || project_field(p, "name") || "this project"
    end
  end

  defp project_field(nil, _), do: nil
  defp project_field(p, key), do: field(p, key)

  @doc "The loaded page of `kind` (any options when `options` is nil), or nil."
  def records_page(ctx, kind, options \\ nil) do
    records = Map.get(data(ctx), :records) || %{}

    exact = if options, do: Map.get(records, {kind, options}) || Map.get(records, kind)

    exact ||
      Enum.find_value(records, fn
        {{^kind, _opts}, page} -> page
        {^kind, page} -> page
        _ -> nil
      end)
  end

  @doc "The loaded items of `kind` (records), `[]` before they arrive."
  def items(ctx, kind, options \\ nil) do
    case records_page(ctx, kind, options) do
      nil -> []
      page -> Map.get(page, :items) || Map.get(page, "items") || []
    end
  end

  @doc "Whether a page of `kind` has arrived."
  def loaded?(ctx, kind, options \\ nil), do: records_page(ctx, kind, options) != nil

  @doc "The total of a record page (its own count when the page has none)."
  def total(ctx, kind, options \\ nil) do
    case records_page(ctx, kind, options) do
      nil -> nil
      page -> Map.get(page, :total) || Map.get(page, "total") || length(items(ctx, kind, options))
    end
  end

  @doc "A loaded single record (`record` view) by kind and id, or nil."
  def record(ctx, kind, id) do
    single = Map.get(data(ctx), :record) || %{}
    Map.get(single, {kind, id}) || Enum.find(items(ctx, plural(kind)), &(record_id(&1) == id))
  end

  @doc "A loaded file (`file` view) by ref, or nil."
  def file(ctx, ref) do
    files = Map.get(data(ctx), :files) || %{}
    Map.get(files, ref)
  end

  @doc "A setting value (`SettingValue`) by key, or nil."
  def value(ctx, key) do
    values = Map.get(data(ctx), :values) || %{}
    Map.get(values, key)
  end

  @doc "The effective wire value of a setting, `default` when not loaded."
  def value_of(ctx, key, default \\ nil) do
    case value(ctx, key) do
      nil -> default
      v -> field(v, "value")
    end
  end

  @doc "The layer's task map (`task_id => task`)."
  def tasks(ctx), do: Map.get(layer(ctx), :tasks) || Map.get(ctx, :tasks) || %{}

  @doc """
  The newest task of `action` whose target matches `target` (a map of the keys to match, or
  nil for any), as `{task_id, task}`, or nil.
  """
  def task(ctx, action, target \\ nil) do
    ctx
    |> tasks()
    |> Enum.filter(fn {_id, t} ->
      field(t, "action") == action and target_matches?(field(t, "target"), target)
    end)
    |> Enum.max_by(fn {_id, t} -> field(t, "received_at_ms") || 0 end, fn -> nil end)
  end

  defp target_matches?(_actual, nil), do: true

  defp target_matches?(actual, wanted) when is_map(actual) do
    Enum.all?(wanted, fn {k, v} -> field(actual, to_string(k)) == v end)
  end

  defp target_matches?(_actual, _wanted), do: false

  @doc "The rows of a finished task's result (`view=task`), `[]` until they arrive."
  def task_rows(ctx, task_id) do
    views = Map.get(data(ctx), :task_views) || %{}

    case Map.get(views, task_id) do
      nil ->
        case get_in_map(tasks(ctx), [task_id]) do
          nil -> []
          t -> rows_of(field(t, "result"))
        end

      view ->
        pages = Map.get(view, :pages) || Map.get(view, "pages") || %{}

        pages
        |> Enum.sort_by(fn {cursor, _} -> cursor_order(cursor) end)
        |> Enum.flat_map(&elem(&1, 1))
    end
  end

  defp rows_of(%{} = result), do: field(result, "rows") || []
  defp rows_of(_), do: []

  defp cursor_order(nil), do: -1

  defp cursor_order(c) when is_binary(c) do
    case Integer.parse(c) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp cursor_order(_), do: 0

  @doc "A finished task's summary (from the delta or the task view), or nil."
  def task_summary(ctx, task_id) do
    views = Map.get(data(ctx), :task_views) || %{}

    case Map.get(views, task_id) do
      nil ->
        tasks(ctx) |> Map.get(task_id) |> then(&(&1 && field(&1, "summary")))

      view ->
        field(view, "summary") ||
          tasks(ctx) |> Map.get(task_id) |> then(&(&1 && field(&1, "summary")))
    end
  end

  @doc "A draft's fields (`%{field => value}`)."
  def draft_fields(nil), do: %{}
  def draft_fields(draft), do: Map.get(draft, :fields) || Map.get(draft, "fields") || %{}

  @doc "A draft's field errors (`%{field => message}`)."
  def draft_errors(nil), do: %{}
  def draft_errors(draft), do: Map.get(draft, :errors) || Map.get(draft, "errors") || %{}

  @doc "Whether a draft holds a pasted secret for `slot`."
  def draft_secret?(nil, _slot), do: false

  def draft_secret?(draft, slot) do
    secrets = Map.get(draft, :secrets) || Map.get(draft, "secrets") || %{}
    Map.has_key?(secrets, slot)
  end

  @doc "The draft of `kind` (§3.7.10) or nil."
  def draft(ctx, kind), do: layer(ctx) |> Map.get(:drafts, %{}) |> Map.get(kind)

  @doc "The staged fields of a record (D8), `%{}` when none."
  def staged(ctx, kind, id), do: layer(ctx) |> Map.get(:staged, %{}) |> Map.get({kind, id}, %{})

  @doc "The error shown under a row, or nil."
  def row_error(ctx, row_id), do: layer(ctx) |> Map.get(:row_errors, %{}) |> Map.get(row_id)

  @doc "The in-page filter query when it applies to `page_ref`, else nil."
  def filter(ctx, page_ref) do
    case Map.get(layer(ctx), :filter) do
      %{page_ref: ^page_ref, query: q} -> q
      %{"page_ref" => ^page_ref, "query" => q} -> q
      _ -> nil
    end
  end

  @doc "The clock the reducer passed in (ms), 0 when absent."
  def now(ctx), do: Map.get(ctx, :now) || 0

  @doc "The glyph tier: `:rich`, `:measured` or `:ascii`."
  def tier(ctx) do
    caps = Map.get(ctx, :caps) || %{}
    Map.get(caps, :glyph_tier) || :rich
  end

  @doc "The effective external editor's name (`terminal.editor` > VISUAL > EDITOR > vi)."
  def editor_name(ctx) do
    prefs = Map.get(ctx, :prefs) || %{}
    facts = Map.get(ctx, :launch_facts) || %{}
    env = Map.get(facts, :env) || Map.get(facts, "env") || %{}

    (Map.get(prefs, "editor") || Map.get(env, "VISUAL") || Map.get(env, "EDITOR") || "vi")
    |> to_string()
    |> String.split()
    |> List.first()
    |> Path.basename()
  end

  # --------------------------------------------------------------- records

  @doc "A record's id (`DTO.SettingsRecord` or a wire map)."
  def record_id(%{id: id}), do: id
  def record_id(%{"id" => id}), do: id
  def record_id(_), do: nil

  @doc "A record's fields map (string keys), `%{}` when it has none."
  def fields(%{fields: f}) when is_map(f), do: f
  def fields(%{"fields" => f}) when is_map(f), do: f
  def fields(other) when is_map(other), do: other
  def fields(_), do: %{}

  @doc "One field of a record, a map, or a struct, by its string name (atom keys too)."
  def field(nil, _key), do: nil

  def field(%{fields: f}, key) when is_map(f), do: field(f, key)
  def field(%{"fields" => f}, key) when is_map(f), do: field(f, key)

  def field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, atom(key))
    end
  end

  def field(_, _), do: nil

  @atoms Map.new(
           ~w(id name kind value state action target result summary rows received_at_ms elapsed_ms
              message progress done total step bytes items fields set hint at count ms status
              provider_id model options project_id title root errors secrets env
              cancellable),
           &{&1, String.to_atom(&1)}
         )
  defp atom(key) when is_binary(key), do: Map.get(@atoms, key, key)
  defp atom(key), do: key

  defp get_in_map(nil, _), do: nil
  defp get_in_map(value, []), do: value
  defp get_in_map(map, [k | rest]) when is_map(map), do: get_in_map(Map.get(map, k), rest)
  defp get_in_map(_, _), do: nil

  defp plural("provider"), do: "providers"
  defp plural("search_provider"), do: "search_providers"
  defp plural("mcp_server"), do: "mcp_servers"
  defp plural("pricing_row"), do: "pricing_rows"
  defp plural(other), do: other <> "s"

  # ------------------------------------------------------------------- rows

  @row_keys [
    :id,
    :kind,
    :key,
    :label,
    :value,
    :tag,
    :marks,
    :lines,
    :editor,
    :keys,
    :detail,
    :state,
    :columns,
    :target,
    :indent
  ]

  @doc """
  A page row (§3.7.2 `%Row{}` fields). Missing fields get the Row defaults: `value: []`,
  `tag: []`, `marks: []`, `lines: []`, `keys: []`, `state: :normal`.
  """
  def row(attrs) do
    attrs = Map.new(attrs)

    base = %{
      id: nil,
      kind: :info,
      key: nil,
      label: "",
      value: [],
      tag: [],
      marks: [],
      lines: [],
      editor: nil,
      keys: [],
      detail: nil,
      state: :normal,
      columns: nil,
      target: nil,
      indent: 0
    }

    Map.merge(base, Map.take(attrs, @row_keys))
  end

  @doc "A group heading row."
  def heading(id, label, tag \\ []),
    do: row(id: "head:#{id}", kind: :heading, label: label, tag: tag)

  @doc "An info row (one line of words, not focusable for editing)."
  def info(id, text, role \\ :text_muted),
    do: row(id: "info:#{id}", kind: :info, label: "", value: [{text, role}], state: :readonly)

  @doc "A text segment."
  def seg(text, role \\ :text_primary), do: {text, role}

  # ------------------------------------------------------------------ words

  @doc "The secret display of §4.1 item 3."
  def secret_words(secret, tier \\ :rich)

  def secret_words(secret, tier) do
    set = field(secret, "set") == true
    hint = field(secret, "hint")
    dots = if tier == :ascii, do: "********", else: "●●●●●●●●"

    cond do
      set and is_binary(hint) -> [{dots, :text_muted}, {" set · ends #{hint}", :text_primary}]
      set -> [{dots, :text_muted}, {" set", :text_primary}]
      true -> [{"not set", :text_ghost}]
    end
  end

  @doc "Bytes in words: `412 MB`, `1.8 GB`, `96 KB`, `512 B`."
  def bytes(nil), do: "—"

  def bytes(n) when is_integer(n) and n >= 1_000_000_000,
    do: "#{:erlang.float_to_binary(n / 1_000_000_000, decimals: 1)} GB"

  def bytes(n) when is_integer(n) and n >= 1_000_000, do: "#{div(n, 1_000_000)} MB"
  def bytes(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)} KB"
  def bytes(n) when is_integer(n), do: "#{n} B"
  def bytes(n) when is_float(n), do: bytes(round(n))
  def bytes(_), do: "—"

  @doc "`HH:MM` of an ISO-8601 stamp (the time part as written), or nil."
  def hhmm(nil), do: nil

  def hhmm(iso) when is_binary(iso) do
    case Regex.run(~r/T(\d{2}):(\d{2})/, iso) do
      [_, h, m] -> "#{h}:#{m}"
      _ -> nil
    end
  end

  def hhmm(_), do: nil

  @doc "A count with a noun: `1 model`, `3 models`."
  def count(1, noun), do: "1 #{noun}"
  def count(n, noun), do: "#{n} #{noun}s"

  @doc "Context window in words: `128k`, `1M`, `family default`."
  def context(nil), do: "family default"

  def context(n) when is_integer(n) and n >= 1_000_000 and rem(n, 1_000_000) == 0,
    do: "#{div(n, 1_000_000)}M"

  def context(n) when is_integer(n) and n >= 1_000, do: "#{div(n, 1_000)}k"
  def context(n), do: to_string(n)

  @doc "A money amount per million tokens: `0.27`, `15.00`; below 0.10 up to three decimals (`0.007`)."
  def money(nil), do: "—"

  def money(n) when is_number(n) and n >= 0.1, do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  def money(n) when is_number(n) do
    three = :erlang.float_to_binary(n * 1.0, decimals: 3) |> String.trim_trailing("0")
    if String.ends_with?(three, "."), do: three <> "00", else: pad_two(three)
  end

  def money(_), do: "—"

  defp pad_two(text) do
    case String.split(text, ".") do
      [int, dec] when byte_size(dec) < 2 -> int <> "." <> String.pad_trailing(dec, 2, "0")
      _ -> text
    end
  end

  @doc """
  The words of a task row (§4.9): `{segments, tag_segments}` for a running, done, failed,
  timed out or cancelled task. `start` and `success` are the action's words; `success` is
  a function of the summary.
  """
  def task_words(ctx, {_id, task}, start, success) do
    state = to_string(field(task, "state"))
    elapsed = elapsed_s(ctx, task)
    at = hhmm(field(task, "at")) || clock(ctx)

    case state do
      "running" ->
        progress = field(task, "progress")
        words = progress_words(start, progress)
        still = if field(task, "message"), do: " · #{field(task, "message")}", else: ""

        cancel =
          if field(task, "cancellable") == false,
            do: [{"can't be stopped", :text_faint}],
            else: [{"c", :key}, {" stop", :text_faint}]

        {[{glyph(ctx, :running) <> " ", :info}, {"#{words} · #{elapsed} s#{still}", :text_muted}],
         cancel}

      "done" ->
        {[
           {glyph(ctx, :ok) <> " ", :success},
           {success.(field(task, "summary") || %{}) <> suffix(at), :text_muted}
         ], []}

      "failed" ->
        {[
           {glyph(ctx, :error) <> " ", :error},
           {to_string(field(task, "message") || "failed") <> suffix(at), :text_muted}
         ], []}

      "timeout" ->
        {[
           {glyph(ctx, :error) <> " ", :error},
           {to_string(field(task, "message") || "no answer") <> suffix(at), :text_muted}
         ], []}

      "cancelled" ->
        {[{"stopped" <> suffix(at), :text_muted}], []}

      _ ->
        {[], []}
    end
  end

  defp suffix(nil), do: ""
  defp suffix(at), do: " · #{at}"

  defp clock(ctx) do
    case Map.get(ctx, :clock) do
      nil -> nil
      text -> text
    end
  end

  defp progress_words(start, nil), do: start

  defp progress_words(start, progress) do
    done = field(progress, "done")
    total = field(progress, "total")
    step = field(progress, "step")

    cond do
      is_binary(step) and step != "" -> step
      is_integer(done) and is_integer(total) -> "#{start} · #{done} of #{total}"
      true -> start
    end
  end

  @doc "Whole seconds a task has run: the delta's `elapsed_ms` plus the local clock since it arrived."
  def elapsed_s(ctx, task) do
    base = field(task, "elapsed_ms") || 0
    received = field(task, "received_at_ms")
    extra = if is_integer(received) and now(ctx) > received, do: now(ctx) - received, else: 0
    div(base + extra, 1_000)
  end

  @doc "Whether the task is still running."
  def running?(nil), do: false
  def running?({_id, task}), do: to_string(field(task, "state")) == "running"

  @glyphs %{
    running: {"◷", "~"},
    ok: {"✓", "v"},
    error: {"✗", "x"},
    attention: {"!", "!"},
    changed: {"•", "*"},
    action: {"▸", ">"},
    dot: {"·", "-"},
    new: {"+", "+"},
    gone: {"−", "-"},
    arrow: {"→", "->"},
    ticked: {"[✓]", "[v]"},
    unticked: {"[ ]", "[ ]"},
    ellipsis: {"…", "..."}
  }

  @doc "A settings glyph in the context's tier (ASCII twins of §4.11)."
  def glyph(ctx, id) do
    {rich, ascii} = Map.fetch!(@glyphs, id)
    if tier(ctx) == :ascii, do: ascii, else: rich
  end

  @doc "`·` or its ASCII twin, with spaces."
  def dot(ctx), do: " #{glyph(ctx, :dot)} "
end
