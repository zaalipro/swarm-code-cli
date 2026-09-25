defmodule SwarmCodeCLI.UI.Settings.Search do
  @moduledoc """
  The settings search (spec §3.7.11). Pure.

  The index has one entry per registry entry and per section, one per
  loaded record (providers, search providers, MCP servers, pricing rows,
  library items…), one per provider model and per MCP tool of a loaded
  record; at most 8 000 entries. Secret values and MCP env/header values
  are never indexed.

  Matching is case-insensitive, words AND, each word a prefix of a word in
  any field. `@filters` narrow first (`@modified @env @flag @session
  @project @cli @shared @secret @attention @restart @new @section:<id>
  @key:<prefix>`). Ranking: exact key > label prefix > label word >
  synonym > key word > description > value > model/tool item > fuzzy (a
  subsequence of the label or key); ties in rail order, then page order.
  """

  alias SwarmCode.Settings.{Entry, Registry}
  alias SwarmCodeCLI.UI.Settings.{Ctx, DeepLink, Display, Rows, Sections}

  @max_entries 8_000
  @ranks [
    :exact_key,
    :label_prefix,
    :label_word,
    :synonym,
    :key_word,
    :description,
    :value,
    :item,
    :fuzzy
  ]
  @filters ~w(modified env flag session project file cli shared secret attention restart new)

  @type entry :: %{
          id: String.t(),
          kind: :key | :section | :record | :item,
          section: atom(),
          label: String.t(),
          key: String.t() | nil,
          target: term(),
          order: {non_neg_integer(), non_neg_integer()},
          fields: map()
        }

  @doc "The ranks in order (best first)."
  def ranks, do: @ranks

  @doc "The largest index."
  def max_entries, do: @max_entries

  @doc "The index for the layer's data (rebuilt when the data changes, not per keystroke)."
  @spec index(Ctx.t()) :: [entry()]
  def index(%Ctx{} = ctx) do
    order = Sections.order()

    keys =
      Registry.all()
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        key_entry(ctx, entry, {Map.get(order, entry.section, 99), index})
      end)

    sections =
      Enum.map(Sections.ids(), fn id ->
        %{
          id: "section:#{id}",
          kind: :section,
          section: id,
          label: Sections.title(id),
          key: nil,
          target: {:section, id},
          order: {Map.get(order, id, 99), -1},
          fields: %{label: Sections.title(id), key: Atom.to_string(id)}
        }
      end)

    records = records(ctx, order)

    (sections ++ keys ++ records)
    |> Enum.take(@max_entries)
    |> Enum.map(&tokenize/1)
  end

  # Each field lowercased once, with its words, so a query never re-splits.
  defp tokenize(%{fields: fields} = entry) do
    tokens =
      Map.new(fields, fn {name, text} ->
        lower = String.downcase(text || "")
        {name, [lower | String.split(lower, ~r/[^\p{L}\p{N}]+/u, trim: true)]}
      end)

    entry
    |> Map.put(:tokens, tokens)
    |> Map.put(
      :all,
      " " <> (tokens |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.join(" "))
    )
    |> Map.put(:lower_label, String.downcase(entry.label))
  end

  defp key_entry(ctx, %Entry{} = entry, order) do
    setting = Rows.setting(ctx, entry)

    value =
      cond do
        entry.secret ->
          ""

        setting == nil ->
          ""

        true ->
          entry
          |> Display.value(Map.get(setting, :value), setting, %{})
          |> Enum.map_join("", &elem(&1, 0))
      end

    %{
      id: "key:" <> entry.key,
      kind: :key,
      section: entry.section,
      label: entry.label,
      key: entry.key,
      target: {:key, entry.key},
      order: order,
      fields: %{
        label: entry.label,
        key: entry.key,
        stored: entry.stored_name || "",
        synonyms: Enum.join(entry.synonyms || [], " "),
        description: entry.description || "",
        value: value
      },
      entry: entry,
      setting: setting
    }
  end

  # Loaded records and their models (providers) and tools (MCP servers).
  defp records(%Ctx{data: %{records: records}}, order) when is_map(records) do
    records
    |> Enum.sort_by(fn {_key, page} -> Map.get(page, :loaded_at, 0) end, :desc)
    |> Enum.flat_map(fn {{_query_kind, _options}, page} -> Map.get(page, :items) || [] end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {record, index} -> record_entries(record, index, order) end)
  end

  defp records(_ctx, _order), do: []

  defp record_entries(record, index, order) do
    kind = Map.get(record, :kind)
    id = Map.get(record, :id)
    fields = Map.get(record, :fields) || %{}
    name = text(Map.get(fields, "name") || id)
    section = DeepLink.record_section(to_string(kind)) || :overview
    rail = Map.get(order, section, 99)

    base = %{
      id: "rec:#{kind}:#{id}",
      kind: :record,
      section: section,
      label: name,
      key: nil,
      target: {:record, kind, id},
      order: {rail, 10_000 + index},
      fields: %{label: name, key: text(id), description: text(Map.get(fields, "kind") || "")}
    }

    items =
      for {field, what} <- [{"models", :model}, {"tools", :tool}],
          item <- List.wrap(Map.get(fields, field)),
          item_name = item_name(item),
          is_binary(item_name) do
        %{
          id: "item:#{kind}:#{id}:#{item_name}",
          kind: :item,
          section: section,
          label: "#{item_name} · #{name}",
          key: nil,
          target: {:record, kind, id, {what, item_name}},
          order: {rail, 20_000 + index},
          fields: %{item: item_name}
        }
      end

    if is_nil(kind) or is_nil(id), do: [], else: [base | items]
  end

  defp item_name(name) when is_binary(name), do: name
  defp item_name(%{"name" => name}) when is_binary(name), do: name
  defp item_name(%{"id" => id}) when is_binary(id), do: id
  defp item_name(%{name: name}) when is_binary(name), do: name
  defp item_name(_item), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""
  defp text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp text(_value), do: ""

  # --------------------------------------------------------------- query

  @doc """
  The matches of `query` in `index`, best first: `%{results: [{rank,
  entry}], fuzzy?: boolean, filters: [..]}`.
  """
  @spec run([entry()], String.t(), Ctx.t() | nil) :: map()
  def run(index, query, ctx \\ nil) do
    {filters, words} = parse(query)
    candidates = Enum.filter(index, &filtered?(&1, filters, ctx))

    ranked =
      for entry <- candidates, rank = rank(entry, words), rank != nil, do: {rank, entry}

    {results, fuzzy?} =
      cond do
        ranked != [] or words == [] -> {ranked, false}
        true -> {fuzzy(candidates, words), true}
      end

    results =
      Enum.sort_by(results, fn {rank, entry} -> {rank_index(rank), entry.order} end)

    %{results: results, fuzzy?: fuzzy?, filters: filters, words: words}
  end

  @doc "`@filters` and the words of a query."
  @spec parse(String.t()) :: {[term()], [String.t()]}
  def parse(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.reduce({[], []}, fn
      "@section:" <> id, {filters, words} ->
        {[{:section, id} | filters], words}

      "@key:" <> prefix, {filters, words} ->
        {[{:key, prefix} | filters], words}

      "@" <> name, {filters, words} when name in @filters ->
        {[filter_atom(name) | filters], words}

      word, {filters, words} ->
        {filters, [word | words]}
    end)
    |> then(fn {filters, words} -> {Enum.reverse(filters), Enum.reverse(words)} end)
  end

  @filter_atoms %{
    "modified" => :modified,
    "env" => :env,
    "flag" => :flag,
    "session" => :session,
    "project" => :project,
    "file" => :file,
    "cli" => :cli,
    "shared" => :shared,
    "secret" => :secret,
    "attention" => :attention,
    "restart" => :restart,
    "new" => :new
  }
  defp filter_atom(name), do: Map.fetch!(@filter_atoms, name)

  defp filtered?(_entry, [], _ctx), do: true
  defp filtered?(entry, filters, ctx), do: Enum.all?(filters, &filter?(entry, &1, ctx))

  defp filter?(%{section: section}, {:section, id}, _ctx),
    do: Atom.to_string(section) == id or String.downcase(Sections.title(section)) =~ id

  defp filter?(%{key: key}, {:key, prefix}, _ctx) when is_binary(key),
    do: String.starts_with?(key, prefix)

  # A value changed from its default (a read-only fact is not a value one
  # changes; the Overview counts the same set).
  defp filter?(%{kind: :key, entry: %{type: type}}, :modified, _ctx)
       when type in [:fact, :action, :link],
       do: false

  defp filter?(%{kind: :key, setting: setting}, :modified, _ctx),
    do: winner(setting) not in [nil, :default]

  defp filter?(%{kind: :key, setting: setting}, layer, _ctx) when layer in [:env, :flag],
    do: winner(setting) == layer

  defp filter?(%{kind: :key, entry: entry}, scope, _ctx) when scope in [:session, :project, :cli],
    do: entry.scope == scope

  defp filter?(%{kind: :key, entry: entry}, :file, _ctx), do: entry.scope == :project_file
  defp filter?(%{kind: :key, entry: entry}, :shared, _ctx), do: entry.shared
  defp filter?(%{kind: :key, entry: entry}, :secret, _ctx), do: entry.secret

  defp filter?(%{kind: :key, entry: entry}, :restart, _ctx),
    do: entry.applies in [:restart, :next_launch]

  defp filter?(%{kind: :key, entry: entry}, :new, _ctx), do: entry.since == :c74

  defp filter?(%{kind: :key, setting: setting}, :attention, _ctx),
    do:
      is_map(setting) and
        Map.get(setting, :state) in [:attention, :invalid, "attention", "invalid"]

  defp filter?(_entry, _filter, _ctx), do: false

  defp winner(%{} = setting), do: Map.get(setting, :winner)
  defp winner(_setting), do: nil

  defp rank(_entry, []), do: :label_word

  defp rank(entry, words) do
    all = entry.all

    # A word is a prefix of some token when " word" occurs in the joined
    # tokens (a C-level binary search, no list walk per keystroke).
    if Enum.all?(words, &(:binary.match(all, " " <> &1) != :nomatch)) do
      best(entry, words)
    end
  end

  defp best(entry, words) do
    query = Enum.join(words, " ")
    tokens = entry.tokens

    cond do
      entry.key != nil and String.downcase(entry.key) == query -> :exact_key
      String.starts_with?(entry.lower_label, query) -> :label_prefix
      all_in?(tokens, :label, words) -> :label_word
      all_in?(tokens, :synonyms, words) -> :synonym
      all_in?(tokens, :key, words) -> :key_word
      all_in?(tokens, :description, words) -> :description
      all_in?(tokens, :value, words) -> :value
      entry.kind == :item -> :item
      true -> :description
    end
  end

  defp all_in?(tokens, field, words) do
    case Map.get(tokens, field) do
      nil -> false
      list -> Enum.all?(words, fn word -> Enum.any?(list, &String.starts_with?(&1, word)) end)
    end
  end

  # Nothing matched: a subsequence of the label or the key.
  defp fuzzy(entries, words) do
    needle = Enum.join(words)

    for entry <- entries,
        entry.kind in [:key, :section],
        subsequence?(String.downcase(entry.label), needle) or
          subsequence?(String.downcase(entry.key || ""), needle),
        do: {:fuzzy, entry}
  end

  defp subsequence?(_text, ""), do: true
  defp subsequence?("", _needle), do: false

  defp subsequence?(<<c::utf8, text::binary>>, <<c::utf8, needle::binary>>),
    do: subsequence?(text, needle)

  defp subsequence?(<<_c::utf8, text::binary>>, needle), do: subsequence?(text, needle)
  defp subsequence?(_text, _needle), do: false

  defp rank_index(rank), do: Enum.find_index(@ranks, &(&1 == rank)) || length(@ranks)

  @doc "The `@filters` a query may use (for Tab completion)."
  def filters, do: Enum.map(@filters, &("@" <> &1)) ++ ["@section:", "@key:"]

  @doc """
  The results as page rows: grouped by section in rail order with counts;
  keys are real rows (editable in place), records, items and sections are
  link rows. Empty: the words, the closest keys and the hint.
  """
  @spec rows(Ctx.t(), map(), String.t()) :: [SwarmCodeCLI.UI.Settings.Row.t()]
  def rows(%Ctx{}, %{results: [], words: words}, query) do
    alias SwarmCodeCLI.UI.Settings.Row
    closest = if words == [], do: [], else: closest(Enum.join(words, "."))

    links =
      Enum.map(closest, fn key ->
        %Row{
          id: "key:" <> key,
          kind: :link,
          key: key,
          label: key,
          value: [{"▸ open", :text_muted}],
          target: {:search_result, {:key, key}}
        }
      end)

    [Row.info("nothing", "Nothing matches “#{query}”.")] ++
      links ++ [Row.info("try", "Try @modified, @env, or a key such as limits.command_timeout.")]
  end

  def rows(%Ctx{} = ctx, %{results: results, fuzzy?: fuzzy?}, _query) do
    alias SwarmCodeCLI.UI.Settings.Row

    groups =
      results
      |> Enum.map(&elem(&1, 1))
      |> Enum.group_by(& &1.section)
      |> Enum.sort_by(fn {section, _} -> Map.get(Sections.order(), section, 99) end)

    head = if fuzzy?, do: [Row.heading("close matches")], else: []

    head ++
      Enum.flat_map(groups, fn {section, entries} ->
        [
          Row.heading(Sections.title(section), [{"#{length(entries)}", :text_faint}])
          | Enum.map(entries, &result_row(ctx, &1))
        ]
      end)
  end

  defp result_row(ctx, %{kind: :key, entry: entry}),
    do: %{Rows.scalar(ctx, entry) | indent: 0}

  defp result_row(_ctx, entry) do
    alias SwarmCodeCLI.UI.Settings.Row

    %Row{
      id: entry.id,
      kind: :link,
      label: entry.label,
      value: [{"▸ open", :text_muted}],
      keys: [{"Enter", :enter, "open"}, {"g", :goto, "go to its section"}],
      target: {:search_result, entry.target}
    }
  end

  @doc "What the index was built from: rebuilt only when this changes."
  @spec index_key(Ctx.t()) :: term()
  def index_key(%Ctx{data: data, prefs: prefs}) do
    records =
      if data,
        do: Enum.map(data.records, fn {key, page} -> {key, Map.get(page, :loaded_at)} end),
        else: []

    {data && data.revision, data && MapSet.size(data.values_loaded), records,
     :erlang.phash2(prefs)}
  end

  @doc "Up to three registry keys closest to `word` (edit distance), for the empty page."
  @spec closest(String.t()) :: [String.t()]
  def closest(word) do
    Registry.all()
    |> Enum.map(&{String.jaro_distance(&1.key, word), &1.key})
    |> Enum.sort(:desc)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 1))
  end
end
