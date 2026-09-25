defmodule SwarmCodeCLI.UI.Settings.Rows do
  @moduledoc """
  Rows built from the core registry (spec §3.7.5). `registry/2` is the default
  page of a section: every registry entry of the section grouped by `group`
  in registry order, one `scalar/2` row each.

  `scalar/2` reads the value from the layer's data (a daemon key's
  SettingValue) or composes it (`Provenance.cli_value/5` for a terminal
  key), then lays the row out: the value by type (§4.5), the winner's tag,
  the marks, the continuation lines (overrides, desktop-only, next launch,
  errors, conflicts), the editor by type and the detail (§4.6). While a
  write is in flight the row shows the value being written.
  """

  alias SwarmCode.Settings.{Entry, Registry}
  alias SwarmCodeCLI.UI.Settings.{Ctx, Detail, Display, Editors, Provenance, Row}

  @applies %{
    at_once: "at once",
    next_turn: "next turn",
    next_spawn: "next spawn",
    next_request: "next request",
    next_research: "next research",
    new_conversations: "new conversations",
    new_clients: "new clients",
    restart: "restart",
    next_launch: "next launch",
    desktop: "desktop"
  }

  # The value editors' byte bound for one-line text.
  @text_max 4_096

  @doc "Every registry entry of `section` as rows, with a heading per group."
  @spec registry(Ctx.t(), atom()) :: [Row.t()]
  def registry(%Ctx{} = ctx, section) do
    ctx
    |> entries(section)
    |> Enum.chunk_by(&Map.get(&1, :group))
    |> Enum.flat_map(fn [first | _] = group ->
      heading = if is_binary(Map.get(first, :group)), do: [Row.heading(first.group)], else: []
      heading ++ Enum.map(group, &scalar(ctx, &1))
    end)
  end

  @doc "The registry entries of `section`, in page order."
  @spec entries(Ctx.t(), atom()) :: [Entry.t()]
  def entries(_ctx, section), do: Registry.for_section(section)

  @doc "The words of an entry's `applies`."
  @spec applies_words(atom()) :: String.t()
  def applies_words(applies), do: Map.get(@applies, applies, to_string(applies))

  @doc """
  The SettingValue of `entry` as the layer knows it: a terminal key's is
  composed from cli.json and the launch; a daemon key's is the service's
  (nil until its section's values arrive).
  """
  @spec setting(Ctx.t(), Entry.t()) :: map() | nil
  def setting(%Ctx{} = ctx, %Entry{storage: {:cli, _}} = entry) do
    cli = (ctx.data && ctx.data.cli) || %{}
    invalid = Map.get(cli, :invalid, [])
    values = (ctx.data && ctx.data.values) || %{}
    Provenance.cli_value(entry, ctx.prefs || %{}, invalid, ctx.launch_facts || %{}, values)
  end

  def setting(%Ctx{data: %{values: values}}, %Entry{key: key}), do: Map.get(values, key)
  def setting(_ctx, _entry), do: nil

  @doc "The value a row shows: the one being written, else the effective one."
  @spec shown(Ctx.t(), Entry.t(), map() | nil) :: term()
  def shown(%Ctx{} = ctx, %Entry{} = entry, setting) do
    case {stepping(ctx, entry), write(ctx, entry)} do
      {{:ok, value}, _write} -> value
      {:error, %{value: value}} -> value
      {:error, nil} -> if setting, do: Map.get(setting, :value), else: nil
    end
  end

  defp stepping(%Ctx{layer: %{step: %{key: key, value: value}}}, %Entry{key: key}),
    do: {:ok, value}

  defp stepping(_ctx, _entry), do: :error

  @doc "One registry entry as a row."
  @spec scalar(Ctx.t(), Entry.t()) :: Row.t()
  def scalar(%Ctx{} = ctx, %Entry{} = entry) do
    setting = setting(ctx, entry)
    id = "key:" <> entry.key
    value = shown(ctx, entry, setting)
    loaded? = setting != nil or not Entry.scalar?(entry)
    write = write(ctx, entry)
    error = row_error(ctx, id)
    conflict = conflict(ctx, entry)

    %Row{
      id: id,
      kind: row_kind(entry),
      key: entry.key,
      label: entry.label,
      value: value_segments(ctx, entry, value, setting, loaded?),
      tag: tag(ctx, entry, setting, write),
      marks: marks(ctx, entry, setting, write, error, conflict),
      lines: lines(ctx, entry, setting, error, conflict),
      editor: if(loaded?, do: editor(ctx, entry, value, setting), else: nil),
      keys: keys(entry),
      detail: detail(ctx, entry, setting, value),
      state: state(entry, loaded?),
      target: {:entry, entry.key}
    }
  end

  defp row_kind(%Entry{type: :action}), do: :action
  defp row_kind(%Entry{type: :link}), do: :link
  defp row_kind(%Entry{type: :fact}), do: :info
  defp row_kind(%Entry{}), do: :setting

  defp state(%Entry{type: :fact}, _loaded?), do: :readonly
  defp state(%Entry{desktop_only: true}, true), do: :normal
  defp state(%Entry{}, false), do: :loading

  defp state(%Entry{} = entry, true) do
    if Entry.scalar?(entry) and not Entry.writable?(entry), do: :readonly, else: :normal
  end

  defp value_segments(_ctx, %Entry{} = entry, _value, _setting, false) do
    if Entry.scalar?(entry),
      do: [{"…", :text_ghost}],
      else: [{"▸ " <> entry.label, :text_primary}]
  end

  defp value_segments(ctx, entry, value, setting, true),
    do: Display.value(entry, value, setting, lookups(ctx))

  @doc "What value display looks up: provider names (when loaded) and the home directory."
  @spec lookups(Ctx.t()) :: map()
  def lookups(%Ctx{} = ctx) do
    providers =
      case ctx.data && provider_pages(ctx.data.records) do
        [] -> nil
        nil -> nil
        items -> Map.new(items, &{get(&1, :id), get(&1, :name) || get(&1, :id)})
      end

    %{providers: providers, home: get(ctx.launch_facts || %{}, :home)}
  end

  defp provider_pages(records) when is_map(records) do
    pages = for {{kind, _}, page} <- records, kind in ["provider", "providers"], do: page

    case pages do
      [] -> nil
      pages -> Enum.flat_map(pages, &(Map.get(&1, :items) || []))
    end
  end

  defp provider_pages(_records), do: nil

  # --------------------------------------------------------------- tag

  defp tag(_ctx, _entry, _setting, %{saving?: true}), do: [{"saving…", :text_faint}]

  defp tag(_ctx, %Entry{type: type}, _setting, _write) when type in [:fact, :action, :link],
    do: []

  defp tag(_ctx, _entry, nil, _write), do: []

  defp tag(_ctx, _entry, %{state: state}, _write) when state in [:invalid, "invalid"],
    do: [{"r resets it", :text_muted}]

  defp tag(_ctx, _entry, setting, _write) do
    case Provenance.winner(setting) do
      nil ->
        [{"default", :text_faint}]

      %{layer: :default} ->
        [{"default", :text_faint}]

      %{layer: layer} = winner ->
        source = Map.get(winner, :source)

        source =
          if layer in [:flag, :env] and is_binary(source),
            do: [{" " <> source, :text_faint}],
            else: []

        [{Provenance.word(layer), :text_muted} | source]
    end
  end

  # ------------------------------------------------------------- marks

  defp marks(_ctx, entry, setting, write, error, conflict) do
    winner = setting && Map.get(setting, :winner)

    [
      if(winner not in [nil, :default] and Entry.scalar?(entry), do: :changed),
      if(setting && Map.get(setting, :state) in [:attention, "attention"], do: :attention),
      if(error != nil or (setting && Map.get(setting, :state) in [:invalid, "invalid"]),
        do: :invalid
      ),
      if(write && Map.get(write, :saving?), do: :pending),
      if(conflict, do: :conflict)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ------------------------------------------------------------- lines

  defp lines(ctx, entry, setting, error, conflict) do
    overrides(entry, setting) ++
      ignored(setting) ++
      notes(ctx, entry) ++
      error_lines(error) ++
      conflict_lines(entry, conflict)
  end

  defp overrides(_entry, nil), do: []

  defp overrides(%Entry{} = entry, setting) do
    home = Enum.find(Map.get(setting, :layers, []), &(Map.get(&1, :layer) == entry.home))

    stored =
      case home do
        %{set: true, value: value} -> Display.words(value)
        _ -> "not set"
      end

    home_word =
      if entry.home == :cli, do: "cli.json", else: Provenance.word(entry.home || :global)

    setting
    |> Provenance.overrides(entry)
    |> Enum.take(1)
    |> Enum.map(fn layer ->
      [
        {"#{Map.get(layer, :source) || Provenance.word(layer.layer)}=#{Map.get(layer, :raw) || Display.words(layer.value)} wins while set",
         :warning},
        {" · #{home_word}: #{stored}", :text_faint}
      ]
    end)
  end

  defp ignored(nil), do: []

  defp ignored(setting) do
    setting
    |> Map.get(:layers, [])
    |> Enum.filter(&Map.get(&1, :ignored, false))
    |> Enum.map(fn layer ->
      note = Map.get(layer, :note) || "not understood"

      [
        {"#{Map.get(layer, :source) || Provenance.word(layer.layer)}=#{Map.get(layer, :raw) || ""} is ignored: #{note}",
         :text_muted}
      ]
    end)
  end

  defp notes(ctx, entry) do
    [
      if(entry.desktop_only, do: [{"no effect in the terminal", :text_faint}]),
      if(entry.scheduler_only,
        do: [{"schedules run only while the desktop app runs", :text_faint}]
      ),
      if(next_launch?(ctx, entry), do: [{"applies at the next launch", :text_muted}])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp next_launch?(%Ctx{layer: %{next_launch: set}}, entry), do: MapSet.member?(set, entry.key)
  defp next_launch?(_ctx, _entry), do: false

  defp error_lines(nil), do: []
  defp error_lines(message), do: [[{"✗ " <> message, :error}]]

  defp conflict_lines(_entry, nil), do: []

  defp conflict_lines(entry, conflict) do
    theirs = Display.toast_words(entry, Map.get(conflict, :theirs))
    mine = Display.toast_words(entry, Map.get(conflict, :mine))
    origin = Map.get(conflict, :origin) || "elsewhere in this session"

    [
      [{"! changed while you edited (#{origin}): now #{theirs}", :warning}],
      [{"Enter keep yours (#{mine}) · Esc take theirs (#{theirs})", :text_muted}]
    ]
  end

  # ------------------------------------------------------------ editor

  @doc "The editor of `entry` holding `value` (nil for rows with nothing to edit)."
  @spec editor(Ctx.t(), Entry.t(), term(), map() | nil) :: nil | {module(), map()}
  def editor(_ctx, %Entry{type: type}, _value, _setting) when type in [:fact, :action, :link],
    do: nil

  def editor(_ctx, %Entry{secret: true}, _value, _setting), do: nil

  def editor(_ctx, %Entry{} = entry, value, setting) do
    if Entry.writable?(entry) and not entry.desktop_only, do: by_type(entry, value, setting)
  end

  defp by_type(%Entry{type: :toggle}, value, _setting),
    do: {Editors.Toggle, %{value: value == true}}

  defp by_type(%Entry{type: type} = entry, value, setting) when type in [:enum, :effort] do
    {Editors.Enum,
     %{
       choices: Display.choices(entry, setting),
       value: value,
       nullable: entry.nullable,
       null_label: entry.null_label
     }}
  end

  defp by_type(%Entry{type: type} = entry, value, _setting)
       when type in [:integer, :duration, :money] do
    {Editors.Number,
     %{
       entry: entry,
       value: value,
       min: entry.min,
       max: entry.max,
       step: entry.step,
       big_step: entry.big_step,
       nullable: entry.nullable,
       null_label: entry.null_label,
       special: entry.special
     }}
  end

  defp by_type(%Entry{type: type} = entry, value, _setting)
       when type in [:text, :path, :combo, :lsp_command] do
    text = if is_binary(value), do: value, else: ""
    {Editors.Text, %{entry: entry, value: text, max: @text_max, nullable: entry.nullable}}
  end

  defp by_type(%Entry{type: :model} = entry, value, _setting) do
    {SwarmCodeCLI.UI.Settings.ModelPicker,
     %{current: value, nullable: entry.nullable, null_label: entry.null_label}}
  end

  defp by_type(%Entry{type: :color} = entry, value, _setting),
    do: {SwarmCodeCLI.UI.Settings.Editors.Color, %{entry: entry, value: value}}

  defp by_type(_entry, _value, _setting), do: nil

  defp keys(%Entry{type: type}) when type in [:fact, :link], do: []
  defp keys(%Entry{type: :action}), do: [{"Enter", :enter, "run"}]

  defp keys(%Entry{} = entry) do
    if Entry.writable?(entry) and entry.resettable,
      do: [{"r", :reset, "reset to the default"}],
      else: []
  end

  # ------------------------------------------------------------ detail

  @doc "The detail of an entry (§4.6)."
  @spec detail(Ctx.t(), Entry.t(), map() | nil, term()) :: Detail.t()
  def detail(%Ctx{} = ctx, %Entry{} = entry, setting, value) do
    %Detail{
      title: entry.label,
      scope: scope_words(ctx, entry),
      key_line: key_line(entry),
      description: entry.description || "",
      facts: facts(ctx, entry, value),
      layers: detail_layers(setting),
      notes:
        [
          if(entry.desktop_only, do: {"no effect in the terminal", :text_faint}),
          if(entry.scheduler_only,
            do: {"runs only while the desktop app runs its scheduler", :text_faint}
          )
        ]
        |> Enum.reject(&is_nil/1)
    }
  end

  defp key_line(%Entry{storage: {:cli, name}} = entry), do: ~s(#{entry.key} · cli.json "#{name}")

  defp key_line(%Entry{stored_name: name} = entry) when is_binary(name),
    do: "#{entry.key} · #{name}"

  defp key_line(%Entry{} = entry), do: entry.key

  @doc "Where an entry lives, in words."
  @spec scope_words(Ctx.t(), Entry.t()) :: String.t() | nil
  def scope_words(_ctx, %Entry{scope: :session}), do: "this conversation"
  def scope_words(_ctx, %Entry{scope: :global}), do: "global · shared with the desktop app"
  def scope_words(_ctx, %Entry{scope: :cli}), do: "this machine's terminal"
  def scope_words(_ctx, %Entry{scope: :project_file}), do: ".swarm_code/config.json"

  def scope_words(%Ctx{project: project}, %Entry{scope: :project}) do
    case project_name(project) do
      nil -> "the project"
      name -> "#{name} (project)"
    end
  end

  def scope_words(_ctx, _entry), do: nil

  defp project_name(%{"name" => name}) when is_binary(name), do: name
  defp project_name(%{name: name}) when is_binary(name), do: name
  defp project_name(name) when is_binary(name), do: name
  defp project_name(_project), do: nil

  defp facts(ctx, %Entry{} = entry, value) do
    lookups = lookups(ctx)

    [
      if(Entry.scalar?(entry),
        do: {"value", segments_words(Display.value(entry, value, nil, lookups))}
      ),
      if(Entry.scalar?(entry) and not is_nil(entry.default),
        do: {"default", segments_words(Display.value(entry, entry.default, nil, lookups))}
      ),
      if(is_number(entry.min) and is_number(entry.max),
        do: {"range", "#{Display.number(entry, entry.min)}–#{Display.number(entry, entry.max)}"}
      ),
      if(entry.type in [:integer, :duration, :money] and entry.step not in [nil, 1],
        do: {"step", to_string(entry.step)}
      ),
      if(entry.unit, do: {"unit", to_string(entry.unit)}),
      if(Entry.scalar?(entry), do: {"applies", applies_words(entry.applies)}),
      case scope_words(ctx, entry) do
        nil -> nil
        words -> {"scope", words}
      end,
      if(entry.env != [], do: {"env", Enum.join(entry.env, ", ")}),
      if(is_binary(entry.flag), do: {"flag", entry.flag})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp segments_words(segments), do: Enum.map_join(segments, "", &elem(&1, 0))

  defp detail_layers(nil), do: []

  defp detail_layers(setting) do
    winner = Map.get(setting, :winner)

    setting
    |> Map.get(:layers, [])
    |> Enum.map(fn layer ->
      %{
        layer: Provenance.word(layer.layer),
        value:
          cond do
            Map.get(layer, :ignored, false) -> "#{Map.get(layer, :raw)} (ignored)"
            Map.get(layer, :set, false) -> Display.words(Map.get(layer, :value))
            true -> "not set"
          end,
        note: Map.get(layer, :note) || Map.get(layer, :source),
        winner?: layer.layer == winner,
        set?: Map.get(layer, :set, false),
        ignored?: Map.get(layer, :ignored, false)
      }
    end)
  end

  # ----------------------------------------------------------- helpers

  @doc "The write key of a registry key."
  @spec write_key(Entry.t()) :: term()
  def write_key(%Entry{key: key}), do: {:value, key}

  defp write(%Ctx{layer: %{writes: writes}}, entry), do: Map.get(writes, write_key(entry))
  defp write(_ctx, _entry), do: nil

  defp row_error(%Ctx{layer: %{row_errors: errors}}, id), do: Map.get(errors, id)
  defp row_error(_ctx, _id), do: nil

  defp conflict(%Ctx{layer: %{conflicts: conflicts}}, entry),
    do: Map.get(conflicts, write_key(entry))

  defp conflict(_ctx, _entry), do: nil

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp get(_map, _key), do: nil
end
